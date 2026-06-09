#' Run a Phase 0 vintage build end-to-end
#'
#' Drives the full Phase 0 pipeline:
#'
#'   1. Fetch the upstream index (GT data lake or IRS direct).
#'   2. (Optional) Run XSD verification against the pinned XPath
#'      claims; abort on mismatch unless `skip_xsd_verification`.
#'   3. Extract every in-scope filing in parallel via `furrr`.
#'   4. Verify the extracted value distribution against config
#'      thresholds.
#'   5. For each configured Phase 0 output, write a parquet plus its
#'      dictionary and quality JSON.
#'   6. Emit a per-vintage `_manifest.json` covering all outputs.
#'
#' S3 publication is deliberately not in this function - the driver
#' script handles `aws s3 sync` after a successful build, so a failed
#' verification never leaves a half-published vintage.
#'
#' See ADR 0001 section 4 (execution model) and section 10 (manifest).
#'
#' @param config Loaded config list.
#' @param dict Layer-2 dictionary data.frame.
#' @param vintage Vintage string (`v2026.06`). Auto-derived if `NULL`.
#' @param xsd_version Optional XSD version label override. When
#'   `NULL` (the default at scale), each filing's version is parsed
#'   from its `return_version` column in the index. Pass an explicit
#'   value only for single-version test slices.
#' @param out_dir Output directory. Defaults to
#'   `file.path(config$output$local_dir, vintage)`.
#' @param skip_xsd_verification If `TRUE`, bypass the XSD check
#'   (useful for local development before XSDs are cached).
#' @param index Optional pre-built index data.frame to skip the
#'   fetch step (useful for testing).
#'
#' @return Invisibly, a summary list with vintage, output directory,
#'   parquet paths, and the structured verification results.
#' @export
run_phase0 <- function(config = load_config(),
                       dict = load_dictionary(),
                       vintage = NULL,
                       xsd_version = NULL,
                       out_dir = NULL,
                       skip_xsd_verification = FALSE,
                       index = NULL) {
  vintage <- vintage %||% config$output$vintage %||%
    sprintf("v%s", format(Sys.Date(), "%Y.%m"))
  out_dir <- out_dir %||% file.path(
    config$output$local_dir %||% "out", vintage
  )
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  cli::cli_h1("Phase 0 build {vintage} -> {out_dir}")

  xsd_result <- if (skip_xsd_verification) {
    list(passed = TRUE, checks_run = 0L, mismatches = list(), skipped = TRUE)
  } else {
    run_phase0_verification(config = config, strict = TRUE)
  }

  if (is.null(index)) {
    index <- if (identical(config$upstream$primary, "irs_direct")) {
      stop("irs_direct upstream requires per-(year, month) calls - pass `index` explicitly")
    } else {
      fetch_gt_indices(config = config)
    }
  }
  cli::cli_alert_info("index: {nrow(index)} filings in scope")

  # Fail fast if any in-scope (tax_year, version) lacks a resolving XPath claim
  # for an output field. This is the gate that would have caught the v2026.05
  # `5-0`-vs-`5.0` typo that silently nulled TY2022/2023 (ADR 0002 Outcome).
  verify_claim_coverage(index, dict, config)

  # Supply-side gate (Phase 0.5): assert the dictionary's own XPath claims
  # resolve to leaf elements in the mechanical Layer 1 XSD inventory. Catches
  # a typo'd/renamed claim against ground truth, not just against the index.
  # Shares the XSD cache run_phase0_verification needs, so it rides the same
  # skip flag.
  if (!skip_xsd_verification) {
    verify_dictionary_against_inventory(
      dict, build_all_xsd_inventories(config), config = config, strict = TRUE
    )
  }

  setup_future_plan(config$parallelism)
  cli::cli_alert_info(
    "extracting ({future::nbrOfWorkers()} parse workers, staging mode '{config$staging$mode %||% \"objects\"}')"
  )
  extracted <- extract_filings(index, dict, config, out_dir, xsd_version)
  cli::cli_alert_info("extracted {nrow(extracted)} rows")
  warn_empty_tax_years(extracted, dict, config)

  # Distribution thresholds in config are calibrated from a 100-filing
  # dry-run; the first scale vintage's job is to *measure* the real
  # distribution, not enforce one. Per-vintage strictness is opt-in
  # via config$verification$strict; flip to TRUE once thresholds are
  # pinned from a real vintage's observed values (ADR 0001 §6).
  dist_strict <- isTRUE(config$verification$strict)
  dist_result <- verify_value_distribution(
    extracted, config = config, strict = dist_strict
  )

  parquet_paths <- character(0)
  for (out in config$phase0_outputs) {
    p <- write_phase0_output(out, extracted, dict, config, xsd_version,
                             out_dir, vintage)
    parquet_paths <- c(parquet_paths, p)
  }

  manifest_path <- emit_manifest(
    vintage = vintage,
    phase = config$output$phase %||% "phase0",
    scope = config$scope,
    parquet_paths = parquet_paths,
    inputs = list(
      nodc_concordance_sha = config$vendored$nodc_concordance_sha,
      nodc_concordance_s3_prefix = config$vendored$nodc_concordance_s3_prefix,
      gt_lake_snapshot_timestamp_utc = format(
        Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"
      ),
      irs_xsd_cache_prefix = config$vendored$irs_xsd_cache_s3_prefix
    ),
    xsd_verification = xsd_result,
    value_distribution = dist_result,
    out_dir = out_dir
  )

  cli::cli_alert_success("Phase 0 build complete: {nrow(extracted)} filings, {length(parquet_paths)} outputs")
  invisible(list(
    vintage = vintage,
    out_dir = out_dir,
    parquet_paths = parquet_paths,
    manifest_path = manifest_path,
    n_filings = nrow(extracted),
    xsd_verification = xsd_result,
    value_distribution = dist_result
  ))
}

#' Write one Phase 0 output: parquet + dictionary + quality.
#'
#' Filters rows to forms_applicable across all fields in the output -
#' i.e. only rows whose form_type appears in EVERY field's
#' forms_applicable list. Phase 0 outputs each carry a single field,
#' so this collapses to a per-form filter.
#' @noRd
write_phase0_output <- function(out_spec, extracted, dict, config,
                                xsd_version, out_dir, vintage) {
  key_cols <- c("filing_receipt_id", "ein", "tax_year", "form_type")
  cols <- c(key_cols, out_spec$fields)
  missing <- setdiff(cols, names(extracted))
  if (length(missing) > 0) {
    stop(sprintf("output %s: missing columns: %s",
                 out_spec$name, paste(missing, collapse = ", ")))
  }
  applicable_forms <- forms_for_fields(out_spec$fields, dict)
  rows <- if (length(applicable_forms) > 0) {
    extracted$form_type %in% applicable_forms
  } else {
    rep(TRUE, nrow(extracted))
  }
  df <- extracted[rows, cols, drop = FALSE]
  # Capture the per-filing extract errors for the in-scope rows BEFORE the
  # `_extract_error` column is dropped (it is not in `cols`, so it never
  # reaches the parquet). Without this the quality file's error counts are
  # always empty - the skipped/oversized filings would be invisible.
  err_vec <- if ("_extract_error" %in% names(extracted)) {
    extracted[rows, "_extract_error", drop = TRUE]
  } else {
    NULL
  }

  parquet_path <- file.path(out_dir, sprintf("%s.parquet", out_spec$name))
  arrow::write_parquet(
    df, parquet_path,
    compression = config$parquet$compression %||% "zstd"
  )
  cli::cli_alert_success("wrote {parquet_path}")

  # The dictionary CSV documents one representative XPath per output.
  # Each row's actual extraction uses the per-filing version, but the
  # dictionary's source_xpath column is a single string - pick the
  # most recent (tax_year, version) in scope as the representative
  # reference. The XPath in xpath_claims is in practice identical
  # across in-scope tuples for the Phase 0 fields.
  rep <- representative_xsd_version(config, fallback = xsd_version)
  emit_dictionary(
    output_name = out_spec$name,
    column_names = cols,
    dict = dict,
    tax_year = rep$tax_year,
    version = rep$version,
    nodc_concordance_sha = config$vendored$nodc_concordance_sha %||% NA_character_,
    out_dir = out_dir
  )
  emit_quality(out_spec$name, df, out_dir = out_dir, extract_errors = err_vec)
  parquet_path
}

#' Pick a representative (tax_year, version) for the dictionary CSV's
#' source_xpath column: the highest tax_year in scope, paired with
#' the last configured version for that year. Falls back to `fallback`
#' (the legacy `xsd_version` arg) if config can't resolve one.
#' @noRd
representative_xsd_version <- function(config, fallback = NULL) {
  years <- config$scope$tax_years
  ty <- if (length(years) > 0) as.character(max(as.integer(years))) else NA_character_
  vers <- config$xsd$versions[[ty]]
  v <- if (!is.null(vers) && length(vers) > 0) vers[[length(vers)]] else fallback
  list(tax_year = ty, version = v)
}

#' Intersection of forms_applicable across a list of nccs_name fields.
#' Reads the dictionary's `forms_applicable` cell (semicolon- or
#' comma-separated), trims, and intersects. Returns character(0) if
#' any field has no forms_applicable entry (treated as "no filter").
#' @noRd
forms_for_fields <- function(fields, dict) {
  if (!"forms_applicable" %in% names(dict)) return(character(0))
  per <- list()
  for (f in fields) {
    row <- dict[dict$nccs_name == f, , drop = FALSE]
    if (nrow(row) == 0) return(character(0))
    raw <- row$forms_applicable[[1]]
    if (is.null(raw) || is.na(raw) || !nzchar(raw)) return(character(0))
    per[[length(per) + 1]] <- trimws(strsplit(raw, "[;,]")[[1]])
  }
  Reduce(intersect, per)
}

#' Set up the furrr/future plan from config.
#' @noRd
setup_future_plan <- function(parallelism) {
  plan_name <- parallelism$plan %||% "multisession"
  workers <- parallelism$workers %||% 4L
  switch(
    plan_name,
    multisession = future::plan(future::multisession, workers = workers),
    multicore    = future::plan(future::multicore, workers = workers),
    sequential   = future::plan(future::sequential),
    stop(sprintf("unknown parallelism.plan: %s", plan_name))
  )
}

# ----------------------------------------------------------------------
# Extraction staging. `staging.mode` selects how XML is obtained:
#   - "zips":    bulk-download the GT lake's EfileData/XmlZips/ bundles,
#                one ZIP at a time (a resumable checkpoint unit), unzip,
#                keep only in-scope object_ids, parse, delete. Any
#                in-scope object_id absent from every ZIP is fetched
#                individually via s5cmd (coverage fallback).
#   - "objects": legacy per-filing download (slow; for small local slices).
# See ADR 0001 §9 and the EC2 runbook.
# ----------------------------------------------------------------------

#' Pre-extract guard: assert every in-scope `(tax_year, version)` resolves to
#' an XPath claim for each output field, using the same `(row$tax_year,
#' parse_return_version(return_version)$version)` lookup the extractor uses.
#' Stops the build (listing the affected cells and filing counts) if any cell
#' is unresolved - the typo/coverage class of bug that otherwise nulls whole
#' tax years invisibly.
#' @noRd
verify_claim_coverage <- function(index, dict, config) {
  combos <- unique(index[, c("tax_year", "return_version", "form_type")])
  misses <- list()
  for (out in config$phase0_outputs) {
    for (fld in out$fields) {
      forms <- forms_for_fields(fld, dict)
      claim_cell <- dict$xpath_claims[dict$nccs_name == fld]
      if (length(claim_cell) != 1) {
        misses[[length(misses) + 1]] <- data.frame(
          field = fld, tax_year = NA_integer_, version = NA_character_,
          n_filings = sum(index$form_type %in% forms),
          reason = "no dictionary row", stringsAsFactors = FALSE)
        next
      }
      sub <- combos[combos$form_type %in% forms, , drop = FALSE]
      for (j in seq_len(nrow(sub))) {
        ver <- parse_return_version(sub$return_version[[j]])$version
        ty  <- sub$tax_year[[j]]
        if (is.na(parse_xpath_claim(claim_cell[[1]], ty, ver))) {
          misses[[length(misses) + 1]] <- data.frame(
            field = fld, tax_year = ty, version = ver,
            n_filings = sum(index$form_type %in% forms &
                            index$tax_year == ty &
                            index$return_version == sub$return_version[[j]]),
            reason = "no xpath claim", stringsAsFactors = FALSE)
        }
      }
    }
  }
  if (length(misses) > 0) {
    m <- do.call(rbind, misses)
    m <- m[order(-m$n_filings), , drop = FALSE]
    tbl <- paste(utils::capture.output(print(m, row.names = FALSE)), collapse = "\n")
    stop(sprintf(
      paste0("claim coverage gap: %d (field, year, version) cell(s) unresolved; ",
             "%s in-scope filings would extract as NA:\n%s"),
      nrow(m), format(sum(m$n_filings), big.mark = ","), tbl), call. = FALSE)
  }
  cli::cli_alert_success(
    "claim coverage: every in-scope (year, version) resolves to an XPath")
}

#' Post-extract sanity: warn loudly if any in-scope tax_year is ~entirely null
#' for an output field. A resolving XPath that still yields nothing across a
#' whole year signals schema drift the coverage guard cannot see. Non-fatal -
#' some years may be legitimately sparse - but surfaced for review.
#' @noRd
warn_empty_tax_years <- function(extracted, dict, config, threshold = 0.999) {
  for (out in config$phase0_outputs) {
    for (fld in out$fields) {
      if (!fld %in% names(extracted)) next
      forms <- forms_for_fields(fld, dict)
      sub <- extracted[extracted$form_type %in% forms, , drop = FALSE]
      if (nrow(sub) == 0) next
      rate <- tapply(sub[[fld]], sub$tax_year, function(v) mean(is.na(v)))
      empty <- rate[!is.na(rate) & rate >= threshold]
      for (ty in names(empty)) {
        cli::cli_alert_danger(paste0(
          "{fld}: tax_year {ty} is {round(100 * empty[[ty]], 1)}% null ",
          "({sum(sub$tax_year == as.integer(ty))} filings) - possible extraction gap"))
      }
    }
  }
}

#' Dispatch extraction by staging mode. Returns a base data.frame.
#' @noRd
extract_filings <- function(index, dict, config, out_dir, xsd_version) {
  mode <- config$staging$mode %||% "objects"
  switch(
    mode,
    zips    = extract_via_zips(index, dict, config, out_dir, xsd_version),
    objects = as.data.frame(
      data.table::rbindlist(
        parse_rows_parallel(index, dict, xsd_version),
        use.names = TRUE, fill = TRUE
      )
    ),
    stop(sprintf("unknown staging.mode: %s", mode))
  )
}

#' Parse a set of index rows in parallel, one filing per row.
#' Splits into worker-sized groups (passed as the furrr iteration
#' argument, not captured as a closure global) and calls
#' `extract_filing` per row. Returns a list of one-row data.frames.
#' @noRd
parse_rows_parallel <- function(df, dict, xsd_version, max_bytes = 50e6) {
  if (nrow(df) == 0) return(list())
  n_workers <- max(1L, future::nbrOfWorkers())
  grp_size <- max(1L, ceiling(nrow(df) / (n_workers * 4L)))
  grp <- ceiling(seq_len(nrow(df)) / grp_size)
  groups <- lapply(
    split(seq_len(nrow(df)), grp),
    function(idx) df[idx, , drop = FALSE]
  )
  # scheduling = Inf dispatches each group as its own future, picked up
  # dynamically as workers free up. Without it, furrr statically partitions the
  # groups across workers up front, so a worker dealt a slow group (one holding
  # an unusually large filing) stalls the whole batch while others idle - the
  # straggler tail that made the static run ~7h. Dynamic dispatch rebalances it.
  res <- furrr::future_map(
    groups,
    function(g) lapply(
      seq_len(nrow(g)),
      function(i) extract_filing(g[i, ], dict, version = xsd_version,
                                 max_bytes = max_bytes)
    ),
    .options = furrr::furrr_options(seed = TRUE, scheduling = Inf)
  )
  unlist(res, recursive = FALSE)
}

#' Per-filing size cap (bytes) from config; 0 disables. Default 50 MB.
#' @noRd
max_bytes_from_config <- function(config) {
  mb <- config$extract$max_file_mb %||% 50
  as.numeric(mb) * 1e6
}

#' ZIP-bulk extraction: the primary scale path. Each ZIP is one
#' resumable checkpoint -> {checkpoint_dir}/{zipname}.parquet, where
#' checkpoint_dir defaults to a `_checkpoints/<vintage>/` sibling of out_dir
#' (NOT under it) so build scratch never crosses the publish boundary.
#' `run_fallback = FALSE` skips the per-object coverage fallback (used by
#' timed_slice.R, where only a few ZIPs are processed and the full
#' "missing" set is meaningless).
#' @noRd
extract_via_zips <- function(index, dict, config, out_dir, xsd_version,
                             run_fallback = TRUE) {
  staging <- config$staging
  stage_dir <- staging$stage_dir %||% file.path(out_dir, "_stage")
  # Checkpoints are build-internal resume state, NOT deliverables. They MUST
  # live outside out_dir: the publish step syncs the whole out_dir, so anything
  # under it crosses the publish boundary. Placing them in a sibling
  # `_checkpoints/<vintage>/` makes that leak structurally impossible rather
  # than relying on a --exclude denylist that future scratch could slip past.
  chunk_dir <- staging$checkpoint_dir %||%
    file.path(dirname(out_dir), "_checkpoints", basename(out_dir))
  dir.create(chunk_dir, recursive = TRUE, showWarnings = FALSE)

  index$object_id <- as.character(index$object_id)
  index <- index[!duplicated(index$object_id), , drop = FALSE]

  zips <- list_target_zips(staging)
  if (length(zips) == 0) stop("no target ZIPs found under ", staging$zip_prefix)
  cli::cli_alert_info(
    "staging via {length(zips)} ZIP bundle(s) from {staging$zip_prefix}"
  )

  found_ids <- character(0)
  t0 <- Sys.time()
  for (k in seq_along(zips)) {
    z <- zips[[k]]
    pq <- file.path(chunk_dir, sprintf("%s.parquet", basename(z)))
    if (file.exists(pq)) {
      ids <- arrow::read_parquet(pq)$filing_receipt_id
      found_ids <- c(found_ids, as.character(ids))
      cli::cli_alert_info(
        "[zip {k}/{length(zips)}] {basename(z)} - skip (done, {length(ids)} rows)"
      )
      next
    }
    rows <- process_one_zip(z, index, dict, config, stage_dir, xsd_version)
    if (length(rows) > 0) {
      dt <- data.table::rbindlist(rows, use.names = TRUE, fill = TRUE)
      write_chunk_parquet(dt, pq, config)
      found_ids <- c(found_ids, as.character(dt$filing_receipt_id))
      matched <- nrow(dt)
    } else {
      write_chunk_parquet(empty_extract_df(dict), pq, config)
      matched <- 0L
    }
    elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
    eta <- if (k < length(zips)) round(elapsed / k * (length(zips) - k)) else 0
    cli::cli_alert_info(
      "[zip {k}/{length(zips)}] {basename(z)} - {matched} in-scope rows, {round(elapsed)}s elapsed, ETA {eta}s"
    )
  }

  missing <- setdiff(index$object_id, unique(found_ids))
  if (run_fallback && length(missing) > 0) extract_coverage_fallback(
    index[index$object_id %in% missing, , drop = FALSE],
    dict, config, stage_dir, chunk_dir, xsd_version
  ) else if (length(missing) > 0) {
    cli::cli_alert_info("{length(missing)} in-scope ids not in processed ZIPs (fallback skipped)")
  }

  unlink(stage_dir, recursive = TRUE, force = TRUE)
  parts <- lapply(
    list.files(chunk_dir, pattern = "\\.parquet$", full.names = TRUE),
    arrow::read_parquet
  )
  parts <- parts[vapply(parts, nrow, integer(1)) > 0L]
  if (length(parts) == 0) stop("no rows extracted from any ZIP")
  combined <- data.table::rbindlist(parts, use.names = TRUE, fill = TRUE)

  # A filing's object_id can appear in more than one release-year ZIP, so the
  # same filing_receipt_id is parsed once per ZIP it lands in. Those copies come
  # from the same source XML and are value-identical, so collapse to one row per
  # filing. (The index is deduped by object_id upstream; this dedups the
  # *extracted* rows, which the per-ZIP chunk concatenation does not.)
  n_before <- nrow(combined)
  combined <- unique(combined, by = "filing_receipt_id")
  if (nrow(combined) < n_before) {
    cli::cli_alert_info(
      "deduped {n_before - nrow(combined)} cross-ZIP duplicate rows -> {nrow(combined)} unique filings"
    )
  }
  as.data.frame(combined)
}

#' Download one ZIP, extract it, parse its in-scope entries.
#' Uses the system `unzip` binary rather than `utils::unzip`, which
#' fails with error -103 on the GT lake's Zip64/large archives.
#' Returns a list of one-row data.frames (empty list if none in scope).
#' @noRd
process_one_zip <- function(z, index, dict, config, stage_dir, xsd_version) {
  reset_dir(stage_dir)
  local_zip <- file.path(stage_dir, basename(z))
  t_dl <- system.time(aws_s3_cp_anon(z, local_zip))[["elapsed"]]

  xdir <- file.path(stage_dir, "x")
  dir.create(xdir, recursive = TRUE, showWarnings = FALSE)
  # -j flatten paths, -o overwrite, -q quiet. system2 execs directly (no
  # shell), so paths need no quoting. unzip exits 1 on warnings (e.g. a
  # skipped entry) which is non-fatal; we validate by listing extracted
  # files below.
  t_uz <- system.time(
    system2("unzip", c("-j", "-o", "-q", local_zip, "-d", xdir),
            stdout = FALSE, stderr = FALSE)
  )[["elapsed"]]
  unlink(local_zip)

  files <- list.files(xdir, pattern = "_public\\.xml$")
  ids <- sub("_public\\.xml$", "", files)
  keep <- ids %in% index$object_id
  n_total <- length(files)
  n_keep <- sum(keep)
  rows <- list()
  t_pa <- 0
  if (n_keep > 0) {
    sel_ids <- ids[keep]
    sub <- index[match(sel_ids, index$object_id), , drop = FALSE]
    sub$local_path <- file.path(xdir, files[keep])
    t_pa <- system.time(
      rows <- parse_rows_parallel(sub, dict, xsd_version,
                                  max_bytes = max_bytes_from_config(config))
    )[["elapsed"]]
  }
  cli::cli_alert_info(
    "  phases: download {round(t_dl)}s, unzip {round(t_uz)}s ({n_total} files), parse {round(t_pa)}s ({n_keep} in scope)"
  )
  rows
}

#' Fetch in-scope filings missing from all ZIPs, individually via s5cmd,
#' and write them to {chunk_dir}/_fallback.parquet (also resumable).
#' @noRd
extract_coverage_fallback <- function(df, dict, config, stage_dir,
                                      chunk_dir, xsd_version) {
  fb_pq <- file.path(chunk_dir, "_fallback.parquet")
  if (file.exists(fb_pq)) {
    cli::cli_alert_info("coverage fallback - skip (done)")
    return(invisible())
  }
  tool <- config$staging$fallback_tool %||% "s5cmd"
  cli::cli_alert_warning(
    "{nrow(df)} in-scope filings absent from ZIPs; fetching individually via {tool}"
  )
  reset_dir(stage_dir)
  xdir <- file.path(stage_dir, "fb")
  dir.create(xdir, recursive = TRUE, showWarnings = FALSE)
  local_paths <- file.path(xdir, paste0(df$object_id, "_public.xml"))
  runfile <- file.path(stage_dir, "s5cmd.txt")
  writeLines(sprintf("cp %s %s", df$s3_key, local_paths), runfile)
  system2(tool, c("--no-sign-request", "run", runfile),
          stdout = FALSE, stderr = FALSE)

  df$local_path <- local_paths
  got <- file.exists(df$local_path)
  if (sum(!got) > 0) {
    cli::cli_alert_warning("{sum(!got)} filings still unfetched after fallback")
  }
  rows <- parse_rows_parallel(df[got, , drop = FALSE], dict, xsd_version,
                              max_bytes = max_bytes_from_config(config))
  if (length(rows) > 0) {
    dt <- data.table::rbindlist(rows, use.names = TRUE, fill = TRUE)
    write_chunk_parquet(dt, fb_pq, config)
  }
  invisible()
}

#' List target ZIP s3 URIs, filtered to release years >= the floor.
#' The release year is the last 19xx/20xx run in the filename (handles
#' both `YYYY_TEOS_XML_*` and `download990xml_YYYY_N` naming schemes).
#' @noRd
list_target_zips <- function(staging) {
  prefix <- staging$zip_prefix
  floor_yr <- as.integer(staging$zip_release_year_floor %||% 0L)
  out <- suppressWarnings(system2(
    "aws", c("s3", "ls", "--no-sign-request", prefix),
    stdout = TRUE, stderr = FALSE
  ))
  files <- sub(".*\\s", "", out)
  files <- files[grepl("\\.zip$", files)]
  yr <- vapply(files, extract_release_year, integer(1))
  keep <- !is.na(yr) & yr >= floor_yr
  uris <- paste0(prefix, files[keep])
  max_zips <- staging$max_zips
  if (!is.null(max_zips) && length(uris) > max_zips) uris <- utils::head(uris, max_zips)
  uris
}

#' Last plausible 4-digit year (19xx/20xx) in a filename, or NA.
#' @noRd
extract_release_year <- function(fname) {
  m <- regmatches(fname, gregexpr("(19|20)\\d{2}", fname))[[1]]
  if (length(m) == 0) return(NA_integer_)
  as.integer(m[[length(m)]])
}

#' Atomic parquet write: write to .tmp then rename, so a kill mid-write
#' never leaves a half-written chunk that resume would trust.
#' @noRd
write_chunk_parquet <- function(df, path, config) {
  tmp <- paste0(path, ".tmp")
  arrow::write_parquet(
    df, tmp, compression = config$parquet$compression %||% "zstd"
  )
  file.rename(tmp, path)
}

#' Zero-row data.frame with the columns `extract_filing` produces, used
#' as the chunk parquet for a ZIP that holds no in-scope filings (so
#' resume still skips it).
#' @noRd
empty_extract_df <- function(dict) {
  cols <- c("filing_receipt_id", "ein", "tax_year", "form_type",
            dict$nccs_name, "_extract_error")
  df <- stats::setNames(
    lapply(cols, function(.) character(0)), cols
  )
  as.data.frame(df, stringsAsFactors = FALSE, check.names = FALSE)
}

#' Wipe and recreate a directory (bounds staging disk to one ZIP).
#' @noRd
reset_dir <- function(d) {
  unlink(d, recursive = TRUE, force = TRUE)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}
