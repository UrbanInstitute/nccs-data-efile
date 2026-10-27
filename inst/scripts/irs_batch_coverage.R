#!/usr/bin/env Rscript
# Monthly check: does each published e-file release hold every filing the
# IRS has released? Run after each IRS monthly release (backlog U1).
#
#   Rscript inst/scripts/irs_batch_coverage.R [--publish] [index_year ...]
#
# Reads the IRS index files (default: the current year), compares them
# batch by batch with the header tables of efile_v3_1 and efilepf_v3_1 over
# anonymous HTTPS, and writes one CSV per release under
# out/irs-batch-coverage/. With --publish, each release's rows are also
# appended to the one report file kept beside the release,
# public/{release}/IRS-BATCH-COVERAGE.CSV in the nccs-efile bucket (AWS
# profile thiya). Needs the duckdb and DBI packages, the curl command and,
# for --publish, the aws command.

suppressPackageStartupMessages(library(nccs.data.efile))

arguments <- commandArgs(trailingOnly = TRUE)
publish <- "--publish" %in% arguments
arguments <- setdiff(arguments, "--publish")
index_years <- if (length(arguments) > 0) as.integer(arguments) else as.integer(format(Sys.Date(), "%Y"))

run_irs_batch_coverage(index_years = index_years, publish = publish)
