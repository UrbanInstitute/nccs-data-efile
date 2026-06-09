#' Verify the dictionary's XPath claims against the Layer 1 inventory
#'
#' Phase 0.5 unified the schema gate: rather than walking the IRS XSDs
#' per entry of a hand-maintained `config$xsd$phase0_claims` list, this
#' builds the mechanical Layer 1 inventory once and verifies the
#' dictionary's own `xpath_claims` against it (existence + leaf +
#' numeric type-class) via `verify_dictionary_against_inventory()`. The
#' return shape is preserved for `_manifest.json`'s `xsd_verification`
#' block (ADR 0001 section 10 / ADR 0014).
#'
#' @param config Loaded config list.
#' @param strict If `TRUE`, error on any hard breach (missing XPath,
#'   non-leaf element, or numeric/type mismatch).
#' @param dict Layer 2 dictionary (defaults to `load_dictionary()`).
#' @param inventory Optional prebuilt Layer 1 inventory; built via
#'   `build_all_xsd_inventories()` when `NULL`.
#'
#' @return A list with `passed`, `checks_run`, `mismatches` (the
#'   non-`ok` claims), `aliases` (version inheritances in scope), and
#'   `results` (the full per-claim data.frame).
#' @export
run_phase0_verification <- function(config = load_config(),
                                    strict = TRUE,
                                    dict = load_dictionary(),
                                    inventory = NULL) {
  if (is.null(inventory)) inventory <- build_all_xsd_inventories(config)
  gate <- verify_dictionary_against_inventory(dict, inventory, config = config,
                                              strict = strict)
  xsd_verification_block(gate, dict, config)
}

#' Map the dictionary<->inventory gate result into the manifest's
#' `xsd_verification` block shape (passed / checks_run / mismatches /
#' aliases), plus the full `results` frame for the on-disk report.
#' @noRd
xsd_verification_block <- function(gate, dict, config) {
  res <- gate$results
  bad <- res[res$status != "ok", , drop = FALSE]
  mismatches <- lapply(seq_len(nrow(bad)), function(i) list(
    field = bad$field[i],
    xpath = bad$xpath[i],
    tax_year = bad$tax_year[i],
    version = bad$version[i],
    status = bad$status[i],
    found = !(bad$status[i] %in% c("missing_xpath", "unverifiable_no_cell")),
    actual_type = bad$xsd_type[i] %||% NA_character_
  ))
  list(
    passed = isTRUE(gate$passed),
    checks_run = nrow(res),
    mismatches = mismatches,
    aliases = inscope_aliases(dict, config),
    results = res
  )
}

#' Version inheritances (aliases) that apply to the dictionary's
#' in-scope `(tax_year, version)` cells - recorded in the manifest so a
#' verification done against inherited XSDs is explicit.
#' @noRd
inscope_aliases <- function(dict, config) {
  claims <- expand_xpath_claims(dict)
  if (nrow(claims) == 0) return(list())
  cells <- unique(claims[, c("tax_year", "version")])
  out <- list()
  for (i in seq_len(nrow(cells))) {
    a <- config$xsd$version_aliases[[cells$tax_year[i]]][[cells$version[i]]]
    if (!is.null(a)) {
      out[[length(out) + 1]] <- list(
        tax_year = cells$tax_year[i],
        version = cells$version[i],
        xsd_from = a$xsd_from,
        reason = a$reason %||% NA_character_
      )
    }
  }
  out
}
