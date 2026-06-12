#' Run a wholesale relational (scalar) extraction build — ADR 0004 step 3.
#'
#' Drives the raw researcher tier end-to-end:
#'   1. Build the relational plan from the Layer 1 inventory (`is_leaf &
#'      !repeating` scalar leaves per form root).
#'   2. Fetch the upstream index.
#'   3. Extract every in-scope filing in parallel, one parse per filing feeding
#'      all of `returnheader` + the form body, via the ZIP-bulk staging path
#'      (the same engine `run_phase0()` uses) or the per-filing `objects` path.
#'   4. Write each table partitioned by `tax_year`, with a per-table dictionary,
#'      a best-effort/uncontracted marker, and a manifest.
#'
#' S3 publication is NOT here — `inst/scripts/run_relational.R` syncs each table
#' dir to `relational/{table}/{vintage}/` after a clean build, so a failed build
#' never half-publishes. The tier is best-effort / uncontracted (ADR 0004
#' section 4 / nccs-contracts 0028): provenance is shipped, stability is not
#' promised.
#'
#' @param config Loaded config list.
#' @param vintage Vintage string (`v2026.06`); auto-derived if `NULL`.
#' @param out_dir Output directory (default `{output$local_dir}/relational/{vintage}`).
#' @param index Optional pre-built index (skips the fetch; for testing).
#' @param inventory Optional Layer 1 inventory data.frame (skips the rebuild).
#' @param plan Optional pre-built relational plan (skips inventory + plan build).
#' @return Invisibly, a summary list (vintage, out_dir, per-table row counts).
#' @export
run_relational <- function(config = load_config(), vintage = NULL,
                           out_dir = NULL, index = NULL, inventory = NULL,
                           plan = NULL) {
  vintage <- vintage %||% config$output$vintage %||%
    sprintf("v%s", format(Sys.Date(), "%Y.%m"))
  out_dir <- out_dir %||% file.path(
    config$output$local_dir %||% "out", "relational", vintage)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  cli::cli_h1("Relational build {vintage} -> {out_dir}")

  if (is.null(plan)) {
    if (is.null(inventory)) {
      cli::cli_alert_info("building Layer 1 inventory for the relational plan")
      inventory <- build_all_xsd_inventories(config = config)
    }
    plan <- build_relational_plan(inventory)
  }
  for (tn in names(plan)) {
    cli::cli_alert_info("plan: {tn} = {nrow(plan[[tn]]$leaves)} scalar columns")
  }

  if (is.null(index)) index <- fetch_gt_indices(config = config)
  cli::cli_alert_info("index: {nrow(index)} filings in scope")

  setup_future_plan(config$parallelism)
  cli::cli_alert_info(
    "extracting ({future::nbrOfWorkers()} parse workers, staging '{config$staging$mode %||% \"objects\"}')")
  tables <- extract_relational(index, plan, config, out_dir)
  for (tn in names(tables)) {
    if (!is.null(tables[[tn]])) cli::cli_alert_info("{tn}: {nrow(tables[[tn]])} rows")
  }

  written <- write_relational_tables(tables, plan, out_dir, config, vintage)

  cli::cli_alert_success(
    "Relational build complete: {length(written)} table(s) under {out_dir}")
  invisible(list(vintage = vintage, out_dir = out_dir,
                 tables = written,
                 row_counts = lapply(tables, function(t) if (is.null(t)) 0L else nrow(t))))
}

#' Dispatch relational extraction by staging mode (mirrors `extract_filings`).
#' @noRd
extract_relational <- function(index, plan, config, out_dir) {
  mode <- config$staging$mode %||% "objects"
  switch(
    mode,
    zips    = extract_relational_via_zips(index, plan, config, out_dir),
    objects = extract_filings_relational(
      index, plan, max_bytes = max_bytes_from_config(config)),
    stop(sprintf("unknown staging.mode: %s", mode))
  )
}

#' ZIP-bulk relational extraction — the scale path. Mirrors `extract_via_zips`,
#' but each filing yields rows for several tables, so each ZIP checkpoints ONE
#' parquet per table (`{chunk}/{zip}__{table}.parquet`, empty if a table got no
#' rows so resume still detects completion). Final assembly reads, unions,
#' dedups, and types each table.
#' @noRd
extract_relational_via_zips <- function(index, plan, config, out_dir) {
  staging <- config$staging
  stage_dir <- staging$stage_dir %||% file.path(out_dir, "_stage")
  chunk_dir <- staging$checkpoint_dir %||%
    file.path(dirname(out_dir), "_checkpoints", basename(out_dir))
  dir.create(chunk_dir, recursive = TRUE, showWarnings = FALSE)
  tnames <- names(plan)

  index$object_id <- as.character(index$object_id)
  index <- index[!duplicated(index$object_id), , drop = FALSE]

  zips <- list_target_zips(staging)
  if (length(zips) == 0) stop("no target ZIPs found under ", staging$zip_prefix)
  cli::cli_alert_info("staging via {length(zips)} ZIP bundle(s) from {staging$zip_prefix}")

  chunk_paths <- function(z) stats::setNames(
    file.path(chunk_dir, sprintf("%s__%s.parquet", basename(z), tnames)), tnames)

  t0 <- Sys.time()
  for (k in seq_along(zips)) {
    z <- zips[[k]]
    pqs <- chunk_paths(z)
    if (all(file.exists(pqs))) {
      cli::cli_alert_info("[zip {k}/{length(zips)}] {basename(z)} - skip (done)")
      next
    }
    per_table <- process_one_zip_relational(z, index, plan, config, stage_dir)
    matched <- 0L
    for (tn in tnames) {
      dt <- per_table[[tn]]
      if (is.null(dt) || nrow(dt) == 0) dt <- empty_relational_chunk()
      write_chunk_parquet(as.data.frame(dt), pqs[[tn]], config)
      matched <- max(matched, nrow(dt))
    }
    elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
    eta <- if (k < length(zips)) round(elapsed / k * (length(zips) - k)) else 0
    cli::cli_alert_info(
      "[zip {k}/{length(zips)}] {basename(z)} - {matched} in-scope filings, {round(elapsed)}s, ETA {eta}s")
  }

  # Coverage fallback: in-scope object_ids absent from every processed ZIP.
  found <- unique(unlist(lapply(
    list.files(chunk_dir, pattern = "__returnheader\\.parquet$", full.names = TRUE),
    function(p) as.character(arrow::read_parquet(p)$filing_receipt_id))))
  missing <- setdiff(index$object_id, found)
  if (length(missing) > 0) {
    extract_relational_fallback(index[index$object_id %in% missing, , drop = FALSE],
                                plan, config, stage_dir, chunk_dir)
  }
  unlink(stage_dir, recursive = TRUE, force = TRUE)

  # Final assembly per table: union all chunks, dedup by filing, type columns.
  out <- list()
  for (tn in tnames) {
    parts <- lapply(
      list.files(chunk_dir, pattern = sprintf("__%s\\.parquet$", tn), full.names = TRUE),
      arrow::read_parquet)
    parts <- parts[vapply(parts, nrow, integer(1)) > 0L]
    if (length(parts) == 0) { out[[tn]] <- NULL; next }
    combined <- data.table::rbindlist(parts, use.names = TRUE, fill = TRUE)
    combined <- unique(combined, by = "filing_receipt_id")  # same source across ZIPs
    out[[tn]] <- type_relational_table(as.data.frame(combined), plan[[tn]]$leaves)
  }
  out
}

#' Download + unzip one ZIP, parse its in-scope filings into per-table rows.
#' Mirrors `process_one_zip` (same unzip handling) but uses the relational
#' extractor; returns a named list (by table) of data.tables.
#' @noRd
process_one_zip_relational <- function(z, index, plan, config, stage_dir) {
  reset_dir(stage_dir)
  local_zip <- file.path(stage_dir, basename(z))
  aws_s3_cp_anon(z, local_zip)
  xdir <- file.path(stage_dir, "x")
  dir.create(xdir, recursive = TRUE, showWarnings = FALSE)
  system2("unzip", c("-j", "-o", "-q", local_zip, "-d", xdir),
          stdout = FALSE, stderr = FALSE)
  unlink(local_zip)

  files <- list.files(xdir, pattern = "_public\\.xml$")
  ids <- sub("_public\\.xml$", "", files)
  keep <- ids %in% index$object_id
  if (!any(keep)) return(stats::setNames(vector("list", length(plan)), names(plan)))
  sub <- index[match(ids[keep], index$object_id), , drop = FALSE]
  sub$local_path <- file.path(xdir, files[keep])
  per_filing <- parse_rows_relational_parallel(
    sub, plan, max_bytes = max_bytes_from_config(config))
  bind_relational_by_table(per_filing, names(plan))
}

#' s5cmd coverage fallback for in-scope filings missing from all ZIPs.
#' Writes `{chunk}/_fallback__{table}.parquet` (resumable).
#' @noRd
extract_relational_fallback <- function(df, plan, config, stage_dir, chunk_dir) {
  done <- file.path(chunk_dir, sprintf("_fallback__%s.parquet", names(plan)))
  if (all(file.exists(done))) { cli::cli_alert_info("coverage fallback - skip (done)"); return(invisible()) }
  tool <- config$staging$fallback_tool %||% "s5cmd"
  cli::cli_alert_warning("{nrow(df)} in-scope filings absent from ZIPs; fetching via {tool}")
  reset_dir(stage_dir)
  xdir <- file.path(stage_dir, "fb"); dir.create(xdir, recursive = TRUE, showWarnings = FALSE)
  df$local_path <- file.path(xdir, paste0(df$object_id, "_public.xml"))
  runfile <- file.path(stage_dir, "s5cmd.txt")
  writeLines(sprintf("cp %s %s", df$s3_key, df$local_path), runfile)
  system2(tool, c("--no-sign-request", "run", runfile), stdout = FALSE, stderr = FALSE)
  got <- file.exists(df$local_path)
  if (any(!got)) cli::cli_alert_warning("{sum(!got)} filings still unfetched after fallback")
  per_filing <- parse_rows_relational_parallel(
    df[got, , drop = FALSE], plan, max_bytes = max_bytes_from_config(config))
  per_table <- bind_relational_by_table(per_filing, names(plan))
  for (tn in names(plan)) {
    dt <- per_table[[tn]]; if (is.null(dt) || nrow(dt) == 0) dt <- empty_relational_chunk()
    write_chunk_parquet(as.data.frame(dt), file.path(chunk_dir, sprintf("_fallback__%s.parquet", tn)), config)
  }
  invisible()
}

#' Parallel per-filing relational parse over a set of index rows (mirrors
#' `parse_rows_parallel`: worker-sized groups, dynamic scheduling). Returns a
#' flat list of per-filing named-lists (table -> one-row df).
#' @noRd
parse_rows_relational_parallel <- function(df, plan, max_bytes = 50e6) {
  if (nrow(df) == 0) return(list())
  n_workers <- max(1L, future::nbrOfWorkers())
  grp_size <- max(1L, ceiling(nrow(df) / (n_workers * 4L)))
  groups <- lapply(split(seq_len(nrow(df)), ceiling(seq_len(nrow(df)) / grp_size)),
                   function(idx) df[idx, , drop = FALSE])
  res <- furrr::future_map(
    groups,
    function(g) lapply(seq_len(nrow(g)),
                       function(i) extract_filing_relational(g[i, ], plan, max_bytes = max_bytes)),
    .options = furrr::furrr_options(seed = TRUE, scheduling = Inf))
  unlist(res, recursive = FALSE)
}

#' Regroup a flat list of per-filing named-lists into one data.table per table.
#' @noRd
bind_relational_by_table <- function(per_filing, table_names) {
  out <- list()
  for (tn in table_names) {
    parts <- lapply(per_filing, function(pf) pf[[tn]])
    parts <- parts[!vapply(parts, is.null, logical(1))]
    out[[tn]] <- if (length(parts)) {
      data.table::rbindlist(parts, use.names = TRUE, fill = TRUE)
    } else {
      NULL
    }
  }
  out
}

#' A zero-row chunk carrying just the keys, for a (zip, table) pair that matched
#' no filings — so resume still sees the checkpoint as complete.
#' @noRd
empty_relational_chunk <- function() {
  data.frame(filing_receipt_id = character(0), ein = character(0),
             tax_year = integer(0), form_type = character(0),
             `_extract_error` = character(0), check.names = FALSE,
             stringsAsFactors = FALSE)
}

#' Write the relational tables: each to its own dir, partitioned by `tax_year`,
#' with `_dictionary.csv`, a best-effort marker, and a per-table manifest. The
#' driver script syncs each dir to `relational/{table}/{vintage}/`.
#' @noRd
write_relational_tables <- function(tables, plan, out_dir, config, vintage) {
  comp <- config$parquet$compression %||% "zstd"
  written <- character(0)
  for (tn in names(tables)) {
    tbl <- tables[[tn]]
    if (is.null(tbl) || nrow(tbl) == 0) {
      cli::cli_alert_warning("{tn}: 0 rows — not written")
      next
    }
    tdir <- file.path(out_dir, tn)
    dir.create(tdir, recursive = TRUE, showWarnings = FALSE)
    ds_dir <- file.path(tdir, "data")
    unlink(ds_dir, recursive = TRUE, force = TRUE)
    if (!"tax_year" %in% names(tbl)) stop(tn, ": no tax_year column to partition on")
    write_partitioned_parquet(tbl, ds_dir, "tax_year", comp)

    utils::write.csv(plan[[tn]]$leaves,
                     file.path(tdir, "_dictionary.csv"), row.names = FALSE)
    writeLines(c(
      "TIER: relational (raw, XSD-faithful researcher catalog).",
      "STATUS: best-effort / UNCONTRACTED — no stability guarantee (ADR 0004 s4, nccs-contracts 0028).",
      "Column names are the element path relative to the form root; curated views (snake_case,",
      "contracted) are produced separately. Provenance is in _manifest.json."),
      file.path(tdir, "_TIER.txt"))
    emit_relational_manifest(tn, tbl, plan[[tn]], vintage, config, tdir)
    cli::cli_alert_success("wrote {tdir} ({nrow(tbl)} rows, {ncol(tbl)} cols)")
    written <- c(written, tdir)
  }
  written
}

#' Write `tbl` as a Hive-partitioned parquet dataset under `ds_dir`
#' (`{partition_col}={value}/part-0.parquet`), the partition column dropped from
#' the files (it lives in the path). Done by hand rather than
#' `arrow::write_dataset()`, which pulls `dplyr` (not a package dependency).
#' @noRd
write_partitioned_parquet <- function(tbl, ds_dir, partition_col, compression) {
  dir.create(ds_dir, recursive = TRUE, showWarnings = FALSE)
  vals <- tbl[[partition_col]]
  value_cols <- setdiff(names(tbl), partition_col)
  write_one <- function(rows, label) {
    pdir <- file.path(ds_dir, sprintf("%s=%s", partition_col, label))
    dir.create(pdir, recursive = TRUE, showWarnings = FALSE)
    arrow::write_parquet(tbl[rows, value_cols, drop = FALSE],
                         file.path(pdir, "part-0.parquet"), compression = compression)
  }
  for (pv in sort(unique(vals[!is.na(vals)]))) write_one(!is.na(vals) & vals == pv, pv)
  if (any(is.na(vals))) write_one(is.na(vals), "__HIVE_DEFAULT_PARTITION__")
  invisible(ds_dir)
}

#' Per-table relational manifest (ADR 0014 shape, best-effort tier).
#' @noRd
emit_relational_manifest <- function(table, tbl, plan_tbl, vintage, config, tdir) {
  parts <- as.list(sort(table(tbl$tax_year)))
  payload <- list(
    schema_version = 1L,
    artifact = sprintf("relational/%s", table),
    tier = "relational",
    contracted = FALSE,
    best_effort = TRUE,
    producer = "nccs-data-efile",
    producer_git_sha = git_head_sha(),
    vintage = vintage,
    build_timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    form_root = plan_tbl$root,
    forms = plan_tbl$forms,
    row_count = nrow(tbl),
    column_count = ncol(tbl),
    value_column_count = nrow(plan_tbl$leaves),
    partition = "tax_year",
    rows_per_tax_year = parts,
    inputs = list(
      gt_lake_snapshot_timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      irs_xsd_cache_prefix = config$vendored$irs_xsd_cache_s3_prefix,
      layer1_inventory_prefix = paste0(
        sub("/?$", "/", config$vendored$nodc_concordance_s3_prefix %||%
              "s3://nccsdata/processed/efile/concordance/"), "layer1/latest/")
    )
  )
  path <- file.path(tdir, "_manifest.json")
  jsonlite::write_json(payload, paste0(path, ".tmp"), pretty = TRUE,
                       auto_unbox = TRUE, na = "null")
  file.rename(paste0(path, ".tmp"), path)
  path
}
