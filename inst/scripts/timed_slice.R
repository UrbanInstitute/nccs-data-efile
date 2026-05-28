#!/usr/bin/env Rscript
# Timed-slice gate for the Phase 0 scale run.
#
# Processes a few ZIP bundles (default 2) through the real extraction
# path, with wall timing, and projects the full-run wall time and cost
# from the measured throughput. Run this on a fresh instance BEFORE
# committing to the full run (see inst/ops/ec2-scale-run.md). The
# coverage fallback is disabled here - over only a few ZIPs the global
# "missing" set is meaningless.
#
# Usage:
#   Rscript inst/scripts/timed_slice.R [profile]
#
# Env knobs:
#   SLICE_ZIPS   number of ZIPs to process (default 2)
#   HOURLY_USD   instance on-demand $/hr for the cost projection (default 1.53)

# Quiet the renv "project is out-of-sync" notice that each multisession
# worker would otherwise print on startup (inherited by child processes).
Sys.setenv(RENV_CONFIG_SYNCHRONIZED_CHECK = "FALSE")

suppressPackageStartupMessages({
  library(nccs.data.efile)
})

args <- commandArgs(trailingOnly = TRUE)
profile <- if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else NULL
n_slice <- as.integer(Sys.getenv("SLICE_ZIPS", "2"))
hourly  <- as.numeric(Sys.getenv("HOURLY_USD", "1.53"))

config <- load_config(profile = profile)
dict   <- load_dictionary()

if (!identical(config$staging$mode %||% "objects", "zips")) {
  stop("timed_slice expects staging.mode = 'zips'")
}

cli::cli_h1("Timed slice: {n_slice} ZIP(s)")

index <- fetch_gt_indices(config = config)
n_total <- nrow(index)
cli::cli_alert_info("full in-scope index: {n_total} filings")

# Total target ZIPs (uncapped) for the projection denominator.
n_zips_total <- length(nccs.data.efile:::list_target_zips(config$staging))
cli::cli_alert_info("total target ZIPs: {n_zips_total}")

config$staging$max_zips <- n_slice
config$staging$stage_dir <- file.path(tempdir(), "slice_stage")
out_dir <- file.path(tempdir(), sprintf("slice_%s", format(Sys.time(), "%H%M%S")))
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

nccs.data.efile:::setup_future_plan(config$parallelism)
n_workers <- future::nbrOfWorkers()

t0 <- Sys.time()
extracted <- nccs.data.efile:::extract_via_zips(
  index, dict, config, out_dir, xsd_version = NULL, run_fallback = FALSE
)
secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

rows <- nrow(extracted)
rate <- rows / secs                                  # filings/sec (slice)
err_rate <- mean(!is.na(extracted[["_extract_error"]]))
proj_secs_by_count <- if (rate > 0) n_total / rate else NA_real_
proj_secs_by_zip   <- secs / n_slice * n_zips_total

cli::cli_h2("Results")
cli::cli_alert_info("parse workers: {n_workers}")
cli::cli_alert_info("slice: {rows} rows from {n_slice} ZIP(s) in {round(secs, 1)}s")
cli::cli_alert_info("throughput: {round(rate, 1)} filings/sec")
cli::cli_alert_info("extract error rate (this slice): {round(err_rate * 100, 2)}%")
cli::cli_h2("Projection to full run ({n_total} filings, {n_zips_total} ZIPs)")
cli::cli_alert_info("by filing rate: {round(proj_secs_by_count / 3600, 2)} h  (~${round(proj_secs_by_count / 3600 * hourly, 2)})")
cli::cli_alert_info("by ZIP count:   {round(proj_secs_by_zip / 3600, 2)} h  (~${round(proj_secs_by_zip / 3600 * hourly, 2)})")
cli::cli_alert_warning("Coverage parity (in-scope ids missing from ALL ZIPs) is only measured by the full run; the s5cmd fallback handles any gap.")
