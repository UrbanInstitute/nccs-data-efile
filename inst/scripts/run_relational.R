#!/usr/bin/env Rscript
# Relational (raw scalar) tier build entry point — ADR 0004 step 3.
#
# Usage:
#   Rscript inst/scripts/run_relational.R [profile]
#
#   profile   Config profile overlay. "default" locally; "production" on EC2
#             (multicore + s3_enabled).
#
# Behavior:
#   - Builds the per-form header tables (returnheader, f990_header,
#     f990pf_header) by pulling every non-repeating scalar leaf per filing.
#   - If config$output$s3_enabled, syncs EACH table dir to
#     s3://{s3_prefix}/relational/{table}/{vintage}/ (+ .../latest/) after a
#     clean build, so a failed build never half-publishes.
#   - The tier is best-effort / UNCONTRACTED (ADR 0004 s4 / nccs-contracts 0028).
#   - Exits non-zero on any failure.

Sys.setenv(RENV_CONFIG_SYNCHRONIZED_CHECK = "FALSE")
options(parallelly.fork.enable = TRUE)
suppressPackageStartupMessages({ library(nccs.data.efile) })

args <- commandArgs(trailingOnly = TRUE)
profile <- if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else NULL
config <- load_config(profile = profile)

# Relocate ephemeral staging / resumable checkpoints off a small or NVMe-less
# volume (see the EC2 runbook). Same env knobs as run_phase0.R.
stage_override <- Sys.getenv("STAGE_DIR", "")
if (nzchar(stage_override)) config$staging$stage_dir <- stage_override
checkpoint_override <- Sys.getenv("CHECKPOINT_DIR", "")
if (nzchar(checkpoint_override)) config$staging$checkpoint_dir <- checkpoint_override

# Slice gate: cap the number of ZIPs processed to measure throughput on THIS
# instance before committing to the full multi-hour run (see the runbook).
max_zips <- Sys.getenv("MAX_ZIPS", "")
if (nzchar(max_zips)) config$staging$max_zips <- as.integer(max_zips)

summary <- run_relational(config = config)

if (isTRUE(config$output$s3_enabled)) {
  s3_prefix <- config$output$s3_prefix %||% "s3://nccsdata/processed/efile/"
  if (!endsWith(s3_prefix, "/")) s3_prefix <- paste0(s3_prefix, "/")
  for (tdir in summary$tables) {
    table <- basename(tdir)
    vintage_uri <- sprintf("%srelational/%s/%s/", s3_prefix, table, summary$vintage)
    latest_uri  <- sprintf("%srelational/%s/latest/", s3_prefix, table)
    args1 <- c("s3", "sync", tdir, vintage_uri)
    if (!is.null(config$aws$profile)) args1 <- c(args1, "--profile", config$aws$profile)
    if (!identical(system2("aws", args1), 0L)) stop(sprintf("aws s3 sync failed: %s", vintage_uri))
    args2 <- c("s3", "sync", "--delete", vintage_uri, latest_uri)
    if (!is.null(config$aws$profile)) args2 <- c(args2, "--profile", config$aws$profile)
    if (!identical(system2("aws", args2), 0L)) stop(sprintf("aws s3 sync (latest) failed: %s", latest_uri))
    cat(sprintf("published: %s\n", vintage_uri))
  }
} else {
  cat(sprintf("local build: %s\n", summary$out_dir))
}
