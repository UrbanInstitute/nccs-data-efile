#!/usr/bin/env Rscript
# Parallelism diagnostic: why is the parse step ~1x despite N workers?
# Stages one ZIP, samples M filings, and times extract_filing over them
# under sequential / multicore / multisession plans. Prints filings/sec
# and the effective speedup so we can pick the right plan.
#
# Usage: Rscript inst/scripts/parse_bench.R [M] [workers]

Sys.setenv(RENV_CONFIG_SYNCHRONIZED_CHECK = "FALSE")
# Allow fork-based multicore even under an RStudio-flavored session.
options(parallelly.fork.enable = TRUE)

suppressPackageStartupMessages({
  library(nccs.data.efile)
  library(future)
  library(furrr)
})

args <- commandArgs(trailingOnly = TRUE)
M <- if (length(args) >= 1) as.integer(args[[1]]) else 3000L
W <- if (length(args) >= 2) as.integer(args[[2]]) else 70L

dict <- load_dictionary()

z <- "s3://gt990datalake-rawdata/EfileData/XmlZips/2021_TEOS_XML_01A.zip"
stage <- file.path(tempdir(), "bench")
unlink(stage, recursive = TRUE); dir.create(stage, recursive = TRUE)
lz <- file.path(stage, "z.zip")
cat("staging", z, "...\n")
system2("aws", c("s3", "cp", "--no-sign-request", z, lz),
        stdout = FALSE, stderr = FALSE)
xdir <- file.path(stage, "x"); dir.create(xdir)
system2("unzip", c("-j", "-o", "-q", lz, "-d", xdir),
        stdout = FALSE, stderr = FALSE)
files <- list.files(xdir, pattern = "_public\\.xml$", full.names = TRUE)
M <- min(M, length(files))
samp <- files[seq_len(M)]
cat(sprintf("benchmarking %d filings, %d workers\n\n", M, W))

# Fixed version: we are timing parse cost, not extraction correctness.
rows <- lapply(samp, function(p) list(
  local_path = p, filing_receipt_id = basename(p),
  ein = NA, tax_year = 2020L, form_type = "990", return_version = "2020v4.0"
))

one <- function(r) nccs.data.efile::extract_filing(r, dict, version = "4.0")
par_run <- function() furrr::future_map(rows, one, .options = furrr::furrr_options(seed = TRUE))

report <- function(label, secs) {
  cat(sprintf("%-26s %6.1fs  %7.1f filings/sec\n", label, secs, M / secs))
  invisible(M / secs)
}

future::plan(future::sequential)
s_seq <- system.time(invisible(lapply(rows, one)))[["elapsed"]]
r_seq <- report("sequential (1 core)", s_seq)

ok_mc <- tryCatch({
  future::plan(future::multicore, workers = W); TRUE
}, error = function(e) { cat("multicore unavailable:", conditionMessage(e), "\n"); FALSE })
if (ok_mc && inherits(future::plan(), "multicore")) {
  s_mc <- system.time(invisible(par_run()))[["elapsed"]]
  r_mc <- report("multicore", s_mc)
  cat(sprintf("  -> multicore speedup: %.1fx\n", r_mc / r_seq))
} else {
  cat("multicore NOT active (fell back); skipping\n")
}

future::plan(future::multisession, workers = W)
s_ms <- system.time(invisible(par_run()))[["elapsed"]]
r_ms <- report("multisession", s_ms)
cat(sprintf("  -> multisession speedup: %.1fx\n", r_ms / r_seq))

future::plan(future::sequential)
