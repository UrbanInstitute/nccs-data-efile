#' Heavy-tail diagnostics for one numeric column
#'
#' Order statistics plus tail-mass concentration, computed over the
#' FULL population passed in (no sampling). Min, max, and the upper
#' quantiles are order statistics: a sample cannot bound them, so the
#' distribution gate and the quality report compute them over every
#' row, not a stratified sample (see ADR 0002 Outcome, the v2026.06
#' threshold note - the published GG max $13.2B / Battelle and the
#' negative-contribution filings only show up at the population tail).
#'
#' Tail-mass concentration (`top_*_mass_share`) is the share of the
#' column's total dollar mass held by the largest 1% / 0.1% of
#' filings - the same framing as the parse-cost "top-1 file = 60% of
#' CPU" diagnostic, applied to dollars. A value near 1 means a handful
#' of filings carry almost the entire total (very heavy tail); near
#' the fraction itself (0.01 / 0.001) means a near-uniform mass.
#'
#' @param x Numeric vector. `NA`s are dropped.
#' @param configured_min,configured_max Optional gate bounds. When
#'   supplied, the result reports how many non-null values fall outside
#'   them - the "how far past the gate does the tail run" signal.
#' @return Named list of diagnostics, or an empty list when `x` has no
#'   non-null values.
#' @noRd
tail_diagnostics <- function(x, configured_min = NULL, configured_max = NULL) {
  nn <- suppressWarnings(as.numeric(x))
  nn <- nn[!is.na(nn)]
  n <- length(nn)
  if (n == 0) return(list())

  qs <- stats::quantile(nn, c(0.5, 0.9, 0.99, 0.999),
                        na.rm = TRUE, names = FALSE)
  total <- sum(nn)

  # Share of total mass in the largest `frac` of filings. NA when the
  # total is non-positive (a mass share is undefined then).
  top_share <- function(frac) {
    if (!is.finite(total) || total <= 0) return(NA_real_)
    k <- max(1L, ceiling(n * frac))
    sum(utils::head(sort(nn, decreasing = TRUE), k)) / total
  }

  out <- list(
    min = min(nn),
    max = max(nn),
    p50 = qs[1],
    p90 = qs[2],
    p99 = qs[3],
    p999 = qs[4],
    n_negative = sum(nn < 0),
    n_zero = sum(nn == 0),
    top_1pct_mass_share = top_share(0.01),
    top_0_1pct_mass_share = top_share(0.001)
  )
  if (!is.null(configured_max)) {
    out$n_above_configured_max <- sum(nn > as.numeric(configured_max))
  }
  if (!is.null(configured_min)) {
    out$n_below_configured_min <- sum(nn < as.numeric(configured_min))
  }
  out
}
