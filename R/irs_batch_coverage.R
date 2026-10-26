# ---- IRS batch coverage of a published e-file release ----------------------
#
# Answers one question for a release that NODC publishes into the nccs-efile
# bucket: for every monthly IRS release (an "XML batch"), how many of the
# filings the IRS lists are in the published tables, and where did the
# release get the XML from (the GivingTuesday lake or the NCCS patch
# store). Run after each IRS release. Backlog U1; found while handling the
# October 2026 Tepper request (batch 2026_TEOS_XML_09A absent because it
# postdated the build).

#' Read the header table of a published e-file release
#'
#' Reads the per-filing header table (`F9-P00-T00-HEADER-{year}` for the
#' 990 and 990-EZ release, `PF-P00-T00-HEADER-{year}` for the 990-PF
#' release) over anonymous HTTPS with DuckDB, keeping only the columns the
#' coverage check needs. Only those columns are transferred, so a run moves
#' a few megabytes per year rather than the whole table.
#'
#' @param release Release prefix under `public/` in the nccs-efile bucket,
#'   for example `"efile_v3_1"` or `"efilepf_v3_1"`.
#' @param tax_years Integer vector of tax years whose header files to read.
#'   A year with no file is skipped with a message (releases do not carry
#'   every year).
#' @param bucket_url Base URL of the bucket.
#' @return A data.frame with `object_id` (the IRS object id, without the
#'   `OID-` prefix), `return_type`, `tax_year`, `source_host` (host name of
#'   the XML the row was parsed from) and `release`.
#' @details Needs the `duckdb` and `DBI` packages (Suggests). The header
#'   table name is chosen from the release prefix: `efilepf_` releases use
#'   the `PF-` table, every other release the `F9-` table.
#' @export
read_release_header <- function(release,
                                tax_years,
                                bucket_url = "https://nccs-efile.s3.amazonaws.com") {
  for (package_name in c("duckdb", "DBI")) {
    if (!requireNamespace(package_name, quietly = TRUE)) {
      stop("read_release_header() needs the ", package_name, " package")
    }
  }
  table_name <- if (startsWith(release, "efilepf_")) "PF-P00-T00-HEADER" else "F9-P00-T00-HEADER"
  urls <- sprintf("%s/public/%s/%s-%d.parquet", bucket_url, release, table_name, as.integer(tax_years))

  # Keep only the years that exist; a HEAD request per year is cheap.
  exists <- vapply(urls, url_exists, logical(1))
  if (!any(exists)) {
    stop("no header files found for release ", release, " and tax years ",
         paste(range(tax_years), collapse = " to "))
  }
  for (missing_url in urls[!exists]) {
    cli::cli_alert_info("no header file at {missing_url}; skipped")
  }

  connection <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
  on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(connection, "INSTALL httpfs; LOAD httpfs;")
  url_list <- paste(sprintf("'%s'", urls[exists]), collapse = ", ")
  query <- sprintf(
    paste(
      "SELECT regexp_replace(OBJECTID, '^OID-', '') AS object_id,",
      "       RETURN_TYPE AS return_type,",
      "       CAST(TAX_YEAR AS INTEGER) AS tax_year,",
      "       regexp_extract(URL, '^https?://([^/]+)/', 1) AS source_host",
      "FROM read_parquet([%s], union_by_name = true)"
    ),
    url_list
  )
  header <- DBI::dbGetQuery(connection, query)
  header$release <- release
  header
}

#' TRUE when an HTTPS URL answers a HEAD request with status 200.
#' @noRd
url_exists <- function(url) {
  response <- tryCatch(
    system2("curl", c("-sI", "--max-time", "60", "-o", "/dev/null", "-w", "%{http_code}", shQuote(url)),
            stdout = TRUE, stderr = FALSE),
    error = function(error) ""
  )
  identical(trimws(response), "200")
}

#' Last-Modified date of an HTTPS object, or NA.
#' @noRd
url_last_modified <- function(url) {
  header_lines <- tryCatch(
    system2("curl", c("-sI", "--max-time", "60", shQuote(url)), stdout = TRUE, stderr = FALSE),
    error = function(error) character(0)
  )
  line <- grep("^last-modified:", header_lines, ignore.case = TRUE, value = TRUE)
  if (length(line) != 1) return(as.Date(NA))
  as.Date(trimws(sub("^last-modified:", "", line, ignore.case = TRUE)), format = "%a, %d %b %Y", tz = "GMT")
}

#' Classify the host an XML file was read from
#'
#' @param source_host Character vector of host names.
#' @return `"givingtuesday"`, `"nccs_patch"` or `"other"` per element.
#' @noRd
classify_source_host <- function(source_host) {
  ifelse(grepl("^gt990datalake", source_host), "givingtuesday",
  ifelse(grepl("^nccs-efile", source_host), "nccs_patch",
  ifelse(is.na(source_host) | !nzchar(source_host), "other", "other")))
}

#' Compare one release against the IRS index, batch by batch
#'
#' Pure function over two data.frames: the IRS annual index rows (from
#' `fetch_irs_indices()`) and the release header rows (from
#' `read_release_header()`). Filings are matched on the IRS object id.
#'
#' @param irs IRS index rows: `object_id`, `return_type`, `xml_batch_id`.
#' @param header Release header rows: `object_id`, `source_host`.
#' @param forms Return types the release is meant to hold (for example
#'   `c("990", "990EZ")`). IRS rows of other types are not counted.
#' @param build_date Date the release was published. Batches the IRS
#'   published after it get status `after_build`.
#' @param batch_dates Publication date per batch from `irs_batch_dates()`,
#'   or NULL (then `published` is NA and no batch is marked `after_build`).
#' @return One row per IRS batch: `xml_batch_id`, `published`, `n_irs`,
#'   `n_found`, `n_missing`, `missing_share`, `n_from_givingtuesday`,
#'   `n_from_nccs_patch`, `n_from_other`, `status`. Status is `complete`
#'   (nothing missing), `partial`, `missing` (nothing found) or
#'   `after_build`.
#' @export
summarise_batch_coverage <- function(irs, header, forms, build_date, batch_dates = NULL) {
  in_scope <- irs[irs$return_type %in% forms, c("object_id", "xml_batch_id"), drop = FALSE]
  if (nrow(in_scope) == 0) stop("no IRS index rows for forms ", paste(forms, collapse = ", "))

  header_match <- match(in_scope$object_id, header$object_id)
  in_scope$found <- !is.na(header_match)
  in_scope$source <- ifelse(in_scope$found, classify_source_host(header$source_host[header_match]), NA_character_)

  by_batch <- split(in_scope, in_scope$xml_batch_id)
  rows <- lapply(names(by_batch), function(batch_id) {
    batch <- by_batch[[batch_id]]
    data.frame(
      xml_batch_id = batch_id,
      n_irs = nrow(batch),
      n_found = sum(batch$found),
      n_from_givingtuesday = sum(batch$source %in% "givingtuesday"),
      n_from_nccs_patch = sum(batch$source %in% "nccs_patch"),
      n_from_other = sum(batch$source %in% "other"),
      stringsAsFactors = FALSE
    )
  })
  report <- do.call(rbind, rows)
  report$n_missing <- report$n_irs - report$n_found
  report$missing_share <- round(report$n_missing / report$n_irs, 4)
  report$published <- as.Date(NA)
  if (!is.null(batch_dates)) {
    report$published <- as.Date(batch_dates$published)[match(report$xml_batch_id, batch_dates$xml_batch_id)]
  }
  after_build <- !is.na(report$published) & !is.na(build_date) & report$published > as.Date(build_date)
  report$status <- ifelse(after_build, "after_build",
                   ifelse(report$n_missing == 0, "complete",
                   ifelse(report$n_found == 0, "missing", "partial")))
  report <- report[order(report$xml_batch_id),
                   c("xml_batch_id", "published", "n_irs", "n_found", "n_missing", "missing_share",
                     "n_from_givingtuesday", "n_from_nccs_patch", "n_from_other", "status")]
  rownames(report) <- NULL
  report
}

#' Latest IRS batch a release is complete through
#'
#' @param report Output of `summarise_batch_coverage()`.
#' @param max_missing_share A batch counts as complete here when its
#'   missing share is at or under this value (default one in a thousand),
#'   so a handful of stragglers does not move the cutoff back a month. The
#'   per-batch `status` stays exact; only this summary tolerates them.
#' @return The last batch id (in id order) before the first batch that is
#'   `after_build` or has more than `max_missing_share` missing, ignoring
#'   `no_batch_id`; NA when the first batch is already incomplete.
#' @export
complete_through_batch <- function(report, max_missing_share = 0.001) {
  ordered <- report[report$xml_batch_id != "no_batch_id", ]
  ordered <- ordered[order(ordered$xml_batch_id), ]
  complete <- ordered$status != "after_build" & ordered$missing_share <= max_missing_share
  if (length(complete) == 0 || !complete[1]) return(NA_character_)
  first_gap <- which(!complete)
  last_complete <- if (length(first_gap) == 0) nrow(ordered) else first_gap[1] - 1L
  ordered$xml_batch_id[last_complete]
}

#' Run the IRS batch coverage check for the published e-file releases
#'
#' For each release named, reads the IRS index files for `index_years`,
#' reads the release's header table for every tax year the index mentions,
#' and writes one CSV per release with one row per IRS batch. Prints a
#' short summary with the batch each release is complete through.
#'
#' @param releases Named list: release prefix to the forms it holds, for
#'   example
#'   `list(efile_v3_1 = c("990", "990EZ"), efilepf_v3_1 = "990PF")`.
#' @param index_years IRS index years to read (default: the current year).
#' @param config Package config (for the IRS URL patterns and cache).
#' @param out_dir Directory for the CSVs. One file per release and run:
#'   `{release}-irs-batch-coverage-{index years}-{run date}.csv`.
#' @param skip_sync Passed to `fetch_irs_indices()` and `irs_batch_dates()`.
#' @return Invisibly, a named list of reports (one per release) with
#'   attributes `build_date` and `complete_through`.
#' @details The release build date is the `Last-Modified` of the latest
#'   header file read. Header files are read for every tax year present in
#'   the in-scope IRS rows; years with no file in the release are skipped.
#' @export
run_irs_batch_coverage <- function(releases = list(efile_v3_1 = c("990", "990EZ"), efilepf_v3_1 = "990PF"),
                                   index_years = as.integer(format(Sys.Date(), "%Y")),
                                   config = load_config(),
                                   out_dir = "out/irs-batch-coverage",
                                   skip_sync = FALSE) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  run_date <- format(Sys.Date(), "%Y-%m-%d")

  irs <- fetch_irs_indices(index_years, config = config, skip_sync = skip_sync)
  batch_dates <- irs_batch_dates(unique(irs$xml_batch_id), config = config, skip_sync = skip_sync)

  reports <- list()
  for (release in names(releases)) {
    forms <- releases[[release]]
    in_scope <- irs[irs$return_type %in% forms, , drop = FALSE]
    tax_years <- sort(unique(in_scope$tax_year))
    cli::cli_h2("{release}: {nrow(in_scope)} IRS filings of type {paste(forms, collapse = '/')}, tax years {min(tax_years)} to {max(tax_years)}")

    header <- read_release_header(release, tax_years)
    table_name <- if (startsWith(release, "efilepf_")) "PF-P00-T00-HEADER" else "F9-P00-T00-HEADER"
    build_date <- url_last_modified(sprintf("https://nccs-efile.s3.amazonaws.com/public/%s/%s-%d.parquet",
                                            release, table_name, max(tax_years[tax_years %in% header$tax_year])))

    report <- summarise_batch_coverage(irs, header, forms, build_date, batch_dates)
    report <- cbind(release = release, index_years = paste(index_years, collapse = "+"),
                    build_date = as.character(build_date), checked_on = run_date, report,
                    stringsAsFactors = FALSE)
    through <- complete_through_batch(report)
    attr(report, "build_date") <- build_date
    attr(report, "complete_through") <- through

    out_path <- file.path(out_dir, sprintf("%s-irs-batch-coverage-%s-%s.csv",
                                           release, paste(index_years, collapse = "+"), run_date))
    utils::write.csv(report, out_path, row.names = FALSE)
    cli::cli_alert_success("{release}: built {build_date}, complete through {through %||% 'none'}; wrote {out_path}")
    print(report[, c("xml_batch_id", "published", "n_irs", "n_missing", "missing_share",
                     "n_from_givingtuesday", "n_from_nccs_patch", "status")], row.names = FALSE)
    reports[[release]] <- report
  }
  invisible(reports)
}
