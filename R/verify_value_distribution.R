#' Verify the extracted value distribution against configured thresholds
#'
#' Samples up to `sample_size` rows per `(tax_year, form_type)` from
#' an extracted data.frame and checks per-field assertions defined in
#' `config$verification$fields`:
#'
#'   - `type`            character; coercion sanity (currently only
#'                       "double" is enforced; others noop).
#'   - `min`, `max`      numeric value bounds for non-null observations.
#'   - `null_rate_min`,  acceptable null-rate window for the field.
#'     `null_rate_max`
#'
#' See ADR 0001 section 6. Thresholds in `inst/config.yml` are
#' placeholders until pinned against the first vintage's distribution
#' (ADR open item #1).
#'
#' @param extracted Data.frame produced by extracting many filings -
#'   one row per filing, with at minimum `tax_year`, `form_type`, and
#'   one column per field under verification.
#' @param config Loaded config list.
#' @param strict If `TRUE`, error on any breach.
#'
#' @return A list with `passed` (logical), `checks_run` (integer),
#'   `breaches` (list of breach descriptions), and `per_field`
#'   (named list of per-field summaries).
#' @export
verify_value_distribution <- function(extracted,
                                      config = load_config(),
                                      strict = TRUE) {
  fields <- config$verification$fields
  if (is.null(fields) || length(fields) == 0) {
    stop("config$verification$fields is empty - nothing to verify")
  }
  sample_size <- config$verification$sample_size_per_form_year %||% 1000L

  sample_df <- stratified_sample(extracted, sample_size)
  per_field <- list()
  breaches <- list()

  for (nm in names(fields)) {
    if (!(nm %in% names(sample_df))) {
      breaches[[length(breaches) + 1]] <- list(
        field = nm, reason = "field missing from extracted data"
      )
      next
    }
    spec <- fields[[nm]]
    scoped_df <- if (!is.null(spec$forms_applicable) &&
                     length(spec$forms_applicable) > 0 &&
                     "form_type" %in% names(sample_df)) {
      sample_df[sample_df$form_type %in% spec$forms_applicable, , drop = FALSE]
    } else {
      sample_df
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
    sample_size_used = nrow(sample_df)
  )
}

#' Stratified sample: up to `n` rows per (tax_year, form_type).
#' @noRd
stratified_sample <- function(df, n) {
  if (!all(c("tax_year", "form_type") %in% names(df))) {
    return(df)  # nothing to stratify by; caller gets the full frame
  }
  groups <- split(df, list(df$tax_year, df$form_type), drop = TRUE)
  picked <- lapply(groups, function(g) {
    if (nrow(g) <= n) g else g[sample(nrow(g), n), , drop = FALSE]
  })
  do.call(rbind, picked)
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
    nn <- suppressWarnings(as.numeric(non_null))
    numeric_summary <- list(
      min = min(nn, na.rm = TRUE),
      max = max(nn, na.rm = TRUE),
      p50 = stats::quantile(nn, 0.5, na.rm = TRUE, names = FALSE),
      p99 = stats::quantile(nn, 0.99, na.rm = TRUE, names = FALSE)
    )
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
