#!/usr/bin/env Rscript
# Monthly check: does each published e-file release hold every filing the
# IRS has released? Run after each IRS monthly release (backlog U1).
#
#   Rscript inst/scripts/irs_batch_coverage.R [index_year ...]
#
# Reads the IRS index files (default: the current year), compares them
# batch by batch with the header tables of efile_v3_1 and efilepf_v3_1 over
# anonymous HTTPS, and writes one CSV per release under
# out/irs-batch-coverage/. Nothing is published; copy the CSV by hand once
# the destination is contracted. Needs the duckdb and DBI packages and the
# curl command.

suppressPackageStartupMessages(library(nccs.data.efile))

arguments <- commandArgs(trailingOnly = TRUE)
index_years <- if (length(arguments) > 0) as.integer(arguments) else as.integer(format(Sys.Date(), "%Y"))

run_irs_batch_coverage(index_years = index_years)
