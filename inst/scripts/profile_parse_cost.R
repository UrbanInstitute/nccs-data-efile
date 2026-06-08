#!/usr/bin/env Rscript
# Per-file parse-cost profiler for a single XmlZips bundle.
#
# Motivation (v2026.06): the v2026.05 build's wall time was dominated by a
# handful of "straggler" ZIPs - e.g. 2021_TEOS_XML_01F parsed at ~39
# filings/s while the same-year, same-size 01G ran at ~1100 filings/s,
# back-to-back. `furrr_options(scheduling = Inf)` was confirmed a no-op
# (the slow ZIPs are compute-bound, not load-imbalanced), so the real
# fix depends on the SHAPE of the per-file parse cost inside a slow
# bundle:
#
#   * SINGLE MONSTER  -> one sub-50MB filing parses to a huge DOM and
#                        stalls the worker. Fix: targeted skip / stream
#                        parse / lower the size cap.
#   * FAT TAIL        -> many mid-size filings are each moderately slow.
#                        Fix: cheaper parse path - avoid the whole-tree
#                        `xml_ns_strip` copy (extract_filing.R:80-83),
#                        e.g. namespace-aware XPath or a streaming reader.
#
# This script measures that distribution directly: download one ZIP,
# unzip, and for every `_public.xml` time `read_xml` and `xml_ns_strip`
# SEQUENTIALLY (no worker interleaving), honoring the production size cap
# so skipped giants cost ~0 just as they do in the real run. The decisive
# statistic is the share of total parse time held by the top-1 and top-10
# files: a single-monster bundle concentrates it, a fat tail spreads it.
#
# Usage:
#   Rscript inst/scripts/profile_parse_cost.R [zip-uri-or-basename]
#
# Default target: 2021_TEOS_XML_01F.zip (the known straggler).
# Pass 2021_TEOS_XML_01G.zip to profile the fast control for contrast.
#
# Env knobs:
#   CAP_MB     size cap in MB, mirrors extract.max_file_mb (default 50)
#   MAX_FILES  cap the number of files profiled (default: all)
#   ZIP_PREFIX S3 prefix for bare basenames (default GT lake XmlZips)

Sys.setenv(RENV_CONFIG_SYNCHRONIZED_CHECK = "FALSE")

suppressPackageStartupMessages({
  library(xml2)
})

args      <- commandArgs(trailingOnly = TRUE)
target    <- if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else "2021_TEOS_XML_01F.zip"
cap_mb    <- as.numeric(Sys.getenv("CAP_MB", "50"))
cap_bytes <- cap_mb * 1e6
max_files <- suppressWarnings(as.integer(Sys.getenv("MAX_FILES", "")))
zprefix   <- Sys.getenv("ZIP_PREFIX", "s3://gt990datalake-rawdata/EfileData/XmlZips/")

zip_uri <- if (startsWith(target, "s3://")) target else paste0(zprefix, target)
bundle  <- sub("\\.zip$", "", basename(zip_uri))

cat(sprintf("=== parse-cost profile: %s ===\n", bundle))
cat(sprintf("size cap: %.0f MB | source: %s\n\n", cap_mb, zip_uri))

stage <- file.path(tempdir(), paste0("profile_", bundle))
unlink(stage, recursive = TRUE)
dir.create(stage, recursive = TRUE)
lz <- file.path(stage, "z.zip")

cat("downloading (anon) ...\n")
t_dl <- system.time(
  system2("aws", c("s3", "cp", "--no-sign-request", zip_uri, lz),
          stdout = FALSE, stderr = FALSE)
)[["elapsed"]]
if (!file.exists(lz)) stop("download failed: ", zip_uri)
cat(sprintf("  %.0fs, %.0f MB on disk\n", t_dl, file.size(lz) / 1e6))

xdir <- file.path(stage, "x")
dir.create(xdir)
cat("unzipping ...\n")
t_uz <- system.time(
  system2("unzip", c("-j", "-o", "-q", lz, "-d", xdir),
          stdout = FALSE, stderr = FALSE)
)[["elapsed"]]
unlink(lz)

files <- list.files(xdir, pattern = "_public\\.xml$", full.names = TRUE)
if (!is.na(max_files) && length(files) > max_files) files <- files[seq_len(max_files)]
n <- length(files)
cat(sprintf("  %.0fs, %d _public.xml files to profile\n\n", t_uz, n))

# Per-file timing. read_xml and xml_ns_strip are timed separately so we can
# attribute cost to the namespace-strip copy specifically. Giants over the
# cap are recorded as skipped (parse cost ~0 in the real run, since the cap
# fires on file.size before read_xml in extract_filing).
bytes   <- file.size(files)
read_s  <- rep(NA_real_, n)
strip_s <- rep(NA_real_, n)
status  <- rep("ok", n)

t_all <- Sys.time()
for (i in seq_len(n)) {
  if (!is.na(bytes[i]) && cap_bytes > 0 && bytes[i] > cap_bytes) {
    status[i] <- "skipped_cap"
    next
  }
  doc <- tryCatch(
    { tr <- system.time(d <- xml2::read_xml(files[i]))[["elapsed"]]; read_s[i] <- tr; d },
    error = function(e) { status[i] <<- "parse_error"; NULL }
  )
  if (is.null(doc)) next
  strip_s[i] <- system.time(xml2::xml_ns_strip(doc))[["elapsed"]]
  rm(doc)
  if (i %% 5000 == 0) cat(sprintf("  ... %d/%d\n", i, n))
}
wall <- as.numeric(difftime(Sys.time(), t_all, units = "secs"))

total_s <- ifelse(is.na(read_s), 0, read_s) + ifelse(is.na(strip_s), 0, strip_s)
df <- data.frame(
  file    = basename(files),
  bytes   = bytes,
  read_ms = round(read_s * 1000, 2),
  strip_ms= round(strip_s * 1000, 2),
  total_ms= round(total_s * 1000, 2),
  status  = status,
  stringsAsFactors = FALSE
)
csv <- file.path(tempdir(), sprintf("parse_profile_%s.csv", bundle))
write.csv(df, csv, row.names = FALSE)

# ---- summary ----------------------------------------------------------
ok        <- status == "ok"
n_skip    <- sum(status == "skipped_cap")
n_err     <- sum(status == "parse_error")
parse_tot <- sum(total_s)                       # CPU-seconds in read+strip
ord       <- order(total_s, decreasing = TRUE)
share     <- function(k) if (parse_tot > 0) sum(total_s[ord[seq_len(min(k, n))]]) / parse_tot else NA
qs        <- stats::quantile(total_s[ok] * 1000, c(.5, .9, .99, 1), names = FALSE)

cat("\n================ SUMMARY ================\n")
cat(sprintf("bundle              : %s\n", bundle))
cat(sprintf("files               : %d  (ok %d | skipped>cap %d | parse_err %d)\n",
            n, sum(ok), n_skip, n_err))
cat(sprintf("wall (sequential)   : %.1fs\n", wall))
cat(sprintf("sum read+strip CPU  : %.1fs  -> %.1f files/s (parsed only)\n",
            parse_tot, if (parse_tot > 0) sum(ok) / parse_tot else NA))
cat(sprintf("read vs strip split : read %.1fs (%.0f%%) | strip %.1fs (%.0f%%)\n",
            sum(read_s, na.rm = TRUE), 100 * sum(read_s, na.rm = TRUE) / parse_tot,
            sum(strip_s, na.rm = TRUE), 100 * sum(strip_s, na.rm = TRUE) / parse_tot))
cat("\nper-file total_ms (parsed): \n")
cat(sprintf("  p50 %.1f | p90 %.1f | p99 %.1f | max %.1f ms\n",
            qs[1], qs[2], qs[3], qs[4]))
cat("\n*** DISCRIMINATOR: share of total parse time ***\n")
cat(sprintf("  top 1 file   : %5.1f%%\n", 100 * share(1)))
cat(sprintf("  top 10 files : %5.1f%%\n", 100 * share(10)))
cat(sprintf("  top 100 files: %5.1f%%\n", 100 * share(100)))
cat("  (top-1 >~50%% => single monster; top-10 small + broad mid-band => fat tail)\n")

cat("\nheaviest 10 files (basename | MB | read_ms | strip_ms):\n")
for (j in ord[seq_len(min(10, n))]) {
  cat(sprintf("  %-34s %6.1f  %8.1f  %8.1f\n",
              substr(df$file[j], 1, 34), bytes[j] / 1e6,
              df$read_ms[j], df$strip_ms[j]))
}
cat(sprintf("\nbytes vs total_ms (parsed) Spearman rho: %.3f\n",
            suppressWarnings(stats::cor(bytes[ok], total_s[ok], method = "spearman"))))
cat(sprintf("\nper-file CSV: %s\n", csv))
cat("========================================\n")

unlink(xdir, recursive = TRUE)
