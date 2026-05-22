#' Vendor the NODC concordance file at a pinned SHA
#'
#' Downloads the NODC `irs-efile-master-concordance-file` repo's
#' `concordance.csv` at the configured commit SHA and mirrors it to
#' `s3://nccsdata/processed/efile/concordance/{sha}_{YYYY-MM-DD}.csv`.
#' Idempotent: if the target S3 key already exists, the upload is
#' skipped (the GitHub raw file at a given SHA is immutable, so this
#' is safe).
#'
#' See ADR 0001 section 8.
#'
#' @param sha Commit SHA to pin. Defaults to
#'   `config$vendored$nodc_concordance_sha`.
#' @param s3_prefix Destination S3 prefix. Defaults to
#'   `config$vendored$nodc_concordance_s3_prefix`.
#' @param config Loaded config list (see [load_config()]).
#' @param aws_profile AWS CLI profile name used for the `aws s3` calls.
#' @param dry_run If `TRUE`, log actions without uploading.
#'
#' @return Invisibly, a list with `sha`, `s3_uri`, `bytes`,
#'   `sha256`, and `uploaded` (logical: `FALSE` if skipped because the
#'   key already existed).
#' @export
vendor_nodc <- function(sha = NULL,
                        s3_prefix = NULL,
                        config = load_config(),
                        aws_profile = NULL,
                        dry_run = FALSE) {
  sha <- sha %||% config$vendored$nodc_concordance_sha
  if (is.null(sha) || !nzchar(sha)) {
    stop("NODC concordance SHA is not pinned (config$vendored$nodc_concordance_sha)")
  }
  s3_prefix <- s3_prefix %||% config$vendored$nodc_concordance_s3_prefix
  aws_profile <- aws_profile %||% config$aws$profile

  s3_uri <- nodc_s3_uri(sha, s3_prefix, today = Sys.Date())

  if (s3_object_exists(s3_uri, aws_profile = aws_profile)) {
    cli::cli_alert_info("NODC vendor: {s3_uri} already exists - skipping")
    return(invisible(list(
      sha = sha, s3_uri = s3_uri, uploaded = FALSE,
      bytes = NA_integer_, sha256 = NA_character_
    )))
  }

  url <- nodc_raw_url(sha)
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)

  cli::cli_alert_info("Fetching {url}")
  utils::download.file(url, tmp, mode = "wb", quiet = TRUE)

  bytes <- file.info(tmp)$size
  sha256 <- digest::digest(file = tmp, algo = "sha256")

  if (dry_run) {
    cli::cli_alert_info("DRY RUN: would upload {tmp} ({bytes} bytes) to {s3_uri}")
    return(invisible(list(
      sha = sha, s3_uri = s3_uri, uploaded = FALSE,
      bytes = bytes, sha256 = sha256
    )))
  }

  aws_s3_cp(tmp, s3_uri, aws_profile = aws_profile)
  cli::cli_alert_success("Uploaded {bytes} bytes -> {s3_uri} (sha256 {substr(sha256, 1, 12)})")

  invisible(list(
    sha = sha, s3_uri = s3_uri, uploaded = TRUE,
    bytes = bytes, sha256 = sha256
  ))
}

#' GitHub raw URL for the NODC concordance file at a pinned SHA.
#' @noRd
nodc_raw_url <- function(sha) {
  sprintf(
    "https://raw.githubusercontent.com/Nonprofit-Open-Data-Collective/irs-efile-master-concordance-file/%s/concordance.csv",
    sha
  )
}

#' S3 URI for the vendored concordance: `{prefix}{sha}_{YYYY-MM-DD}.csv`.
#' @noRd
nodc_s3_uri <- function(sha, s3_prefix, today = Sys.Date()) {
  prefix <- if (endsWith(s3_prefix, "/")) s3_prefix else paste0(s3_prefix, "/")
  sprintf("%s%s_%s.csv", prefix, sha, format(today, "%Y-%m-%d"))
}

#' Check whether an S3 object exists by shelling out to `aws s3 ls`.
#' @noRd
s3_object_exists <- function(s3_uri, aws_profile = NULL) {
  args <- c("s3", "ls", s3_uri)
  if (!is.null(aws_profile)) args <- c(args, "--profile", aws_profile)
  status <- suppressWarnings(system2("aws", args, stdout = FALSE, stderr = FALSE))
  identical(status, 0L)
}

#' Upload a local file to S3 via `aws s3 cp`.
#' @noRd
aws_s3_cp <- function(local_path, s3_uri, aws_profile = NULL) {
  args <- c("s3", "cp", local_path, s3_uri)
  if (!is.null(aws_profile)) args <- c(args, "--profile", aws_profile)
  status <- system2("aws", args, stdout = FALSE, stderr = FALSE)
  if (!identical(status, 0L)) {
    stop(sprintf("aws s3 cp %s -> %s failed (exit %s)", local_path, s3_uri, status))
  }
  invisible(TRUE)
}
