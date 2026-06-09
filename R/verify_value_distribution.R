#' Verify the extracted value distribution against configured thresholds
#'
#' Checks per-field assertions defined in `config$verification$fields`
#' over the FULL extracted population (one row per filing):
#'
#'   - `type`            character; coercion sanity (currently only
#'                       "double" is enforced; others noop).
#'   - `min`, `max`      numeric value bounds. These are order
#'                       statistics, so they are evaluated over every
#'                       row, not a sample - a sample cannot bound a
#'                       max (ADR 0002 Outcome, v2026.06 threshold
#'                       note: the GG max $13.2B / Battelle filing and
#'                       the negative-contribution filings only appear
#'                       at the population tail).
#'   - `null_rate_min`,  acceptable null-rate window for the field.
#'     `null_rate_max`
#'
#' See ADR 0001 section 6. Each field's summary carries a heavy-tail
#' diagnostics block (see `tail_diagnostics`) that is also written into
#' the manifest's `value_distribution`.
#'
#' @param extracted Data.frame produced by extracting many filings -
#'   one row per filing, with at minimum `tax_year`, `form_type`, and
#'   one column per field under verification.
#' @param config Loaded config list.
#' @param strict If `TRUE`, error on any breach.
#'
#' @return A list with `passed` (logical), `checks_run` (integer),
#'   `breaches` (list of breach descriptions), `per_field` (named list
#'   of per-field summaries), and `rows_evaluated` (population size).
#' @export
verify_value_distribution <- function(extracted,
                                      config = load_config(),
                                      strict = TRUE) {
  fields <- config$verification$fields
  if (is.null(fields) || length(fields) == 0) {
    stop("config$verification$fields is empty - nothing to verify")
  }

  per_field <- list()
  breaches <- list()

  for (nm in names(fields)) {
    if (!(nm %in% names(extracted))) {
      breaches[[length(breaches) + 1]] <- list(
        field = nm, reason = "field missing from extracted data"
      )
      next
    }
    spec <- fields[[nm]]
    # Scope to the forms the field applies to, over the full population
    # - not a stratified sample. min/max breaches must see the tail.
    scoped_df <- if (!is.null(spec$forms_applicable) &&
                     length(spec$forms_applicable) > 0 &&
                     "form_type" %in% names(extracted)) {
      extracted[extracted$form_type %in% spec$forms_applicable, , drop = FALSE]
    } else {
      extracted
    }
    summary <- summarize_field(scoped_df[[nm]], spec)
    summary$forms_applicable <- spec$forms_applicable
    summary$rows_in_scope <- nrow(scoped_df)
    per_field[[nm]] <- summary
    for (b in summary$breaches) {
      b$field <- nm
      breaches[[length(breaches) + 1]] <- b
    }
  }

  passed <- length(breaches) == 0
  if (strict && !passed) {
    cli::cli_alert_danger("value distribution: {length(breaches)} breach(es)")
    stop("value distribution verification failed (strict mode)")
  }

  list(
    passed = passed,
    checks_run = length(fields),
    breaches = breaches,
    per_field = per_field,
    rows_evaluated = nrow(extracted)
  )
}

#' Per-field summary + breach list given a verification spec.
#' Coerces numeric thresholds defensively: YAML 1.1 leaves
#' `1.0e10` (no `+`) as a string, which would break comparisons.
#' @noRd
summarize_field <- function(vals, spec) {
  for (k in c("min", "max", "null_rate_min", "null_rate_max")) {
    if (!is.null(spec[[k]])) spec[[k]] <- suppressWarnings(as.numeric(spec[[k]]))
  }
  total <- length(vals)
  non_null <- vals[!is.na(vals)]
  null_rate <- if (total == 0) NA_real_ else (total - length(non_null)) / total

  breaches <- list()
  if (!is.null(spec$null_rate_min) && !is.na(null_rate) &&
      null_rate < spec$null_rate_min) {
    breaches[[length(breaches) + 1]] <- list(
      field = NA, reason = "null_rate below configured floor",
      observed = null_rate, threshold = spec$null_rate_min
    )
  }
  if (!is.null(spec$null_rate_max) && !is.na(null_rate) &&
      null_rate > spec$null_rate_max) {
    breaches[[length(breaches) + 1]] <- list(
      field = NA, reason = "null_rate above configured ceiling",
      observed = null_rate, threshold = spec$null_rate_max
    )
  }

  numeric_summary <- list()
  if (identical(spec$type, "double") && length(non_null) > 0) {
    numeric_summary <- tail_diagnostics(non_null, spec$min, spec$max)
    if (!is.null(spec$min) && numeric_summary$min < spec$min) {
      breaches[[length(breaches) + 1]] <- list(
        field = NA, reason = "min below configured floor",
        observed = numeric_summary$min, threshold = spec$min
      )
    }
    if (!is.null(spec$max) && numeric_summary$max > spec$max) {
      breaches[[length(breaches) + 1]] <- list(
        field = NA, reason = "max above configured ceiling",
        observed = numeric_summary$max, threshold = spec$max
      )
    }
  }

  list(
    n = total,
    n_non_null = length(non_null),
    null_rate = null_rate,
    numeric = numeric_summary,
    breaches = breaches
  )
}
