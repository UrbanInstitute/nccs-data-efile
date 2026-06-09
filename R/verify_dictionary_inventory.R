#' Verify the Layer 2 dictionary against the Layer 1 XSD inventory
#'
#' Supply-side concordance gate (Phase 0.5): asserts that every
#' `xpath_claims` tuple in the curated dictionary points at an element
#' that actually exists in the mechanical Layer 1 inventory, and that
#' the element is a leaf (carries a value). This is the mechanical
#' successor to `verify_claim_coverage()` - that checks *demand*
#' coverage (every in-scope filing's (year, version) resolves some
#' claim); this checks the claims themselves against ground truth, so a
#' typo'd or renamed XPath is an unrepresentable build state rather than
#' a silent stream of NAs.
#'
#' Version strings are normalized before joining: the dictionary uses
#' dotted versions (matching the extractor's `parse_return_version`)
#' while the inventory carries the IRS folder convention (hyphenated for
#' 2022/2023). Comparing them raw is exactly the `5-0`-vs-`5.0` mismatch
#' that nulled TY2022/2023 in v2026.05 (ADR 0002 Outcome).
#'
#' Claim statuses:
#'   - `ok`                     resolves to a leaf element of a
#'                              data_type-consistent XSD type.
#'   - `missing_xpath`          cell exists but the XPath is absent (HARD).
#'   - `not_leaf`               XPath exists but is a container (HARD).
#'   - `type_mismatch`          a numeric (`double`/`int`) field resolves
#'                              to a non-numeric XSD type (HARD). This is
#'                              the type-class check that replaced the
#'                              retired per-field `phase0_claims`
#'                              expected_type; non-numeric data_types are
#'                              recorded but not enforced yet.
#'   - `unverifiable_no_cell`   no inventory cell for that (year,
#'                              version) - a gated schema with no public
#'                              XSD. WARN, not a failure.
#'
#' Coverage is bounded by the inventory's root scope (currently
#' 990 + 990PF + ReturnHeader): a dictionary claim on a form/schedule
#' the inventory does not yet enumerate would read as `missing_xpath`.
#' Widen `default_inventory_roots()` before adding such claims.
#'
#' @param dict Layer 2 dictionary (from `load_dictionary()`).
#' @param inventory Layer 1 inventory data.frame (from
#'   `load_layer1_inventory()` / `build_all_xsd_inventories()`).
#' @param config Loaded config list.
#' @param strict If TRUE, error on any HARD breach.
#' @return Invisibly, a list with `passed`, `results` (per-claim
#'   data.frame), and status counts.
#' @export
verify_dictionary_against_inventory <- function(dict, inventory,
                                                config = load_config(),
                                                strict = TRUE) {
  claims <- expand_xpath_claims(dict)
  if (nrow(claims) == 0) stop("dictionary has no xpath_claims to verify")
  dtypes <- stats::setNames(dict$data_type, dict$nccs_name)

  inv <- inventory
  inv$ckey <- paste(inv$tax_year, canon_version(inv$version), sep = "|")

  res <- do.call(rbind, lapply(seq_len(nrow(claims)), function(k) {
    cl <- claims[k, ]
    ckey <- paste(cl$tax_year, canon_version(cl$version), sep = "|")
    cell <- inv[inv$ckey == ckey, , drop = FALSE]
    status <- "unverifiable_no_cell"
    xsd_type <- NA_character_
    type_plausible <- NA
    if (nrow(cell) > 0) {
      hit <- cell[cell$xpath == cl$xpath, , drop = FALSE]
      if (nrow(hit) == 0) {
        status <- "missing_xpath"
      } else {
        xsd_type <- hit$xsd_type[[1]]
        status <- if (isTRUE(hit$is_leaf[[1]])) "ok" else "not_leaf"
        type_plausible <- xsd_type_plausible(dtypes[[cl$field]], xsd_type)
        # A numeric field landing on a non-numeric XSD type is a hard
        # failure - the mechanical type-class check that replaced the
        # retired per-field phase0_claims expected_type. Non-numeric
        # data_types return NA (not enforced yet).
        if (identical(status, "ok") && isFALSE(type_plausible)) {
          status <- "type_mismatch"
        }
      }
    }
    data.frame(field = cl$field, tax_year = cl$tax_year, version = cl$version,
               xpath = cl$xpath, status = status, xsd_type = xsd_type,
               type_plausible = type_plausible, stringsAsFactors = FALSE)
  }))

  hard <- res$status %in% c("missing_xpath", "not_leaf", "type_mismatch")
  n_unver <- sum(res$status == "unverifiable_no_cell")
  passed <- !any(hard)

  if (n_unver > 0) {
    cells <- unique(sprintf("%sv%s", res$tax_year[res$status == "unverifiable_no_cell"],
                            res$version[res$status == "unverifiable_no_cell"]))
    cli::cli_alert_warning(
      "{n_unver} claim(s) unverifiable - no Layer 1 cell (gated schema): {paste(cells, collapse=', ')}")
  }
  if (strict && !passed) {
    m <- res[hard, c("field", "tax_year", "version", "xpath", "status", "xsd_type")]
    tbl <- paste(utils::capture.output(print(m, row.names = FALSE)), collapse = "\n")
    stop(sprintf(
      "dictionary<->inventory: %d claim(s) failed verification against the Layer 1 XSD inventory:\n%s",
      sum(hard), tbl), call. = FALSE)
  }
  cli::cli_alert_success(
    "dictionary<->inventory: {sum(res$status=='ok')}/{nrow(res)} claims verified against Layer 1 ({n_unver} unverifiable, {sum(hard)} failed)")

  invisible(list(
    passed = passed, results = res,
    n_ok = sum(res$status == "ok"),
    n_missing = sum(res$status == "missing_xpath"),
    n_not_leaf = sum(res$status == "not_leaf"),
    n_type_mismatch = sum(res$status == "type_mismatch"),
    n_unverifiable = n_unver
  ))
}

#' Expand a dictionary's `xpath_claims` cells into one row per claim.
#' @noRd
expand_xpath_claims <- function(dict) {
  rows <- list()
  for (i in seq_len(nrow(dict))) {
    cell <- dict$xpath_claims[i]
    if (is.na(cell) || !nzchar(cell)) next
    for (t in trimws(strsplit(cell, ";", fixed = TRUE)[[1]])) {
      parts <- strsplit(t, ":", fixed = TRUE)[[1]]
      if (length(parts) < 3) next
      rows[[length(rows) + 1]] <- data.frame(
        field = dict$nccs_name[i], tax_year = parts[[1]], version = parts[[2]],
        xpath = paste(parts[-c(1, 2)], collapse = ":"), stringsAsFactors = FALSE)
    }
  }
  if (length(rows) == 0) {
    return(data.frame(field = character(0), tax_year = character(0),
                      version = character(0), xpath = character(0),
                      stringsAsFactors = FALSE))
  }
  do.call(rbind, rows)
}

#' Normalize an XSD version string to the dotted convention used by the
#' dictionary and the extractor (`5-0` -> `5.0`).
#' @noRd
canon_version <- function(v) gsub("-", ".", as.character(v))

#' Coarse plausibility of an XSD type against a declared data_type.
#' Only checked for numeric data_types in v1 (NA = not checked); never
#' fatal, surfaced as an informational warning.
#' @noRd
xsd_type_plausible <- function(data_type, xsd_type) {
  if (is.null(data_type) || length(data_type) == 0 || is.na(xsd_type)) return(NA)
  if (data_type %in% c("double", "int")) {
    return(grepl("Amount|Decimal|Ratio|Numeric|Integer|Count|Qty|Percent|Cnt|Num",
                 xsd_type, ignore.case = TRUE))
  }
  NA
}

#' Load the Layer 1 inventory for the dictionary<->inventory gate.
#'
#' @param config Loaded config list.
#' @param source `"build"` (regenerate from the local XSD cache - the
#'   self-contained default), `"local"` (read a parquet at `path`), or
#'   `"s3"` (download the published `latest/` inventory).
#' @param path Parquet path for `source="local"`.
#' @return A data.frame.
#' @export
load_layer1_inventory <- function(config = load_config(),
                                  source = c("build", "local", "s3"),
                                  path = NULL) {
  source <- match.arg(source)
  if (source == "build") return(build_all_xsd_inventories(config))
  if (source == "local") {
    if (is.null(path)) stop("path required for source='local'")
    return(as.data.frame(arrow::read_parquet(path)))
  }
  prefix <- layer1_s3_prefix(config, "latest")
  tmp <- tempfile(fileext = ".parquet")
  args <- c("s3", "cp", paste0(prefix, "layer1_xsd_inventory.parquet"), tmp)
  if (!is.null(config$aws$profile)) args <- c(args, "--profile", config$aws$profile)
  if (system2("aws", args) != 0) {
    stop("failed to download Layer 1 inventory from S3: ", prefix)
  }
  as.data.frame(arrow::read_parquet(tmp))
}
