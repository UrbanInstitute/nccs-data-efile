#' Drive the XSD verifier across the Phase 0 XPath claims
#'
#' For every combination of (tax_year, version, claim) defined in
#' config, runs `verify_xpath()` and aggregates the results into a
#' structured report suitable for embedding in `_manifest.json` under
#' the `xsd_verification` key (ADR 0001 section 10).
#'
#' Pass policy: for each (field, tax_year, version), at least one
#' declared XPath variant must resolve to the expected type. Variants
#' that don't resolve are reported but not treated as failure - per
#' ADR 0002 extractor design ("first non-null wins"), the dictionary
#' carries multiple variants to cover schema evolution. Failing the
#' build only when an entire field has no working variant for a given
#' (year, version) matches the actual data-correctness invariant.
#'
#' Fails (errors) in `strict = TRUE` mode when any (field, year,
#' version) cell has zero passing variants. In non-strict mode the
#' caller is responsible for interpreting the returned `passed` flag.
#'
#' See ADR 0001 section 5.
#'
#' @param tax_years Character/integer vector of tax years. Defaults to
#'   `config$scope$tax_years`.
#' @param versions Named list mapping `as.character(tax_year)` to a
#'   character vector of versions to verify for that year. If `NULL`,
#'   versions are discovered by listing subdirectories of the local
#'   XSD cache.
#' @param config Loaded config list.
#' @param strict If `TRUE`, error on any mismatch.
#'
#' @return A list with `passed` (logical), `checks_run` (integer),
#'   `mismatches` (list of failed-check results), and `results`
#'   (data.frame of every check, one row per
#'   (tax_year, version, claim)).
#' @export
run_phase0_verification <- function(tax_years = NULL,
                                    versions = NULL,
                                    config = load_config(),
                                    strict = TRUE) {
  claims <- config$xsd$phase0_claims
  if (is.null(claims) || length(claims) == 0) {
    stop("config$xsd$phase0_claims is empty - nothing to verify")
  }
  tax_years <- tax_years %||% config$scope$tax_years
  if (is.null(tax_years) || length(tax_years) == 0) {
    stop("no tax_years to verify (config$scope$tax_years is empty)")
  }

  rows <- list()
  for (ty in tax_years) {
    vers <- if (is.null(versions)) {
      discover_xsd_versions(ty, config)
    } else {
      versions[[as.character(ty)]]
    }
    if (length(vers) == 0) {
      cli::cli_alert_warning("No XSD versions found for tax_year {ty}; skipping")
      next
    }
    for (v in vers) {
      for (claim in claims) {
        r <- tryCatch(
          verify_xpath(
            xpath = claim$xpath,
            tax_year = ty,
            version = v,
            expected_type = claim$expected_type,
            config = config
          ),
          error = function(e) {
            list(
              xpath = claim$xpath, tax_year = ty, version = v,
              expected_type = claim$expected_type,
              found = FALSE, actual_type = NA_character_,
              matches_expected = FALSE,
              path_to_element = NA_character_,
              error = conditionMessage(e)
            )
          }
        )
        rows[[length(rows) + 1]] <- c(list(field = claim$field), r)
      }
    }
  }

  results <- rows_to_df(rows)
  mismatches <- rows[!vapply(rows, function(r) isTRUE(r$matches_expected), logical(1))]

  # Pass policy: a (field, year, version) cell passes if >=1 variant
  # resolves to the expected type. The build fails only when an entire
  # field has zero passing variants for some (year, version).
  cells <- aggregate_field_cells(results)
  uncovered <- cells[!cells$any_passing, , drop = FALSE]
  passed <- nrow(uncovered) == 0

  if (strict && !passed) {
    cli::cli_alert_danger(
      "XSD verification: {nrow(uncovered)} (field, year, version) cell(s) with zero passing XPath variant(s)"
    )
    for (i in seq_len(nrow(uncovered))) {
      cli::cli_alert_danger(
        "  {uncovered$field[i]} @ {uncovered$tax_year[i]}/{uncovered$version[i]}"
      )
    }
    stop("XSD verification failed (strict mode)")
  }

  list(
    passed = passed,
    checks_run = nrow(results),
    mismatches = mismatches,
    uncovered_cells = uncovered,
    field_coverage = cells,
    results = results
  )
}

#' Aggregate per-XPath results into per-(field, year, version) cells.
#' @noRd
aggregate_field_cells <- function(results) {
  if (nrow(results) == 0) {
    return(data.frame(
      field = character(0), tax_year = character(0),
      version = character(0), n_variants = integer(0),
      n_passing = integer(0), any_passing = logical(0),
      stringsAsFactors = FALSE
    ))
  }
  agg <- stats::aggregate(
    results$matches_expected,
    by = list(
      field = results$field,
      tax_year = results$tax_year,
      version = results$version
    ),
    FUN = function(x) c(n_variants = length(x), n_passing = sum(x))
  )
  data.frame(
    field       = agg$field,
    tax_year    = agg$tax_year,
    version     = agg$version,
    n_variants  = as.integer(agg$x[, "n_variants"]),
    n_passing   = as.integer(agg$x[, "n_passing"]),
    any_passing = as.integer(agg$x[, "n_passing"]) > 0,
    stringsAsFactors = FALSE
  )
}

#' Discover XSD versions present in the local cache for a tax year.
#' @noRd
discover_xsd_versions <- function(tax_year, config) {
  base <- path.expand(config$xsd$local_cache_dir %||% "~/.cache/nccs-data-efile/xsds")
  ty_dir <- file.path(base, as.character(tax_year))
  if (!dir.exists(ty_dir)) return(character(0))
  list.dirs(ty_dir, recursive = FALSE, full.names = FALSE)
}

#' Flatten a list of verify_xpath result lists into a data.frame.
#' @noRd
rows_to_df <- function(rows) {
  if (length(rows) == 0) {
    return(data.frame(
      field = character(0), xpath = character(0),
      tax_year = character(0), version = character(0),
      expected_type = character(0), actual_type = character(0),
      found = logical(0), matches_expected = logical(0),
      path_to_element = character(0),
      stringsAsFactors = FALSE
    ))
  }
  pick <- function(r, k) if (is.null(r[[k]])) NA else r[[k]]
  data.frame(
    field            = vapply(rows, function(r) as.character(pick(r, "field")), character(1)),
    xpath            = vapply(rows, function(r) as.character(pick(r, "xpath")), character(1)),
    tax_year         = vapply(rows, function(r) as.character(pick(r, "tax_year")), character(1)),
    version          = vapply(rows, function(r) as.character(pick(r, "version")), character(1)),
    expected_type    = vapply(rows, function(r) as.character(pick(r, "expected_type")), character(1)),
    actual_type      = vapply(rows, function(r) as.character(pick(r, "actual_type")), character(1)),
    found            = vapply(rows, function(r) isTRUE(pick(r, "found")), logical(1)),
    matches_expected = vapply(rows, function(r) isTRUE(pick(r, "matches_expected")), logical(1)),
    path_to_element  = vapply(rows, function(r) as.character(pick(r, "path_to_element")), character(1)),
    stringsAsFactors = FALSE
  )
}
