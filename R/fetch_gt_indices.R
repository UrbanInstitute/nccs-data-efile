#' Fetch and filter GT data lake indices
#'
#' Reads the per-tax-year CSVs under
#' `s3://gt990datalake-rawdata/Indices/990xmls/yearly/` (anonymous
#' read), keeps the most recent snapshot per year, parses, filters by
#' scope, and returns a single data.frame of filings to extract.
#'
#' The full `Indices/990xmls/` prefix is ~358 GB across many
#' snapshots; this function pulls only the latest snapshot per
#' in-scope tax_year, which keeps a single-year fetch under a minute.
#'
#' Per ADR 0001 section 9.
#'
#' GT yearly index columns (post-2025 snapshots):
#'   `BuildTs, DAF, DateSigned, DocStatus, EIN, FileSha256,
#'   FileSizeBytes, FormType, GrossReceipts, ..., ObjectId, ...,
#'   ReturnVersion, ..., TaxPeriod, TaxYear, ..., URL, ZipFile`
#'
#' Normalized output columns:
#'   `filing_receipt_id, ein, tax_period, tax_year, form_type,
#'   return_version, object_id, url, s3_key`
#'
#' `s3_key` is `s3://` form of `url` for parity with the
#' `fetch_irs_direct()` shape; downstream `extract_filing()` prefers
#' the local_path or s3_key fields.
#'
#' @param config Loaded config list.
#' @param local_cache_dir Where to cache yearly CSVs. Defaults to
#'   `~/.cache/nccs-data-efile/gt-indices/`.
#' @param skip_sync If `TRUE`, do not fetch from S3; just re-parse
#'   whatever is on disk.
#'
#' @return A data.frame with one row per filing in scope.
#' @export
fetch_gt_indices <- function(config = load_config(),
                             local_cache_dir = NULL,
                             skip_sync = FALSE) {
  local_cache_dir <- local_cache_dir %||%
    path.expand("~/.cache/nccs-data-efile/gt-indices")
  yearly_prefix <- paste0(
    sub("/$", "", config$upstream$gt_data_lake$index_prefix %||%
        "s3://gt990datalake-rawdata/Indices/990xmls/"),
    "/yearly/"
  )
  tax_years <- as.integer(config$scope$tax_years %||% integer(0))
  if (length(tax_years) == 0) {
    stop("config$scope$tax_years is empty - nothing to fetch")
  }
  dir.create(local_cache_dir, recursive = TRUE, showWarnings = FALSE)

  cached <- character(0)
  for (ty in tax_years) {
    local_path <- file.path(local_cache_dir,
                            sprintf("%d_latest.csv", ty))
    if (!skip_sync && !file.exists(local_path)) {
      remote_key <- latest_yearly_key(yearly_prefix, ty)
      if (is.null(remote_key)) {
        cli::cli_alert_warning("no GT yearly index for tax_year {ty}")
        next
      }
      cli::cli_alert_info("fetching {remote_key} -> {local_path}")
      aws_s3_cp_anon(remote_key, local_path)
    }
    if (file.exists(local_path)) cached <- c(cached, local_path)
  }
  if (length(cached) == 0) {
    stop("no GT yearly index files cached - nothing to parse")
  }

  parts <- lapply(cached, parse_gt_index_csv)
  df <- do.call(rbind, parts)
  df <- filter_gt_index(df, config$scope)
  df$s3_key <- url_to_s3_uri(df$url)
  df
}

#' Pick the latest snapshot key for a given tax_year by lexically
#' sorting the `_created_on_YYYY-MM-DD.csv` suffix.
#' @noRd
latest_yearly_key <- function(yearly_prefix, tax_year) {
  ls_out <- suppressWarnings(system2(
    "aws",
    c("s3", "ls", "--no-sign-request", yearly_prefix),
    stdout = TRUE, stderr = FALSE
  ))
  if (length(ls_out) == 0) return(NULL)
  files <- sub(".*\\s", "", ls_out)
  matches <- grep(
    sprintf("^%d_efiledata_xmls_created_on_\\d{4}-\\d{2}-\\d{2}\\.csv$",
            tax_year),
    files, value = TRUE
  )
  if (length(matches) == 0) return(NULL)
  paste0(yearly_prefix, sort(matches, decreasing = TRUE)[[1]])
}

#' Parse a single GT yearly index CSV with column normalization.
#'
#' Forces ObjectId, EIN, and TaxPeriod to character: ObjectId is an
#' 18-digit IRS DLN that overflows R's double precision (~2^53), and
#' EIN / TaxPeriod have leading zeros worth preserving.
#' @noRd
parse_gt_index_csv <- function(path) {
  header <- names(utils::read.csv(path, nrows = 1, check.names = FALSE))
  col_classes <- stats::setNames(rep(NA, length(header)), header)
  for (k in c("ObjectId", "EIN", "TaxPeriod")) {
    if (k %in% header) col_classes[[k]] <- "character"
  }
  raw <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE,
                         colClasses = col_classes)
  rename_map <- c(
    EIN           = "ein",
    FormType      = "form_type",
    TaxPeriod     = "tax_period",
    TaxYear       = "tax_year",
    ObjectId      = "object_id",
    ReturnVersion = "return_version",
    URL           = "url"
  )
  for (old in names(rename_map)) {
    if (old %in% names(raw)) names(raw)[names(raw) == old] <- rename_map[[old]]
  }
  required <- unname(rename_map)
  missing <- setdiff(required, names(raw))
  if (length(missing) > 0) {
    stop(sprintf("GT index %s missing columns: %s",
                 basename(path), paste(missing, collapse = ", ")))
  }
  raw$tax_year <- suppressWarnings(as.integer(raw$tax_year))
  raw$filing_receipt_id <- as.character(raw$object_id)
  raw[, c("filing_receipt_id", "ein", "tax_period", "tax_year",
          "form_type", "return_version", "object_id", "url")]
}

#' Filter a GT index data.frame by scope.forms / scope.tax_years.
#' @noRd
filter_gt_index <- function(df, scope) {
  if (!is.null(scope$forms) && length(scope$forms) > 0) {
    df <- df[df$form_type %in% scope$forms, , drop = FALSE]
  }
  if (!is.null(scope$tax_years) && length(scope$tax_years) > 0) {
    df <- df[df$tax_year %in% as.integer(scope$tax_years), , drop = FALSE]
  }
  if (!is.null(scope$index_filter) && nzchar(scope$index_filter)) {
    df <- df[grepl(scope$index_filter, df$object_id), , drop = FALSE]
  }
  df
}

#' Convert the GT `URL` column (virtual-hosted https) to s3:// form.
#' @noRd
url_to_s3_uri <- function(urls) {
  vapply(urls, function(u) {
    if (is.na(u) || !nzchar(u)) return(NA_character_)
    m <- regmatches(u, regexec("^https?://([^.]+)\\.s3\\.amazonaws\\.com/(.+)$", u))[[1]]
    if (length(m) != 3) return(NA_character_)
    sprintf("s3://%s/%s", m[[2]], m[[3]])
  }, character(1))
}

#' Anonymous `aws s3 cp`.
#' @noRd
aws_s3_cp_anon <- function(src, dst) {
  status <- system2(
    "aws",
    c("s3", "cp", "--no-sign-request", src, dst),
    stdout = FALSE, stderr = FALSE
  )
  if (!identical(status, 0L)) {
    stop(sprintf("aws s3 cp (anon) %s -> %s failed (exit %s)",
                 src, dst, status))
  }
  invisible(TRUE)
}
