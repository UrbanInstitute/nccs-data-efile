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
#' @param xsd_version XSD version label to resolve XPath claims for.
#'   Phase 0 uses one version per build.
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
                       xsd_version,
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

  setup_future_plan(config$parallelism)
  cli::cli_alert_info("extracting in parallel ({future::nbrOfWorkers()} workers)")
  rows <- furrr::future_map(
    seq_len(nrow(index)),
    function(i) extract_filing(index[i, ], dict, version = xsd_version),
    .options = furrr::furrr_options(seed = TRUE)
  )
  extracted <- do.call(rbind, rows)

  dist_result <- verify_value_distribution(
    extracted, config = config, strict = TRUE
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

  parquet_path <- file.path(out_dir, sprintf("%s.parquet", out_spec$name))
  arrow::write_parquet(
    df, parquet_path,
    compression = config$parquet$compression %||% "zstd"
  )
  cli::cli_alert_success("wrote {parquet_path}")

  # Dictionary uses the first tax_year in scope to resolve XPath; the
  # XPath itself is documented in the dictionary's xpath_claims cell
  # for all (year, version) tuples. Picking one for source_xpath is a
  # representative reference.
  ty <- config$scope$tax_years[[1]]
  emit_dictionary(
    output_name = out_spec$name,
    column_names = cols,
    dict = dict,
    tax_year = ty,
    version = xsd_version,
    nodc_concordance_sha = config$vendored$nodc_concordance_sha %||% NA_character_,
    out_dir = out_dir
  )
  emit_quality(out_spec$name, df, out_dir = out_dir)
  parquet_path
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
