#' Emit a per-vintage manifest.json
#'
#' Writes `_manifest.json` to `out_dir` per the shape in ADR 0001
#' section 10. Computes sha256 + byte size + row count for each
#' parquet file in `parquet_paths`.
#'
#' @param vintage Vintage string, e.g. `"v2026.06"`. If `NULL`,
#'   derived from today as `vYYYY.MM`.
#' @param phase Phase label, e.g. `"phase0"`.
#' @param scope List with `forms` and `tax_years`.
#' @param parquet_paths Character vector of paths to the published
#'   parquet files. Row counts are read via `arrow::read_parquet`
#'   if available; otherwise reported as `NA`.
#' @param inputs Named list to populate the `inputs` block
#'   (NODC SHA, GT lake snapshot timestamp, XSD cache prefix, etc.).
#' @param xsd_verification Result list from `run_phase0_verification()`.
#' @param value_distribution Result list from `verify_value_distribution()`.
#' @param producer_git_sha Optional commit SHA; auto-detected via
#'   `git rev-parse HEAD` when `NULL`.
#' @param out_dir Directory to write the manifest into.
#'
#' @return Invisibly, the path to the written manifest.
#' @export
emit_manifest <- function(vintage = NULL,
                          phase,
                          scope,
                          parquet_paths,
                          inputs,
                          xsd_verification,
                          value_distribution,
                          producer_git_sha = NULL,
                          out_dir) {
  vintage <- vintage %||% sprintf("v%s", format(Sys.Date(), "%Y.%m"))
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  files <- lapply(parquet_paths, function(p) {
    list(
      name = basename(p),
      sha256 = digest::digest(file = p, algo = "sha256"),
      row_count = parquet_row_count(p),
      bytes = file.info(p)$size
    )
  })

  manifest <- list(
    schema_version = 1L,
    producer = "nccs-data-efile",
    producer_git_sha = producer_git_sha %||% git_head_sha(),
    vintage = vintage,
    build_timestamp_utc = format(
      Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"
    ),
    phase = phase,
    scope = scope,
    inputs = inputs,
    files = files,
    xsd_verification = list(
      passed = isTRUE(xsd_verification$passed),
      checks_run = xsd_verification$checks_run %||% 0L,
      mismatches = xsd_verification$mismatches %||% list(),
      aliases = xsd_verification$aliases %||% list()
    ),
    value_distribution = value_distribution$per_field %||% list()
  )

  path <- file.path(out_dir, "_manifest.json")
  write_json_atomic(manifest, path)
  cli::cli_alert_success("wrote {path}")
  invisible(path)
}

#' Read row count from a parquet file. Returns NA if arrow is not
#' installed or the file is unreadable.
#' @noRd
parquet_row_count <- function(path) {
  if (!requireNamespace("arrow", quietly = TRUE)) return(NA_integer_)
  tryCatch(
    nrow(arrow::read_parquet(path, as_data_frame = FALSE)),
    error = function(e) NA_integer_
  )
}

#' Current git HEAD SHA, or NA if not in a git repo / git missing.
#' @noRd
git_head_sha <- function() {
  out <- suppressWarnings(
    system2("git", c("rev-parse", "HEAD"),
            stdout = TRUE, stderr = FALSE)
  )
  if (length(out) == 0 || !is.character(out)) return(NA_character_)
  trimws(out[[1]])
}
