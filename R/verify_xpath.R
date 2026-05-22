#' Verify an XPath claim against a cached IRS XSD
#'
#' Walks an XSD directory for a given (tax_year, version) and resolves
#' the element targeted by `xpath`. Returns a structured result
#' indicating whether the element exists and whether its declared type
#' matches `expected_type`.
#'
#' The walker is deliberately schema-aware but XPath-syntax-naive: it
#' accepts simple absolute paths of the form `/A/B/C` (no predicates,
#' no axes, no wildcards). Phase 0 claims fit this shape; if a future
#' phase needs predicates, extend `parse_xpath_steps()`.
#'
#' See ADR 0001 section 5.
#'
#' @param xpath Absolute XPath, e.g. `/Return/ReturnData/IRS990/GovernmentGrantsAmt`.
#' @param tax_year Integer or character tax year.
#' @param version XSD version string.
#' @param expected_type Local-name of the expected XSD type.
#' @param xsd_dir Directory containing the unpacked XSDs for the
#'   `(tax_year, version)` bundle. Defaults to
#'   `xsd_cache_path(tax_year, version, config)`.
#' @param config Loaded config list.
#'
#' @return A list with `found` (logical), `actual_type` (character or
#'   `NA`), `matches_expected` (logical), `path_to_element` (character
#'   or `NA`), `xpath`, `tax_year`, `version`, `expected_type`.
#' @export
verify_xpath <- function(xpath,
                         tax_year,
                         version,
                         expected_type,
                         xsd_dir = NULL,
                         config = load_config()) {
  if (is.null(xsd_dir)) {
    xsd_dir <- xsd_cache_path(tax_year, version, config)
  }
  if (!dir.exists(xsd_dir)) {
    stop(sprintf("XSD directory not found: %s", xsd_dir))
  }

  steps <- parse_xpath_steps(xpath)
  schema <- load_xsd_schema(xsd_dir)
  resolved <- resolve_steps(steps, schema)

  result <- list(
    xpath = xpath,
    tax_year = tax_year,
    version = version,
    expected_type = expected_type,
    found = !is.null(resolved$type),
    actual_type = resolved$type %||% NA_character_,
    path_to_element = resolved$path %||% NA_character_,
    matches_expected = NA
  )
  result$matches_expected <- isTRUE(
    identical(result$actual_type, expected_type)
  )
  result
}

#' Local cache path for an unpacked XSD bundle.
#' @noRd
xsd_cache_path <- function(tax_year, version, config = load_config()) {
  base <- path.expand(config$xsd$local_cache_dir %||% "~/.cache/nccs-data-efile/xsds")
  file.path(base, as.character(tax_year), as.character(version))
}

#' Parse a simple absolute XPath into element local-names.
#' Strips namespace prefixes and rejects unsupported syntax.
#' @noRd
parse_xpath_steps <- function(xpath) {
  if (!startsWith(xpath, "/")) {
    stop(sprintf("only absolute XPaths supported, got: %s", xpath))
  }
  if (grepl("[\\[\\]@*]|::", xpath, perl = TRUE)) {
    stop(sprintf("unsupported XPath syntax (predicates/axes/wildcards): %s", xpath))
  }
  raw <- strsplit(sub("^/", "", xpath), "/", fixed = TRUE)[[1]]
  # strip ns prefixes: "tns:Foo" -> "Foo"
  sub("^[^:]+:", "", raw)
}

#' Load and index all XSD files under a directory.
#'
#' Some element local-names are defined in multiple XSD files
#' (e.g. `Return`, `ReturnData` appear once per form family - 990,
#' 990EZ, 990PF, 990T). The index stores ALL candidates per name so
#' the walker can try each branch.
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

#' Walk parsed XPath steps through the schema, type-by-type.
#'
#' Handles both XSD child patterns:
#'   - `<xs:element name="Foo" type="FooType"/>`  (inline definition)
#'   - `<xs:element ref="Foo"/>`                  (reference to a
#'     top-level element defined elsewhere - common in IRS XSDs)
#'
#' When the parent has a named complex type, children are searched
#' inside that type's tree. When the parent has an inline
#' (anonymous) complex type, children are searched inside the
#' parent's own node. Either way, hits are matched against `@name`
#' first, then `@ref`. A `ref` resolves to `schema$elements[[ref]]`
#' to recover the referenced element's type.
#'
#' Returns list(type = final element type or NULL, path = traversal trace).
#' @noRd
resolve_steps <- function(steps, schema) {
  if (length(steps) == 0) return(list(type = NULL, path = NULL))

  candidates <- schema$elements[[steps[[1]]]]
  if (is.null(candidates) || length(candidates) == 0) {
    return(list(type = NULL, path = NULL))
  }
  for (cand in candidates) {
    r <- walk_from(cand, steps[-1L], schema)
    if (!is.null(r)) {
      return(list(
        type = r$type,
        path = paste0("/", paste(c(steps[[1]], r$trace), collapse = "/"))
      ))
    }
  }
  list(type = NULL, path = NULL)
}

#' Recursive depth-first walk: from `current` element record, take
#' `remaining` steps, trying every candidate child at each step.
#' Returns NULL if no chain resolves; otherwise list(type, trace).
#' @noRd
walk_from <- function(current, remaining, schema) {
  if (length(remaining) == 0) {
    return(list(type = current$type, trace = character(0)))
  }
  step <- remaining[[1]]
  search_roots <- search_roots_for(current, schema)
  for (root in search_roots) {
    child_candidates <- find_child_elements(root, step, schema)
    for (child in child_candidates) {
      r <- walk_from(child, remaining[-1L], schema)
      if (!is.null(r)) {
        return(list(type = r$type, trace = c(step, r$trace)))
      }
    }
  }
  NULL
}

#' Return all nodes that could contain child elements for `current`.
#' Handles named complex types, inline anonymous types, and
#' `<xs:complexContent><xs:extension base="X">` chains (the inline
#' type extends X; search both the extension itself and X's contents).
#' @noRd
search_roots_for <- function(current, schema) {
  roots <- list()
  parent_type <- current$type
  if (is.null(parent_type) || is.na(parent_type) || parent_type == "(anonymous)") {
    roots[[length(roots) + 1]] <- current$node
    # Inline complexType may extend a named base; recurse on that base.
    ext <- xml2::xml_find_first(
      current$node,
      ".//xs:complexContent/xs:extension[@base]",
      schema$ns
    )
    if (!inherits(ext, "xml_missing")) {
      base <- sub("^[^:]+:", "", xml2::xml_attr(ext, "base"))
      base_ct <- schema$complex_types[[base]]
      if (!is.null(base_ct)) roots[[length(roots) + 1]] <- base_ct
    }
  } else {
    ct <- schema$complex_types[[parent_type]]
    if (!is.null(ct)) {
      roots[[length(roots) + 1]] <- ct
      # Named complex type may itself extend a base.
      ext <- xml2::xml_find_first(
        ct,
        ".//xs:complexContent/xs:extension[@base]",
        schema$ns
      )
      if (!inherits(ext, "xml_missing")) {
        base <- sub("^[^:]+:", "", xml2::xml_attr(ext, "base"))
        base_ct <- schema$complex_types[[base]]
        if (!is.null(base_ct)) roots[[length(roots) + 1]] <- base_ct
      }
    }
  }
  roots
}

#' Find all xs:element children matching `step` (by name OR ref).
#' Returns a list of candidate element records (type + node). When a
#' child uses `ref`, the candidates are all top-level elements indexed
#' under that name; when it uses `name`, the candidate is the child
#' itself (with inline type resolution).
#' @noRd
find_child_elements <- function(search_root, step, schema) {
  out <- list()

  by_name <- xml2::xml_find_all(
    search_root,
    sprintf(".//xs:element[@name='%s']", step),
    schema$ns
  )
  for (n in by_name) {
    ty <- xml2::xml_attr(n, "type")
    if (!is.na(ty)) ty <- sub("^[^:]+:", "", ty)
    if (is.na(ty)) {
      inline <- xml2::xml_find_first(n, "./xs:complexType", schema$ns)
      ty <- if (!inherits(inline, "xml_missing")) "(anonymous)" else NA_character_
    }
    out[[length(out) + 1]] <- list(type = ty, node = n)
  }

  by_ref <- xml2::xml_find_first(
    search_root,
    sprintf(".//xs:element[@ref='%s']", step),
    schema$ns
  )
  if (!inherits(by_ref, "xml_missing")) {
    referenced <- schema$elements[[step]]
    if (!is.null(referenced)) {
      out <- c(out, referenced)
    }
  }

  out
}
