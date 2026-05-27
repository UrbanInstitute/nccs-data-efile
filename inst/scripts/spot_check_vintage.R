#!/usr/bin/env Rscript
# Held-out spot-check of a published Phase 0 vintage.
#
# Usage:
#   Rscript inst/scripts/spot_check_vintage.R <vintage_dir> [n_per_form] [profile]
#
# Arguments:
#   vintage_dir  Local path (e.g. out/v2026.05) or s3:// URI
#                (e.g. s3://nccsdata/processed/efile/phase0/v2026.05/).
#   n_per_form   Sample size per form_type. Default 10 (ADR 0002).
#   profile      Config profile. On EC2, pass "production".
#
# Output:
#   - Prints agreement table to stdout.
#   - Writes structured report to
#     {vintage_dir}/_spot_check_report.json (local) or
#     out/_spot_check_report_{basename(vintage_dir)}.json (remote).

suppressPackageStartupMessages({
  library(nccs.data.efile)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) {
  stop("usage: spot_check_vintage.R <vintage_dir> [n_per_form] [profile]")
}
vintage_dir <- args[[1]]
n_per_form  <- if (length(args) >= 2 && nzchar(args[[2]])) as.integer(args[[2]]) else 10L
profile     <- if (length(args) >= 3 && nzchar(args[[3]])) args[[3]] else NULL

config <- load_config(profile = profile)
dict   <- load_dictionary()

report_path <- if (startsWith(vintage_dir, "s3://")) {
  file.path("out", sprintf("_spot_check_report_%s.json",
                           basename(sub("/$", "", vintage_dir))))
} else {
  file.path(vintage_dir, "_spot_check_report.json")
}

result <- spot_check_vintage(
  vintage_dir = vintage_dir,
  n_per_form  = n_per_form,
  config      = config,
  dict        = dict,
  report_path = report_path
)

cat(sprintf("\nspot-check: %d/%d agree (%d disagree)\n",
            result$agree, result$n, result$disagree))

if (result$disagree > 0 && !interactive()) {
  quit(status = 1L)
}
