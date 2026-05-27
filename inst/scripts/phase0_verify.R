#!/usr/bin/env Rscript
# Phase 0 XSD verification entrypoint.
#
# Usage:
#   Rscript inst/scripts/phase0_verify.R [profile]
#
# Behavior:
#   - Loads config under the given profile (defaults to default).
#   - Fetches + caches IRS XSDs for every tax_year in config$scope,
#     across every version listed in config$xsd$versions[tax_year]
#     (or auto-discovered if the cache is already populated).
#   - Runs run_phase0_verification() across all (year x version x claim).
#   - Writes the structured result to out/phase0_verification_report.json.
#   - Exits 0 on all-pass, 1 on any mismatch.
#
# This is the validation step gated in ADR 0002 §"Phase C — Validation":
# every passing build leaves a fresh report on disk; CI or the
# Phase D driver consumes that report's `passed` flag.

suppressPackageStartupMessages({
  library(nccs.data.efile)
})

args <- commandArgs(trailingOnly = TRUE)
profile <- if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else NULL

config <- load_config(profile = profile)

# Pull XSDs if a URL pattern is configured. Skip silently otherwise -
# the verifier itself will error fast if the local cache is empty.
if (!is.null(config$xsd$url_pattern) && nzchar(config$xsd$url_pattern)) {
  versions_by_year <- config$xsd$versions %||% list()
  for (ty in config$scope$tax_years) {
    vers <- versions_by_year[[as.character(ty)]]
    if (is.null(vers) || length(vers) == 0) {
      message(sprintf(
        "no xsd$versions entry for tax_year %s; skipping fetch", ty
      ))
      next
    }
    aliases <- (config$xsd$version_aliases %||% list())[[as.character(ty)]]
    for (v in vers) {
      if (!is.null(aliases) && !is.null(aliases[[as.character(v)]])) {
        message(sprintf(
          "tax_year %s version %s is aliased to XSDs from %s; skipping fetch",
          ty, v, aliases[[as.character(v)]]$xsd_from
        ))
        next
      }
      fetch_xsds(tax_year = ty, version = v, config = config)
    }
  }
}

result <- run_phase0_verification(config = config, strict = FALSE)

dir.create("out", showWarnings = FALSE, recursive = TRUE)
report_path <- file.path("out", "phase0_verification_report.json")
jsonlite::write_json(
  list(
    passed = result$passed,
    checks_run = result$checks_run,
    mismatches = result$mismatches,
    results = result$results,
    generated_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  ),
  report_path,
  pretty = TRUE, auto_unbox = TRUE, na = "null"
)

cat(sprintf("report: %s\n", report_path))
cat(sprintf("checks: %d, passed: %s\n",
            result$checks_run, isTRUE(result$passed)))

if (!isTRUE(result$passed)) {
  cat(sprintf("mismatches: %d\n", length(result$mismatches)))
  if (interactive()) {
    message("interactive session: not calling quit(1); inspect `result`")
  } else {
    quit(status = 1L)
  }
}
