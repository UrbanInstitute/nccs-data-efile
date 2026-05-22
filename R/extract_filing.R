#' Extract a single 990 filing into a one-row data.frame
#'
#' Given an index row (with at minimum `s3_key`, `ein`, `tax_year`,
#' `form_type`, `filing_receipt_id`) and a layer-2 dictionary,
#' downloads the XML, applies each dictionary row's XPath claim for
#' the filing's `(tax_year, version)`, and returns one row with one
#' column per dictionary `nccs_name`.
#'
#' Designed to run inside `furrr::future_map`: on any failure
#' (network, parse, missing element, type coercion) the function
#' returns a row of `NA`s plus an `_extract_error` column rather than
#' aborting the whole vintage build.
#'
#' See ADR 0001 section 9. The same surface is used by the IRS direct
#' fallback - the only difference is how the XML is obtained.
#'
#' @param row A single-row data.frame or named list. Must carry
#'   either `s3_key` (anonymous S3 fetch via https) or `local_path`
#'   (already-downloaded XML).
#' @param dict A dictionary data.frame; see `load_dictionary()`.
#' @param version XSD version string to resolve XPath claims for.
#'   Phase 0 uses a single version per tax year; later phases will
#'   detect this per filing.
#'
#' @return A one-row data.frame with key columns + one column per
#'   `nccs_name` + `_extract_error` (character, `NA` on success).
#' @export
extract_filing <- function(row, dict, version) {
  row <- as.list(row)
  fields <- dict$nccs_name
  out_skeleton <- function(err = NA_character_) {
    vals <- stats::setNames(
      lapply(seq_along(fields), function(i) NA),
      fields
    )
    df <- data.frame(
      filing_receipt_id = as.character(row$filing_receipt_id %||% NA),
      ein               = as.character(row$ein %||% NA),
      tax_year          = as.integer(row$tax_year %||% NA),
      form_type         = as.character(row$form_type %||% NA),
      stringsAsFactors  = FALSE
    )
    for (f in fields) df[[f]] <- NA
    df[["_extract_error"]] <- err
    df
  }

  xml_path <- tryCatch(
    obtain_xml(row),
    error = function(e) {
      return(structure(NA, error = conditionMessage(e)))
    }
  )
  if (is.na(xml_path)) {
    return(out_skeleton(attr(xml_path, "error", exact = TRUE) %||% "obtain_xml failed"))
  }
  on.exit(if (isTRUE(attr(xml_path, "tempfile"))) unlink(xml_path), add = TRUE)

  doc <- tryCatch(xml2::read_xml(xml_path),
                  error = function(e) e)
  if (inherits(doc, "error")) return(out_skeleton(conditionMessage(doc)))

  df <- out_skeleton()
  df[["_extract_error"]] <- NA_character_
  for (i in seq_len(nrow(dict))) {
    nm <- dict$nccs_name[[i]]
    xp <- parse_xpath_claim(dict$xpath_claims[[i]], row$tax_year, version)
    if (is.na(xp)) next
    val <- tryCatch(
      eval_xpath_value(doc, xp, type = dict$data_type[[i]]),
      error = function(e) NA
    )
    df[[nm]] <- val
  }
  df
}

#' Resolve the XML for an index row.
#' Prefers `local_path`; otherwise downloads via the bucket's
#' public https endpoint (no AWS credentials required).
#' @noRd
obtain_xml <- function(row) {
  if (!is.null(row$local_path) && nzchar(row$local_path)) {
    if (!file.exists(row$local_path)) {
      stop(sprintf("local_path does not exist: %s", row$local_path))
    }
    return(row$local_path)
  }
  if (is.null(row$s3_key) || !nzchar(row$s3_key)) {
    stop("row must carry either local_path or s3_key")
  }
  url <- s3_uri_to_https(row$s3_key)
  tmp <- tempfile(fileext = ".xml")
  utils::download.file(url, tmp, mode = "wb", quiet = TRUE)
  attr(tmp, "tempfile") <- TRUE
  tmp
}

#' Convert s3://bucket/key to https URL (virtual-hosted style).
#' @noRd
s3_uri_to_https <- function(s3_key) {
  if (!startsWith(s3_key, "s3://")) {
    stop(sprintf("not an s3:// URI: %s", s3_key))
  }
  rest <- substr(s3_key, 6, nchar(s3_key))
  slash <- regexpr("/", rest, fixed = TRUE)
  if (slash < 1) stop(sprintf("malformed s3:// URI: %s", s3_key))
  bucket <- substr(rest, 1, slash - 1)
  key <- substr(rest, slash + 1, nchar(rest))
  sprintf("https://%s.s3.amazonaws.com/%s", bucket, key)
}

#' Evaluate an XPath against an xml document and coerce to data_type.
#' Returns a length-1 atomic, or NA if the node is missing.
#' @noRd
eval_xpath_value <- function(doc, xpath, type = "string") {
  # The IRS e-file XML carries a default namespace. xml2 does not let
  # XPath match a default namespace without binding it explicitly, so
  # we strip namespaces from the document. This is acceptable here
  # because Phase 0 XPaths are absolute and reference unique
  # local-names; full layer-1 work will swap to namespace-aware XPath.
  doc_local <- xml2::xml_ns_strip(doc)
  node <- xml2::xml_find_first(doc_local, xpath)
  if (inherits(node, "xml_missing")) return(NA)
  txt <- xml2::xml_text(node, trim = TRUE)
  if (!nzchar(txt)) return(NA)
  switch(
    type %||% "string",
    double = suppressWarnings(as.numeric(txt)),
    int    = suppressWarnings(as.integer(txt)),
    bool   = tolower(txt) %in% c("true", "1", "yes"),
    txt
  )
}
