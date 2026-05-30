#!/usr/bin/env Rscript
# Phase 0 vintage build entry point.
#
# Usage:
#   Rscript inst/scripts/run_phase0.R [profile] [xsd_version]
#
# Arguments:
#   profile      Config profile to overlay on default. Defaults to
#                "default". On EC2, pass "production".
#   xsd_version  Optional. Forces a single XSD version for every
#                filing. Omit at scale - extract_filing parses the
#                version from each filing's return_version column.
#                Kept for single-version test slices.
#
# Behavior:
#   - Runs the full Phase 0 pipeline locally.
#   - If config$output$s3_enabled is TRUE, syncs the vintage dir to
#     s3://{output$s3_prefix}/{phase}/{vintage}/ after a successful
#     build, then server-side copies to .../latest/ per ADR sec 3.
#   - Exits non-zero on any failure (XSD mismatch, distribution
#     breach, S3 sync error).

# Quiet the renv "project is out-of-sync" notice that each worker would
# otherwise print on startup (inherited by child processes).
Sys.setenv(RENV_CONFIG_SYNCHRONIZED_CHECK = "FALSE")
# Allow fork-based multicore even under an RStudio-flavored session
# (the parallelism plan; multicore is ~100x faster than multisession here).
options(parallelly.fork.enable = TRUE)

suppressPackageStartupMessages({
  library(nccs.data.efile)
})

args <- commandArgs(trailingOnly = TRUE)
profile <- if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else NULL
xsd_version <- if (length(args) >= 2 && nzchar(args[[2]])) args[[2]] else NULL

config <- load_config(profile = profile)
dict   <- load_dictionary()

# Override the ephemeral staging dir without editing config (e.g. point at
# instance-store NVMe, or at root EBS on a non-`d` instance type where the
# default /mnt/stage does not exist). Needs ~2 GB free (one unzipped ZIP).
stage_override <- Sys.getenv("STAGE_DIR", "")
if (nzchar(stage_override)) config$staging$stage_dir <- stage_override

# Resumable checkpoints live outside out_dir by design (so they are never
# published). Override the location to place them on a volume with room to
# persist across runs; the default is a `_checkpoints/<vintage>/` sibling of
# out_dir.
checkpoint_override <- Sys.getenv("CHECKPOINT_DIR", "")
if (nzchar(checkpoint_override)) config$staging$checkpoint_dir <- checkpoint_override

summary <- run_phase0(
  config = config,
  dict = dict,
  xsd_version = xsd_version
)

if (isTRUE(config$output$s3_enabled)) {
  s3_prefix <- config$output$s3_prefix %||% "s3://nccsdata/processed/efile/"
  if (!endsWith(s3_prefix, "/")) s3_prefix <- paste0(s3_prefix, "/")
  vintage_uri <- sprintf("%s%s/%s/", s3_prefix,
                         config$output$phase %||% "phase0",
                         summary$vintage)
  latest_uri  <- sprintf("%s%s/latest/", s3_prefix,
                         config$output$phase %||% "phase0")

  # Syncing the whole out_dir is safe by construction: it contains only
  # deliverables. Build scratch lives elsewhere - _stage is unlinked at the end
  # of extraction, and _checkpoints is a sibling outside out_dir - so there is
  # no --exclude denylist here to drift out of sync with the code.
  args <- c("s3", "sync", summary$out_dir, vintage_uri)
  if (!is.null(config$aws$profile)) args <- c(args, "--profile", config$aws$profile)
  status <- system2("aws", args)
  if (!identical(status, 0L)) stop(sprintf("aws s3 sync failed (exit %s)", status))

  args2 <- c("s3", "sync", "--delete", vintage_uri, latest_uri)
  if (!is.null(config$aws$profile)) args2 <- c(args2, "--profile", config$aws$profile)
  status2 <- system2("aws", args2)
  if (!identical(status2, 0L)) stop(sprintf("aws s3 sync (latest) failed (exit %s)", status2))

  cat(sprintf("published: %s\n", vintage_uri))
  cat(sprintf("mirrored:  %s\n", latest_uri))
} else {
  cat(sprintf("local build: %s\n", summary$out_dir))
}
