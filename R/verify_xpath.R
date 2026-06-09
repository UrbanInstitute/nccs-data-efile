#' Verify an XPath claim against the Layer 1 XSD inventory
#'
#' Looks up `xpath` in the mechanical Layer 1 inventory for the
#' `(tax_year, version)` cell and reports whether it resolves to a leaf
#' element, plus its declared XSD type. As of Phase 0.5 this is a
#' lookup against materialized ground truth (`build_xsd_inventory()`),
#' not the former per-call XSD tree-walk - the inventory is built once
#' and every verification reads it. Version strings are normalized
#' (dotted vs the hyphenated IRS folder convention) before matching.
#'
#' @param xpath Absolute XPath, e.g. `/Return/ReturnData/IRS990/GovernmentGrantsAmt`.
#' @param tax_year Integer or character tax year.
#' @param version Version string (dotted or hyphenated; normalized).
#' @param expected_type Optional XSD type to compare `actual_type`
#'   against. When `NULL`, `matches_expected` is `NA`.
#' @param inventory Optional Layer 1 inventory data.frame (from
#'   `build_xsd_inventory()` / `build_all_xsd_inventories()`). When
#'   `NULL`, built for just this `(tax_year, version)` cell.
#' @param config Loaded config list.
#'
#' @return A list with `found` (logical), `actual_type` (character or
#'   `NA`), `is_leaf` (logical or `NA`), `matches_expected` (logical or
#'   `NA`), `xpath`, `tax_year`, `version`, `expected_type`.
#' @export
verify_xpath <- function(xpath,
                         tax_year,
                         version,
                         expected_type = NULL,
                         inventory = NULL,
                         config = load_config()) {
  if (is.null(inventory)) {
    inventory <- build_xsd_inventory(tax_year, version, config = config)
  }
  cv <- canon_version(version)
  hit <- inventory[inventory$tax_year == as.character(tax_year) &
                   canon_version(inventory$version) == cv &
                   inventory$xpath == xpath, , drop = FALSE]
  found <- nrow(hit) > 0
  actual_type <- if (found) hit$xsd_type[[1]] else NA_character_
  list(
    xpath = xpath,
    tax_year = as.character(tax_year),
    version = as.character(version),
    expected_type = expected_type %||% NA_character_,
    found = found,
    actual_type = actual_type,
    is_leaf = if (found) isTRUE(hit$is_leaf[[1]]) else NA,
    matches_expected = if (is.null(expected_type)) NA else identical(actual_type, expected_type)
  )
}

#' Local cache path for an unpacked XSD bundle.
#' @noRd
xsd_cache_path <- function(tax_year, version, config = load_config()) {
  base <- path.expand(config$xsd$local_cache_dir %||% "~/.cache/nccs-data-efile/xsds")
  file.path(base, as.character(tax_year), as.character(version))
}

#' Load and index all XSD files under a directory.
#'
#' Some element local-names are defined in multiple XSD files
#' (e.g. `Return`, `ReturnData` appear once per form family - 990,
#' 990EZ, 990PF, 990T). The index stores ALL candidates per name so
#' the inventory walker can try each branch.
#'
#' Returns a list with:
#'  - `elements`: named list mapping local-name -> list of candidate
#'    records, each with `type`, `file`, `node`.
#'  - `complex_types`: named list mapping type local-name -> xml_node
#'    (last writer wins; type names appear to be unique in practice).
#'  - `docs`: list of read_xml docs, kept alive so subtree XPath stays
#'    valid (xml2 nodes lose context if their doc is GC'd).
#' @noRd
load_xsd_schema <- function(xsd_dir) {
  files <- list.files(xsd_dir, pattern = "\\.xsd$", full.names = TRUE, recursive = TRUE)
  if (length(files) == 0) {
    stop(sprintf("no .xsd files under %s", xsd_dir))
  }
  ns <- c(xs = "http://www.w3.org/2001/XMLSchema")
  elements <- list()
  complex_types <- list()
  docs <- list()
  for (f in files) {
    doc <- xml2::read_xml(f)
    docs[[f]] <- doc
    for (e in xml2::xml_find_all(doc, "//xs:element[@name]", ns)) {
      nm <- xml2::xml_attr(e, "name")
      ty <- xml2::xml_attr(e, "type")
      if (is.na(ty)) {
        inline <- xml2::xml_find_first(e, "./xs:complexType", ns)
        ty <- if (!inherits(inline, "xml_missing")) "(anonymous)" else NA_character_
      } else {
        ty <- sub("^[^:]+:", "", ty)
      }
      rec <- list(type = ty, file = basename(f), node = e)
      elements[[nm]] <- c(elements[[nm]] %||% list(), list(rec))
    }
    for (ct in xml2::xml_find_all(doc, "//xs:complexType[@name]", ns)) {
      nm <- xml2::xml_attr(ct, "name")
      complex_types[[nm]] <- ct
    }
  }
  list(elements = elements, complex_types = complex_types, ns = ns,
       docs = docs)
}
