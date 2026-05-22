#' Load the NCCS layer-2 dictionary
#'
#' Reads `inst/concordance/nccs_dictionary.csv` (or an explicit path)
#' into a data.frame. See ADR 0001 section 7 for the column schema.
#'
#' @param path Explicit path. Defaults to the installed dictionary
#'   under `inst/concordance/`.
#' @return A data.frame.
#' @export
load_dictionary <- function(path = NULL) {
  if (is.null(path)) {
    path <- system.file("concordance", "nccs_dictionary.csv",
                        package = "nccs.data.efile")
    if (!nzchar(path)) {
      stop("nccs_dictionary.csv not found in installed package")
    }
  }
  utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE)
}

#' Resolve the XPath claim for a (field, tax_year, version) lookup
#'
#' The dictionary's `xpath_claims` column carries one or more
#' `tax_year:version:xpath` tuples, semicolon-separated. This helper
#' returns the XPath string for the requested combination, or `NA`
#' if no claim applies.
#'
#' Tuple format is parsed strictly: exactly two colons before the
#' XPath. The XPath itself may contain colons (namespace prefixes).
#'
#' @param dict A dictionary data.frame as returned by
#'   `load_dictionary()`.
#' @param field Value of the `nccs_name` column.
#' @param tax_year Integer or character tax year.
#' @param version Version string.
#'
#' @return Character XPath or `NA_character_`.
#' @export
resolve_xpath <- function(dict, field, tax_year, version) {
  row <- dict[dict$nccs_name == field, , drop = FALSE]
  if (nrow(row) == 0) return(NA_character_)
  if (nrow(row) > 1) {
    stop(sprintf("dictionary has %d rows for nccs_name='%s'", nrow(row), field))
  }
  parse_xpath_claim(row$xpath_claims, tax_year, version)
}

#' Parse the xpath_claims cell and pick the matching tuple.
#' @noRd
parse_xpath_claim <- function(claims_cell, tax_year, version) {
  if (is.null(claims_cell) || is.na(claims_cell) || !nzchar(claims_cell)) {
    return(NA_character_)
  }
  tuples <- trimws(strsplit(claims_cell, ";", fixed = TRUE)[[1]])
  for (t in tuples) {
    parts <- strsplit(t, ":", fixed = TRUE)[[1]]
    if (length(parts) < 3) next
    ty <- parts[[1]]; ver <- parts[[2]]
    xp <- paste(parts[-c(1, 2)], collapse = ":")
    if (identical(as.character(ty), as.character(tax_year)) &&
        identical(as.character(ver), as.character(version))) {
      return(xp)
    }
  }
  NA_character_
}
