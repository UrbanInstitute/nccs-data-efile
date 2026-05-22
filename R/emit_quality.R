#' Emit a per-output quality.json
#'
#' Writes `{name}_quality.json` summarizing the shape of an output
#' data.frame. See ADR 0001 section 10.
#'
#' Contents:
#'   - `row_count`             total rows
#'   - `null_rate_per_column`  named list, one entry per column
#'   - `per_year_counts`       named list keyed by tax_year (if present)
#'   - `numeric_summary`       per numeric column: min/max/p50/p99
#'   - `extract_error_count`   filings that failed extraction
#'                             (`_extract_error` non-NA), if present
#'
#' @param output_name Base name for the emitted file.
#' @param df The data.frame being summarized.
#' @param out_dir Directory to write into.
#' @return Invisibly, the path to the written file.
#' @export
emit_quality <- function(output_name, df, out_dir) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  null_rate <- vapply(df, function(x) mean(is.na(x)), numeric(1))
  numeric_cols <- vapply(df, is.numeric, logical(1))
  numeric_summary <- lapply(df[, numeric_cols, drop = FALSE], function(x) {
    nn <- x[!is.na(x)]
    if (length(nn) == 0) return(list(min = NA, max = NA, p50 = NA, p99 = NA))
    list(
      min = min(nn),
      max = max(nn),
      p50 = unname(stats::quantile(nn, 0.5)),
      p99 = unname(stats::quantile(nn, 0.99))
    )
  })

  per_year <- if ("tax_year" %in% names(df)) {
    as.list(table(df$tax_year))
  } else {
    NULL
  }

  extract_error_count <- if ("_extract_error" %in% names(df)) {
    sum(!is.na(df[["_extract_error"]]))
  } else {
    NULL
  }

  payload <- list(
    output = output_name,
    row_count = nrow(df),
    null_rate_per_column = as.list(null_rate),
    numeric_summary = numeric_summary,
    per_year_counts = per_year,
    extract_error_count = extract_error_count
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
