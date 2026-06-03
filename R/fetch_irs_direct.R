#' Fetch IRS-direct e-file ZIPs as a fallback to the GT data lake
#'
#' Downloads the per-(tax_year, month) e-file ZIP bundle that the IRS
#' publishes on its Form 990 Series Downloads page, unpacks it under a
#' local cache directory, and returns an index data.frame matching the
#' shape of `fetch_gt_indices()` so the downstream `extract_filing()`
#' surface is unaware which upstream was used.
#'
#' See ADR 0001 section 9. Activation is via `upstream.primary:
#' irs_direct` in config. The exact ZIP URL pattern is configurable
#' because the IRS page layout has shifted historically.
#'
#' @param tax_year Integer or character tax year.
#' @param month Integer 1..12 - the calendar month of the IRS bundle.
#' @param config Loaded config list.
#' @param local_cache_dir Where to unpack ZIPs. Defaults to
#'   `~/.cache/nccs-data-efile/irs-direct/{tax_year}/{month}/`.
#' @param url_pattern Optional override; otherwise read from
#'   `config$upstream$irs_direct$url_pattern`. Substitutions
#'   `{tax_year}` and `{month}` (zero-padded) are honored.
#'
#' @return A data.frame with one row per XML in the unpacked bundle,
#'   carrying `filing_receipt_id`, `ein`, `tax_period`, `tax_year`,
#'   `form_type`, `object_id`, `local_path`. `s3_key` is `NA` (these
#'   filings did not come from S3).
#' @export
fetch_irs_direct <- function(tax_year,
                             month,
                             config = load_config(),
                             local_cache_dir = NULL,
                             url_pattern = NULL) {
  pattern <- url_pattern %||% config$upstream$irs_direct$url_pattern
  if (is.null(pattern) || !nzchar(pattern)) {
    stop("config$upstream$irs_direct$url_pattern is not pinned (ADR 0001 open item)")
  }
  local_cache_dir <- local_cache_dir %||% path.expand(file.path(
    "~/.cache/nccs-data-efile/irs-direct",
    as.character(tax_year), sprintf("%02d", as.integer(month))
  ))
  dir.create(local_cache_dir, recursive = TRUE, showWarnings = FALSE)

  if (length(list.files(local_cache_dir, pattern = "\\.xml$", recursive = TRUE)) == 0) {
    url <- format_irs_url(pattern, tax_year, month)
    zip_path <- tempfile(fileext = ".zip")
    on.exit(unlink(zip_path), add = TRUE)
    cli::cli_alert_info("Fetching IRS bundle {url}")
    utils::download.file(url, zip_path, mode = "wb", quiet = TRUE)
    utils::unzip(zip_path, exdir = local_cache_dir)
  } else {
    cli::cli_alert_info("IRS direct cache hit: {local_cache_dir}")
  }

  xmls <- list.files(local_cache_dir, pattern = "\\.xml$",
                     full.names = TRUE, recursive = TRUE)
  if (length(xmls) == 0) {
    stop(sprintf("no XMLs found after unpacking IRS bundle in %s", local_cache_dir))
  }

  # Per-filing index is built from the XML files themselves. The IRS
  # bundle includes an index.json/csv in some years; cheaper to derive
  # from filenames + a light XML peek for EIN + form type.
  build_irs_index(xmls, tax_year)
}

#' Substitute {tax_year} and {month} into a URL pattern.
#' @noRd
format_irs_url <- function(pattern, tax_year, month) {
  m <- sprintf("%02d", as.integer(month))
  out <- gsub("{tax_year}", as.character(tax_year), pattern, fixed = TRUE)
  gsub("{month}", m, out, fixed = TRUE)
}

#' Build a fetch_gt_indices-shaped data.frame from unpacked XMLs.
#' EIN and form type are read from each XML's header. This is
#' deliberately cheap (only the first ReturnHeader element is read).
#' @noRd
build_irs_index <- function(xml_paths, tax_year) {
  rows <- lapply(xml_paths, function(p) {
    h <- tryCatch(read_irs_xml_header(p),
                  error = function(e) list(ein = NA_character_,
                                           form_type = NA_character_,
                                           tax_period = NA_character_,
                                           filing_receipt_id = NA_character_))
    data.frame(
      filing_receipt_id = h$filing_receipt_id %||% NA_character_,
      ein               = h$ein %||% NA_character_,
      tax_period        = h$tax_period %||% NA_character_,
      tax_year          = as.integer(tax_year),
      form_type         = h$form_type %||% NA_character_,
      object_id         = tools::file_path_sans_ext(basename(p)),
      local_path        = p,
      s3_key            = NA_character_,
      stringsAsFactors  = FALSE
    )
  })
  do.call(rbind, rows)
}

#' Pull EIN, form type, tax period, and DLN/return-id from a 990 XML
#' header. Uses namespace-aware XPath (not xml_ns_strip) for the same
#' reason as extract_filing - stripping cliffs to minutes on large
#' filings; see inst/scripts/profile_parse_cost.R.
#' @noRd
read_irs_xml_header <- function(path) {
  doc <- xml2::read_xml(path)
  ns <- irs_efile_ns()
  pick <- function(xp) {
    n <- xml2::xml_find_first(doc, ns_qualify_xpath(xp, names(ns)[[1]]), ns = ns)
    if (inherits(n, "xml_missing")) NA_character_ else xml2::xml_text(n, trim = TRUE)
  }
  list(
    ein = pick("/Return/ReturnHeader/Filer/EIN"),
    form_type = pick("/Return/ReturnHeader/ReturnTypeCd"),
    tax_period = pick("/Return/ReturnHeader/TaxPeriodEndDt"),
    filing_receipt_id = pick("/Return/ReturnHeader/ReturnId")
  )
}
