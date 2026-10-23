#' Fetch the IRS annual e-file index files
#'
#' The IRS publishes one index CSV per calendar year of release
#' (`index_YYYY.csv`) listing every e-filed return it has made public, with
#' the `XML_BATCH_ID` of the monthly ZIP the return shipped in. These are
#' small (under 100 MB each) and are the authoritative list of what exists,
#' independent of any mirror.
#'
#' @param index_years Integer vector of calendar years to fetch.
#' @param config Package config; `config$upstream$irs_index$url_pattern`
#'   gives the URL with `{year}` substituted.
#' @param local_cache_dir Directory for the downloaded files.
#' @param skip_sync When TRUE, only files already in the cache are read.
#' @return A data.frame with columns `object_id`, `return_type`,
#'   `tax_period`, `tax_year`, `xml_batch_id`, `index_year`.
#' @details `tax_year` is derived from `TAX_PERIOD` (YYYYMM, period end):
#'   the end year when the period ends in December, otherwise the end year
#'   minus one. This matches the IRS and GivingTuesday `TaxYear` convention
#'   for fiscal-year filers.
#' @export
fetch_irs_indices <- function(index_years,
                              config = load_config(),
                              local_cache_dir = NULL,
                              skip_sync = FALSE) {
  local_cache_dir <- local_cache_dir %||%
    path.expand("~/.cache/nccs-data-efile/irs-indices")
  url_pattern <- config$upstream$irs_index$url_pattern %||%
    "https://apps.irs.gov/pub/epostcard/990/xml/{year}/index_{year}.csv"
  dir.create(local_cache_dir, recursive = TRUE, showWarnings = FALSE)

  parts <- list()
  for (year in as.integer(index_years)) {
    local_path <- file.path(local_cache_dir, sprintf("index_%d.csv", year))
    if (!skip_sync && !file.exists(local_path)) {
      url <- gsub("{year}", year, url_pattern, fixed = TRUE)
      cli::cli_alert_info("fetching {url} -> {local_path}")
      status <- utils::download.file(url, local_path, quiet = TRUE, mode = "wb")
      if (status != 0) stop("download of ", url, " failed (status ", status, ")")
    }
    if (file.exists(local_path)) {
      parts[[as.character(year)]] <- parse_irs_index_csv(local_path, year)
    } else {
      cli::cli_alert_warning("no IRS index for {year}")
    }
  }
  if (length(parts) == 0) stop("no IRS index files available - nothing to parse")
  do.call(rbind, unname(parts))
}

#' Parse one IRS annual index CSV.
#' @noRd
parse_irs_index_csv <- function(path, index_year) {
  header <- names(data.table::fread(path, nrows = 0, showProgress = FALSE))
  wanted <- intersect(c("OBJECT_ID", "RETURN_TYPE", "TAX_PERIOD", "XML_BATCH_ID"), header)
  missing <- setdiff(c("OBJECT_ID", "RETURN_TYPE", "TAX_PERIOD"), header)
  if (length(missing) > 0) {
    stop(sprintf("IRS index %s missing columns: %s", basename(path), paste(missing, collapse = ", ")))
  }
  raw <- data.table::fread(path, select = wanted,
                           colClasses = list(character = wanted), showProgress = FALSE)
  raw <- as.data.frame(raw)
  # Index files before 2024 carry no XML_BATCH_ID; those filings cannot be
  # attributed to a batch and are grouped under "no_batch_id".
  batch <- if ("XML_BATCH_ID" %in% header) raw$XML_BATCH_ID else rep("no_batch_id", nrow(raw))
  batch[is.na(batch) | !nzchar(batch)] <- "no_batch_id"
  data.frame(
    object_id = raw$OBJECT_ID,
    return_type = raw$RETURN_TYPE,
    tax_period = raw$TAX_PERIOD,
    tax_year = irs_tax_year(raw$TAX_PERIOD),
    xml_batch_id = batch,
    index_year = as.integer(index_year),
    stringsAsFactors = FALSE
  )
}

#' Tax year from an IRS TAX_PERIOD (YYYYMM period end).
#' @noRd
irs_tax_year <- function(tax_period) {
  end_year <- as.integer(substr(tax_period, 1, 4))
  end_month <- as.integer(substr(tax_period, 5, 6))
  ifelse(end_month == 12L, end_year, end_year - 1L)
}

#' Release month of an IRS XML batch id such as `2025_TEOS_XML_09A`.
#' @noRd
batch_release_month <- function(xml_batch_id) {
  m <- regmatches(xml_batch_id, regexec("^(\\d{4})_TEOS_XML_(\\d{2})", xml_batch_id))
  as.Date(vapply(m, function(x) {
    if (length(x) < 3) NA_character_ else sprintf("%s-%s-01", x[[2]], x[[3]])
  }, character(1)))
}

#' Verify that the filing index covers every IRS batch
#'
#' Compares the in-scope filings of the IRS annual indices, batch by batch,
#' against the index the build will extract from (normally the GivingTuesday
#' data lake index). A batch whose filings are largely absent from the build
#' index means the mirror skipped an IRS release, and the build would
#' silently under-cover those months.
#'
#' Background: the GivingTuesday index omitted IRS batches 2025_09A,
#' 2025_10A, part of 2026_05A and 2026_08A. The Phase 0 vintage v2026.06
#' was built from that index and lacks 59,092 in-scope filings that the IRS
#' had published before the build (NCCS review, 2026-10-23).
#'
#' @param index The build index as returned by `fetch_gt_indices()`
#'   (column `object_id`), already filtered to scope.
#' @param irs The IRS index as returned by `fetch_irs_indices()`.
#' @param scope `config$scope` (`forms`, `tax_years`).
#' @param as_of Date of the build index snapshot. Batches released in or
#'   after the month of `as_of` may postdate the snapshot (the IRS batch id
#'   carries only the month), so they are reported but not counted as
#'   failures.
#' @param min_batch_filings Batches with fewer in-scope filings than this
#'   are reported but never fail the gate.
#' @param max_missing_share Largest share of a batch's in-scope filings that
#'   may be absent from the build index before the gate fails.
#' @param strict When TRUE (the build default), stop on failure.
#' @return A list with `passed`, `as_of`, `batches` (one row per batch:
#'   `xml_batch_id`, `release_month`, `n_irs`, `n_in_index`, `missing_share`,
#'   `status`) and `failed` (the batch ids that failed). Status values:
#'   `ok`, `missing` (fails the gate), `small`, `after_snapshot`, and
#'   `no_batch_id` for filings from IRS index years that predate the
#'   `XML_BATCH_ID` column (reported, never failed).
#' @export
verify_index_coverage <- function(index, irs, scope,
                                  as_of = Sys.Date(),
                                  min_batch_filings = 100L,
                                  max_missing_share = 0.05,
                                  strict = TRUE) {
  forms <- scope$forms %||% character(0)
  tax_years <- as.integer(scope$tax_years %||% integer(0))
  in_scope <- irs
  if (length(forms) > 0) in_scope <- in_scope[in_scope$return_type %in% forms, , drop = FALSE]
  if (length(tax_years) > 0) in_scope <- in_scope[in_scope$tax_year %in% tax_years, , drop = FALSE]
  if (nrow(in_scope) == 0) stop("no IRS index rows in scope - check scope$forms / scope$tax_years")

  in_scope$present <- in_scope$object_id %in% as.character(index$object_id)
  by_batch <- split(in_scope, in_scope$xml_batch_id)
  batches <- do.call(rbind, lapply(names(by_batch), function(b) {
    d <- by_batch[[b]]
    data.frame(xml_batch_id = b, n_irs = nrow(d), n_in_index = sum(d$present),
               stringsAsFactors = FALSE)
  }))
  batches$release_month <- batch_release_month(batches$xml_batch_id)
  batches$missing_share <- 1 - batches$n_in_index / batches$n_irs
  snapshot_month <- as.Date(format(as.Date(as_of), "%Y-%m-01"))
  after_snapshot <- !is.na(batches$release_month) & batches$release_month >= snapshot_month
  small <- batches$n_irs < min_batch_filings
  over <- batches$missing_share > max_missing_share
  no_batch <- batches$xml_batch_id == "no_batch_id"
  batches$status <- ifelse(no_batch, "no_batch_id",
                    ifelse(after_snapshot, "after_snapshot",
                    ifelse(small & over, "small",
                    ifelse(over, "missing", "ok"))))
  batches <- batches[order(batches$xml_batch_id),
                     c("xml_batch_id", "release_month", "n_irs", "n_in_index",
                       "missing_share", "status")]
  failed <- batches$xml_batch_id[batches$status == "missing"]
  result <- list(passed = length(failed) == 0, as_of = as.character(as.Date(as_of)),
                 batches = batches, failed = failed)

  if (length(failed) > 0) {
    detail <- batches[batches$status == "missing", ]
    msg <- sprintf("%s: %d of %d in-scope filings absent from the build index",
                   detail$xml_batch_id, detail$n_irs - detail$n_in_index, detail$n_irs)
    if (strict) {
      stop("index coverage gate failed for ", length(failed), " IRS batch(es):\n  ",
           paste(msg, collapse = "\n  "), "\n  (threshold ", max_missing_share,
           "; the build index is missing IRS releases)")
    }
    cli::cli_alert_warning("index coverage: {length(failed)} IRS batch(es) under-covered")
  } else {
    cli::cli_alert_success("index coverage: all {nrow(batches)} IRS batches covered (as of {result$as_of})")
  }
  result
}

#' Calendar years of IRS index files that can hold filings for the scope.
#' @noRd
irs_index_years_for_scope <- function(scope, as_of = Sys.Date()) {
  tax_years <- as.integer(scope$tax_years %||% integer(0))
  if (length(tax_years) == 0) stop("scope$tax_years is empty")
  seq.int(min(tax_years) + 1L, as.integer(format(as.Date(as_of), "%Y")))
}
