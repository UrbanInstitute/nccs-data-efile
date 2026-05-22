#' Fetch and cache IRS XSD bundles for a tax year + version
#'
#' Downloads the IRS XSD ZIP for `(tax_year, version)`, unpacks it
#' under the local cache directory, and mirrors the contents to
#' `s3://nccsdata/processed/efile/schemas/{tax_year}/{version}/`.
#'
#' Idempotent: if the local cache directory already contains XSD
#' files, the download and unpack are skipped. If the S3 prefix
#' already contains objects, the mirror is skipped (cheap `aws s3 ls`
#' check, not per-file ETag verification - if you need stronger
#' guarantees, pass `force = TRUE`).
#'
#' See ADR 0001 section 5. The URL pattern lives in
#' `config$xsd$url_pattern` and is an open item until verified
#' against the IRS download pages.
#'
#' @param tax_year Integer or character tax year.
#' @param version XSD version string.
#' @param config Loaded config list.
#' @param force If `TRUE`, re-download and re-upload regardless of
#'   cache state.
#'
#' @return Invisibly, a list with `tax_year`, `version`,
#'   `local_dir`, `s3_prefix`, `downloaded` (logical), and
#'   `mirrored` (logical).
#' @export
fetch_xsds <- function(tax_year,
                       version,
                       config = load_config(),
                       force = FALSE) {
  pattern <- config$xsd$url_pattern
  if (is.null(pattern) || !nzchar(pattern)) {
    stop("config$xsd$url_pattern is not pinned (ADR 0001 open item #2)")
  }
  url <- format_xsd_url(pattern, tax_year, version)

  local_dir <- xsd_cache_path(tax_year, version, config)
  s3_prefix <- xsd_s3_prefix(tax_year, version, config)

  downloaded <- FALSE
  if (force || !xsd_cache_populated(local_dir)) {
    dir.create(local_dir, recursive = TRUE, showWarnings = FALSE)
    zip_path <- tempfile(fileext = ".zip")
    on.exit(unlink(zip_path), add = TRUE)
    cli::cli_alert_info("Fetching {url}")
    utils::download.file(url, zip_path, mode = "wb", quiet = TRUE)
    utils::unzip(zip_path, exdir = local_dir)
    downloaded <- TRUE
    cli::cli_alert_success("Unpacked XSD bundle to {local_dir}")
  } else {
    cli::cli_alert_info("XSD cache hit: {local_dir}")
  }

  mirrored <- FALSE
  aws_profile <- config$aws$profile
  if (force || !s3_prefix_populated(s3_prefix, aws_profile)) {
    aws_s3_sync(local_dir, s3_prefix, aws_profile = aws_profile)
    mirrored <- TRUE
    cli::cli_alert_success("Mirrored XSDs to {s3_prefix}")
  } else {
    cli::cli_alert_info("XSD S3 mirror already populated: {s3_prefix}")
  }

  invisible(list(
    tax_year = tax_year, version = version,
    local_dir = local_dir, s3_prefix = s3_prefix,
    downloaded = downloaded, mirrored = mirrored
  ))
}

#' Substitute {tax_year} and {version} into a URL pattern.
#' @noRd
format_xsd_url <- function(pattern, tax_year, version) {
  out <- gsub("{tax_year}", as.character(tax_year), pattern, fixed = TRUE)
  out <- gsub("{version}", as.character(version), out, fixed = TRUE)
  out
}

#' S3 prefix for a cached XSD bundle.
#' @noRd
xsd_s3_prefix <- function(tax_year, version, config = load_config()) {
  base <- config$vendored$irs_xsd_cache_s3_prefix %||%
    "s3://nccsdata/processed/efile/schemas/"
  if (!endsWith(base, "/")) base <- paste0(base, "/")
  sprintf("%s%s/%s/", base, tax_year, version)
}

#' Whether a local XSD cache directory has any .xsd files.
#' @noRd
xsd_cache_populated <- function(dir) {
  dir.exists(dir) &&
    length(list.files(dir, pattern = "\\.xsd$", recursive = TRUE)) > 0
}

#' Whether an S3 prefix lists any objects.
#' @noRd
s3_prefix_populated <- function(s3_prefix, aws_profile = NULL) {
  args <- c("s3", "ls", s3_prefix)
  if (!is.null(aws_profile)) args <- c(args, "--profile", aws_profile)
  out <- suppressWarnings(
    system2("aws", args, stdout = TRUE, stderr = FALSE)
  )
  length(out) > 0
}

#' Sync a local directory to S3.
#' @noRd
aws_s3_sync <- function(local_dir, s3_prefix, aws_profile = NULL) {
  args <- c("s3", "sync", local_dir, s3_prefix)
  if (!is.null(aws_profile)) args <- c(args, "--profile", aws_profile)
  status <- system2("aws", args, stdout = FALSE, stderr = FALSE)
  if (!identical(status, 0L)) {
    stop(sprintf("aws s3 sync %s -> %s failed (exit %s)",
                 local_dir, s3_prefix, status))
  }
  invisible(TRUE)
}
