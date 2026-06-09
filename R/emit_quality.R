#' Emit a per-output quality.json
#'
#' Writes `{name}_quality.json` summarizing the shape of an output
#' data.frame. See ADR 0001 section 10.
#'
#' Contents:
#'   - `row_count`             total rows
#'   - `null_rate_per_column`  named list, one entry per column
#'   - `per_year_counts`       named list keyed by tax_year (if present)
#'   - `numeric_summary`       per numeric column: population order
#'                             statistics (min/max/p50/p90/p99/p999),
#'                             negative/zero counts, and tail-mass
#'                             concentration (see `tail_diagnostics`)
#'   - `extract_error_count`   filings that failed extraction
#'                             (`_extract_error` non-NA), if known
#'   - `size_capped_count`     subset of the above skipped for
#'                             exceeding `extract.max_file_mb`
#'
#' @param output_name Base name for the emitted file.
#' @param df The data.frame being summarized (the published shape; the
#'   `_extract_error` column is dropped before publish, so the error
#'   counts come from `extract_errors`, not `df`).
#' @param out_dir Directory to write into.
#' @param extract_errors Optional character vector of `_extract_error`
#'   values for the in-scope filings (one per row, `NA` on success).
#'   Supplied by the caller because the column is stripped from the
#'   published `df`. When `NULL`, falls back to a `_extract_error`
#'   column on `df` if present (for standalone/test use).
#' @return Invisibly, the path to the written file.
#' @export
emit_quality <- function(output_name, df, out_dir, extract_errors = NULL) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  errs <- extract_errors %||%
    (if ("_extract_error" %in% names(df)) df[["_extract_error"]] else NULL)
  if (is.null(errs)) {
    extract_error_count <- NULL
    size_capped_count <- NULL
  } else {
    present <- errs[!is.na(errs)]
    extract_error_count <- length(present)
    size_capped_count <- sum(grepl("^file too large", present))
  }

  null_rate <- vapply(df, function(x) mean(is.na(x)), numeric(1))
  numeric_cols <- vapply(df, is.numeric, logical(1))
  # Population-wide order statistics + heavy-tail concentration (no
  # sampling). See `tail_diagnostics`. Empty list for an all-null column.
  numeric_summary <- lapply(df[, numeric_cols, drop = FALSE], tail_diagnostics)

  per_year <- if ("tax_year" %in% names(df)) {
    as.list(table(df$tax_year))
  } else {
    NULL
  }

  payload <- list(
    output = output_name,
    row_count = nrow(df),
    null_rate_per_column = as.list(null_rate),
    numeric_summary = numeric_summary,
    per_year_counts = per_year,
    extract_error_count = extract_error_count,
    size_capped_count = size_capped_count
  )

  path <- file.path(out_dir, sprintf("%s_quality.json", output_name))
  write_json_atomic(payload, path)
  cli::cli_alert_success("wrote {path}")
  invisible(path)
}

#' Pretty-write JSON atomically (write to tmp, then rename).
#' @noRd
write_json_atomic <- function(x, path) {
  tmp <- paste0(path, ".tmp")
  jsonlite::write_json(x, tmp, pretty = TRUE, auto_unbox = TRUE, na = "null")
  file.rename(tmp, path)
}
