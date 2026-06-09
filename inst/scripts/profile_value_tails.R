#!/usr/bin/env Rscript
# Heavy-tail profiler for a published Phase 0 vintage.
#
# Answers "how heavy-tailed is each e-file value field?" over the FULL
# population - the question the distribution gate's sample cannot, and
# the reason v2026.06's gate was switched to population min/max (see
# decisions/0002 Outcome, v2026.06 threshold note).
#
# Usage:
#   Rscript inst/scripts/profile_value_tails.R <dir-or-s3-prefix> [aws_profile]
#
# Examples:
#   # local dir of parquets
#   Rscript inst/scripts/profile_value_tails.R out/v2026.06
#   # straight from S3 (authed - published vintages are not anon-readable)
#   Rscript inst/scripts/profile_value_tails.R \
#     s3://nccsdata/processed/efile/phase0/v2026.06/ thiya
#
# Per field it prints: the quantile ladder (p50..max), a Pareto mass
# curve (what share of total dollars the top 0.1/1/5/10% of filings
# hold - the dollar analogue of the parse-cost "top-1 file = 60% of
# CPU" framing), negative/zero counts, magnitude bucket counts, and the
# per-year max (to see whether the tail is growing). Read-only.

suppressWarnings(suppressMessages({
  library(arrow)
}))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) {
  stop("usage: profile_value_tails.R <dir-or-s3-prefix> [aws_profile]")
}
src <- args[[1]]
profile <- if (length(args) >= 2) args[[2]] else NULL

# Key columns are identifiers, not measures - never profile them.
KEY_COLS <- c("filing_receipt_id", "ein", "tax_year", "form_type")

# Resolve the source to a local directory of parquet files. An s3://
# prefix is synced to a tempdir with the AWS CLI (honoring `profile`).
local_dir <- if (grepl("^s3://", src)) {
  dest <- tempfile("vintage_")
  dir.create(dest)
  prof <- if (!is.null(profile)) paste("--profile", shQuote(profile)) else ""
  cmd <- sprintf("aws s3 cp %s %s --recursive --exclude '*' --include '*.parquet' %s",
                 shQuote(src), shQuote(dest), prof)
  cat("syncing parquets:", cmd, "\n")
  code <- system(cmd)
  if (code != 0) stop("aws s3 cp failed (code ", code, ")")
  dest
} else {
  src
}

parquets <- list.files(local_dir, pattern = "\\.parquet$", full.names = TRUE)
if (length(parquets) == 0) stop("no .parquet files under ", local_dir)

fmt <- function(x) formatC(x, format = "f", big.mark = ",", digits = 0)
pct <- function(x) sprintf("%.1f%%", 100 * x)

# Pareto mass curve: cumulative share of total mass held by the top
# `frac` of (sorted, non-null) values. The steeper the climb, the
# heavier the tail.
mass_curve <- function(nn, fracs = c(0.001, 0.01, 0.05, 0.10)) {
  total <- sum(nn)
  if (!is.finite(total) || total <= 0) return(setNames(rep(NA_real_, length(fracs)), fracs))
  srt <- sort(nn, decreasing = TRUE)
  vapply(fracs, function(f) {
    k <- max(1L, ceiling(length(nn) * f))
    sum(srt[seq_len(k)]) / total
  }, numeric(1))
}

profile_field <- function(df, col) {
  x <- suppressWarnings(as.numeric(df[[col]]))
  nn <- x[!is.na(x)]
  n <- length(nn)
  cat(sprintf("\n=== %s ===\n", col))
  cat(sprintf("non-null: %s of %s (null_rate %s)\n",
              fmt(n), fmt(length(x)), pct(mean(is.na(x)))))
  if (n == 0) { cat("(all null)\n"); return(invisible()) }

  q <- stats::quantile(nn, c(0.5, 0.9, 0.99, 0.999, 0.9999, 1),
                       na.rm = TRUE, names = FALSE)
  cat("order statistics:\n")
  cat(sprintf("  p50    %s\n  p90    %s\n  p99    %s\n  p99.9  %s\n  p99.99 %s\n  max    %s  (min %s)\n",
              fmt(q[1]), fmt(q[2]), fmt(q[3]), fmt(q[4]), fmt(q[5]), fmt(q[6]), fmt(min(nn))))
  cat(sprintf("  tail ratios: p99/p50 = %.0fx,  max/p99 = %.0fx\n",
              q[3] / max(q[1], 1), q[6] / max(q[3], 1)))

  mc <- mass_curve(nn)
  cat("Pareto mass concentration (share of total $ held by the top ...):\n")
  cat(sprintf("  top 0.1%% = %s   top 1%% = %s   top 5%% = %s   top 10%% = %s\n",
              pct(mc[1]), pct(mc[2]), pct(mc[3]), pct(mc[4])))

  cat(sprintf("sign: negatives %s,  zeros %s,  positives %s\n",
              fmt(sum(nn < 0)), fmt(sum(nn == 0)), fmt(sum(nn > 0))))

  # Magnitude buckets (decades) - shows where the mass and the tail sit.
  brks <- c(-Inf, 0, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, Inf)
  labs <- c("<0", "0-1K", "1K-10K", "10K-100K", "100K-1M", "1M-10M",
            "10M-100M", "100M-1B", "1B-10B", ">10B")
  bucket <- cut(nn, breaks = brks, labels = labs, right = FALSE)
  tb <- table(bucket)
  cat("magnitude buckets:\n")
  for (i in seq_along(tb)) {
    if (tb[i] > 0) cat(sprintf("  %-9s %s\n", names(tb)[i], fmt(tb[i])))
  }

  if ("tax_year" %in% names(df)) {
    cat("per-year max (is the tail growing?):\n")
    ys <- sort(unique(df$tax_year))
    for (y in ys) {
      yv <- nn[df$tax_year[!is.na(x)] == y]
      if (length(yv)) cat(sprintf("  %s  max %s   p99 %s\n", y,
                                  fmt(max(yv)),
                                  fmt(stats::quantile(yv, 0.99, names = FALSE))))
    }
  }
  invisible()
}

for (p in parquets) {
  df <- as.data.frame(read_parquet(p))
  measure_cols <- setdiff(names(df)[vapply(df, is.numeric, logical(1))], KEY_COLS)
  cat(sprintf("\n########## %s  (%s rows) ##########\n", basename(p), fmt(nrow(df))))
  if (length(measure_cols) == 0) { cat("(no measure columns)\n"); next }
  for (col in measure_cols) profile_field(df, col)
}
cat("\n")
