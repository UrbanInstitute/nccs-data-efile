#' Fetch the IRS annual e-file index files
#'
#' The IRS publishes one index CSV per calendar year of release
#' (`index_YYYY.csv`) listing every e-filed return it has made public, with
#' the `XML_BATCH_ID` of the monthly ZIP the return shipped in. These are
#' small (under 100 MB each) and are the authoritative list of what exists,
#' independent of any mirror.
#'
#' @param index_years Integer vector of calendar years to fetch.
#' @param config Package config; `config$upstream$irs_index$url_pattern`
#'   gives the URL with `{year}` substituted.
#' @param local_cache_dir Directory for the downloaded files.
#' @param skip_sync When TRUE, only files already in the cache are read,
#'   and every requested year must be there: a missing file is an error,
#'   never silently skipped. When FALSE (the default) every file is
#'   downloaded again: the IRS rewrites the current year's index with each
#'   monthly batch, so a cached copy goes stale within weeks.
#' @return A data.frame with columns `object_id`, `return_type`,
#'   `tax_period`, `tax_year`, `tax_year_ambiguous`, `xml_batch_id`,
#'   `index_year`, with attribute `sources`: one row per file giving `url`,
#'   `path`, `retrieved_at_utc`, `bytes`, `sha256`, `rows`.
#' @details `tax_year` is derived from `TAX_PERIOD` (YYYYMM, period end):
#'   the end year when the period ends in December, otherwise the end year
#'   minus one. That is the convention for fiscal-year filers, but a
#'   short-year return (for example January to June 2024, `TaxYr` 2024) is
#'   assigned the earlier year. `tax_year_ambiguous` is TRUE for every
#'   non-December period end; see `verify_index_coverage()` for how the
#'   gate treats those rows. Index files before 2024 carry no
#'   `XML_BATCH_ID`; their filings are grouped under `no_batch_id`.
#' @export
fetch_irs_indices <- function(index_years,
                              config = load_config(),
                              local_cache_dir = NULL,
                              skip_sync = FALSE) {
  local_cache_dir <- local_cache_dir %||%
    path.expand("~/.cache/nccs-data-efile/irs-indices")
  url_pattern <- config$upstream$irs_index$url_pattern %||%
    "https://apps.irs.gov/pub/epostcard/990/xml/{year}/index_{year}.csv"
  dir.create(local_cache_dir, recursive = TRUE, showWarnings = FALSE)

  parts <- list()
  sources <- list()
  for (year in as.integer(index_years)) {
    local_path <- file.path(local_cache_dir, sprintf("index_%d.csv", year))
    url <- gsub("{year}", year, url_pattern, fixed = TRUE)
    if (!skip_sync) {
      cli::cli_alert_info("fetching {url} -> {local_path}")
      tmp <- paste0(local_path, ".part")
      status <- utils::download.file(url, tmp, quiet = TRUE, mode = "wb")
      if (status != 0) {
        unlink(tmp)
        stop("download of ", url, " failed (status ", status, ")")
      }
      file.rename(tmp, local_path)
    }
    if (!file.exists(local_path)) {
      # Every requested year must be present. Skipping a year would let the
      # coverage check pass on a partial cache, with whole IRS releases
      # unseen (Codex review of PR #18).
      stop("IRS index file for ", year, " is not in the cache (", local_path,
           ") and skip_sync = TRUE; fetch it or run with skip_sync = FALSE")
    }
    part <- parse_irs_index_csv(local_path, year)
    parts[[as.character(year)]] <- part
    sources[[as.character(year)]] <- data.frame(
      url = url, path = local_path,
      retrieved_at_utc = if (skip_sync) NA_character_ else
        format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
      bytes = file.size(local_path),
      sha256 = digest::digest(local_path, algo = "sha256", file = TRUE),
      rows = nrow(part),
      stringsAsFactors = FALSE
    )
  }
  if (length(parts) == 0) stop("no IRS index files available - nothing to parse")
  out <- do.call(rbind, unname(parts))
  attr(out, "sources") <- do.call(rbind, unname(sources))
  out
}

#' Parse one IRS annual index CSV.
#' @noRd
parse_irs_index_csv <- function(path, index_year) {
  header <- names(data.table::fread(path, nrows = 0, showProgress = FALSE))
  wanted <- intersect(c("OBJECT_ID", "RETURN_TYPE", "TAX_PERIOD", "XML_BATCH_ID"), header)
  missing <- setdiff(c("OBJECT_ID", "RETURN_TYPE", "TAX_PERIOD"), header)
  if (length(missing) > 0) {
    stop(sprintf("IRS index %s missing columns: %s", basename(path), paste(missing, collapse = ", ")))
  }
  raw <- data.table::fread(path, select = wanted,
                           colClasses = list(character = wanted), showProgress = FALSE)
  raw <- as.data.frame(raw)
  batch <- if ("XML_BATCH_ID" %in% header) raw$XML_BATCH_ID else rep("no_batch_id", nrow(raw))
  batch[is.na(batch) | !nzchar(batch)] <- "no_batch_id"
  data.frame(
    object_id = raw$OBJECT_ID,
    return_type = raw$RETURN_TYPE,
    tax_period = raw$TAX_PERIOD,
    tax_year = irs_tax_year(raw$TAX_PERIOD),
    tax_year_ambiguous = irs_tax_year_ambiguous(raw$TAX_PERIOD),
    xml_batch_id = batch,
    index_year = as.integer(index_year),
    stringsAsFactors = FALSE
  )
}

#' Tax year estimated from an IRS TAX_PERIOD (YYYYMM period end).
#' @noRd
irs_tax_year <- function(tax_period) {
  end_year <- as.integer(substr(tax_period, 1, 4))
  end_month <- as.integer(substr(tax_period, 5, 6))
  ifelse(end_month == 12L, end_year, end_year - 1L)
}

#' TRUE when the period does not end in December, so the estimated tax
#' year may be one too low (short-year returns).
#' @noRd
irs_tax_year_ambiguous <- function(tax_period) {
  as.integer(substr(tax_period, 5, 6)) != 12L
}

#' Month named in an IRS XML batch id such as `2025_TEOS_XML_09A`.
#'
#' This is the month the batch is named for, not when the IRS published
#' it; publication runs weeks later (2026_05A was published 2026-06-17).
#' Used only as a label.
#' @noRd
batch_name_month <- function(xml_batch_id) {
  m <- regmatches(xml_batch_id, regexec("^(\\d{4})_TEOS_XML_(\\d{2})", xml_batch_id))
  as.Date(vapply(m, function(x) {
    if (length(x) < 3) NA_character_ else sprintf("%s-%s-01", x[[2]], x[[3]])
  }, character(1)))
}

#' Publication dates of IRS XML batches
#'
#' Reads the `Last-Modified` header of each batch ZIP on the IRS server.
#' That is the only machine-readable record of when a batch became
#' available; the batch id names a month that can be weeks earlier than
#' publication. Results are cached with their retrieval time.
#'
#' @param xml_batch_ids Character vector of batch ids.
#' @param config Package config; `config$upstream$irs_index$zip_pattern`
#'   gives the ZIP URL with `{year}` and `{batch}` substituted.
#' @param local_cache_dir Directory holding `batch-dates.csv`.
#' @param skip_sync When TRUE, only cached dates are returned.
#' @return A data.frame with `xml_batch_id`, `published` (Date, NA when the
#'   server gave no date), `source_url`, `retrieved_at_utc`.
#' @details Uses the system `curl` for a HEAD request; the package does not
#'   depend on an R HTTP client. Fails with a clear message when `curl` is
#'   not on the PATH and the dates are not cached.
#' @export
irs_batch_dates <- function(xml_batch_ids,
                            config = load_config(),
                            local_cache_dir = NULL,
                            skip_sync = FALSE) {
  local_cache_dir <- local_cache_dir %||%
    path.expand("~/.cache/nccs-data-efile/irs-indices")
  dir.create(local_cache_dir, recursive = TRUE, showWarnings = FALSE)
  zip_pattern <- config$upstream$irs_index$zip_pattern %||%
    "https://apps.irs.gov/pub/epostcard/990/xml/{year}/{batch}.zip"
  cache_path <- file.path(local_cache_dir, "batch-dates.csv")
  cached <- if (file.exists(cache_path)) {
    utils::read.csv(cache_path, stringsAsFactors = FALSE, colClasses = "character")
  } else {
    data.frame(xml_batch_id = character(0), published = character(0),
               source_url = character(0), retrieved_at_utc = character(0),
               stringsAsFactors = FALSE)
  }
  ids <- setdiff(unique(xml_batch_ids), "no_batch_id")
  todo <- setdiff(ids, cached$xml_batch_id[!is.na(cached$published) & nzchar(cached$published)])
  if (length(todo) > 0 && !skip_sync) {
    if (!nzchar(Sys.which("curl"))) {
      stop("irs_batch_dates() needs the curl command on the PATH to read ",
           "Last-Modified from the IRS server (", length(todo), " batch(es) uncached)")
    }
    rows <- lapply(todo, function(b) {
      year <- substr(b, 1, 4)
      # The 2024 index writes the batch suffix in lower case (2024_TEOS_XML_04a)
      # but the ZIP on the server is upper case.
      url <- gsub("{batch}", toupper(b), gsub("{year}", year, zip_pattern, fixed = TRUE), fixed = TRUE)
      hdr <- tryCatch(system2("curl", c("-sI", "--max-time", "60", shQuote(url)),
                              stdout = TRUE, stderr = FALSE),
                      error = function(e) character(0))
      lm <- grep("^last-modified:", hdr, ignore.case = TRUE, value = TRUE)
      published <- if (length(lm) == 1) {
        d <- as.Date(trimws(sub("^last-modified:", "", lm, ignore.case = TRUE)),
                     format = "%a, %d %b %Y", tz = "GMT")
        if (is.na(d)) NA_character_ else as.character(d)
      } else NA_character_
      data.frame(xml_batch_id = b, published = published, source_url = url,
                 retrieved_at_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
                 stringsAsFactors = FALSE)
    })
    cached <- rbind(cached[!cached$xml_batch_id %in% todo, ], do.call(rbind, rows))
    utils::write.csv(cached, cache_path, row.names = FALSE)
  }
  out <- cached[match(ids, cached$xml_batch_id), ]
  out$xml_batch_id <- ids
  out$published <- as.Date(out$published)
  rownames(out) <- NULL
  out
}

#' Verify that the filing index covers every IRS batch
#'
#' Compares the in-scope filings of the IRS annual indices, batch by batch,
#' against the index the build will extract from (normally the GivingTuesday
#' data lake index). A batch whose filings are largely absent from the build
#' index means the mirror skipped an IRS release, and the build would
#' silently under-cover those months.
#'
#' Background: the GivingTuesday index omitted IRS batches 2025_09A,
#' 2025_10A, part of 2026_05A and 2026_08A. The Phase 0 vintage v2026.06
#' was built from that index on 2026-06-08 and lacks 37,211 in-scope
#' filings from 2025_09A and 2025_10A, both published by 2025-11-19, and a
#' further 32,250 from batches published after the build (NCCS review,
#' 2026-10-23).
#'
#' @param index The build index as returned by `fetch_gt_indices()`
#'   (column `object_id`), already filtered to scope.
#' @param irs The IRS index as returned by `fetch_irs_indices()`.
#' @param scope `config$scope` (`forms`, `tax_years`).
#' @param batch_dates Publication date per batch as returned by
#'   `irs_batch_dates()`. A batch with no date is treated as published
#'   before the snapshot (the conservative reading) and marked
#'   `date_unknown`.
#' @param as_of Date of the build index snapshot. Batches published after
#'   `as_of` cannot be in the snapshot and are reported, not failed.
#' @param min_batch_filings Batches with fewer in-scope filings than this
#'   are reported but never fail the gate.
#' @param max_missing_share Largest share of a batch's in-scope filings that
#'   may be absent from the build index before the gate fails.
#' @param strict When TRUE (the build default), stop on failure.
#' @return A list with `passed`, `as_of`, `batches` (one row per batch:
#'   `xml_batch_id`, `published`, `n_irs`, `n_ambiguous`, `n_in_index`,
#'   `missing_share`, `status`) and `failed` (the batch ids that failed).
#'   Status values: `ok`, `missing` (fails the gate), `small`,
#'   `after_snapshot`, `no_batch_id` (IRS index years before 2024 carry no
#'   batch id; reported, never failed). `date_unknown` is appended to the
#'   status when the server gave no publication date.
#' @details Rows whose estimated tax year equals the last year in scope
#'   and whose period does not end in December may be short-year returns
#'   of the following tax year, which the build index would never hold.
#'   They are excluded from the denominators and counted in
#'   `n_ambiguous`, so a scope boundary cannot produce a false gap.
#' @export
verify_index_coverage <- function(index, irs, scope,
                                  batch_dates = NULL,
                                  as_of = Sys.Date(),
                                  min_batch_filings = 100L,
                                  max_missing_share = 0.05,
                                  strict = TRUE) {
  forms <- scope$forms %||% character(0)
  tax_years <- as.integer(scope$tax_years %||% integer(0))
  in_scope <- irs
  if (length(forms) > 0) in_scope <- in_scope[in_scope$return_type %in% forms, , drop = FALSE]
  if (length(tax_years) > 0) in_scope <- in_scope[in_scope$tax_year %in% tax_years, , drop = FALSE]
  if (nrow(in_scope) == 0) stop("no IRS index rows in scope - check scope$forms / scope$tax_years")

  ambiguous <- if (length(tax_years) > 0 && "tax_year_ambiguous" %in% names(in_scope)) {
    in_scope$tax_year_ambiguous & in_scope$tax_year == max(tax_years)
  } else rep(FALSE, nrow(in_scope))
  in_scope$present <- in_scope$object_id %in% as.character(index$object_id)

  by_batch <- split(seq_len(nrow(in_scope)), in_scope$xml_batch_id)
  batches <- do.call(rbind, lapply(names(by_batch), function(b) {
    i <- by_batch[[b]]
    keep <- i[!ambiguous[i]]
    data.frame(xml_batch_id = b, n_irs = length(keep), n_ambiguous = sum(ambiguous[i]),
               n_in_index = sum(in_scope$present[keep]), stringsAsFactors = FALSE)
  }))
  batches$published <- as.Date(NA)
  if (!is.null(batch_dates)) {
    batches$published <- as.Date(batch_dates$published)[match(batches$xml_batch_id, batch_dates$xml_batch_id)]
  }
  batches$missing_share <- ifelse(batches$n_irs > 0, 1 - batches$n_in_index / batches$n_irs, 0)
  no_batch <- batches$xml_batch_id == "no_batch_id"
  date_unknown <- is.na(batches$published) & !no_batch
  after_snapshot <- !is.na(batches$published) & batches$published > as.Date(as_of)
  small <- batches$n_irs < min_batch_filings
  over <- batches$missing_share > max_missing_share
  batches$status <- ifelse(no_batch, "no_batch_id",
                    ifelse(after_snapshot, "after_snapshot",
                    ifelse(small & over, "small",
                    ifelse(over, "missing", "ok"))))
  batches$status[date_unknown] <- paste0(batches$status[date_unknown], " (date_unknown)")
  batches <- batches[order(batches$xml_batch_id),
                     c("xml_batch_id", "published", "n_irs", "n_ambiguous", "n_in_index",
                       "missing_share", "status")]
  rownames(batches) <- NULL
  failed <- batches$xml_batch_id[startsWith(batches$status, "missing")]
  result <- list(passed = length(failed) == 0, as_of = as.character(as.Date(as_of)),
                 batches = batches, failed = failed)

  if (length(failed) > 0) {
    detail <- batches[batches$xml_batch_id %in% failed, ]
    msg <- sprintf("%s (published %s): %d of %d in-scope filings absent from the build index",
                   detail$xml_batch_id, ifelse(is.na(detail$published), "unknown", as.character(detail$published)),
                   detail$n_irs - detail$n_in_index, detail$n_irs)
    if (strict) {
      stop("index coverage gate failed for ", length(failed), " IRS batch(es):\n  ",
           paste(msg, collapse = "\n  "), "\n  (threshold ", max_missing_share,
           "; the build index is missing IRS releases)")
    }
    cli::cli_alert_warning("index coverage: {length(failed)} IRS batch(es) under-covered")
  } else {
    cli::cli_alert_success("index coverage: all {nrow(batches)} IRS batches covered (as of {result$as_of})")
  }
  result
}

#' Calendar years of IRS index files that can hold filings for the scope.
#' @noRd
irs_index_years_for_scope <- function(scope, as_of = Sys.Date()) {
  tax_years <- as.integer(scope$tax_years %||% integer(0))
  if (length(tax_years) == 0) stop("scope$tax_years is empty")
  seq.int(min(tax_years) + 1L, as.integer(format(as.Date(as_of), "%Y")))
}

# ---- Gate runner for the Phase 0 build -------------------------------------

#' Run the IRS batch coverage gate for a Phase 0 build
#'
#' Fetches the IRS annual index files for the build scope, reads each
#' batch's publication date from the IRS server, compares the build index
#' against them with `verify_index_coverage()`, and returns the block that
#' `run_phase0()` records in the manifest as `inputs.index_coverage`.
#'
#' The gate is on by default. `config$upstream$index_coverage_gate` holds
#' the settings: `enabled`, `max_missing_share`, `min_batch_filings`,
#' `local_cache_dir`, `skip_sync`. Opting out is explicit and is itself
#' recorded in the manifest, so a published vintage always says whether
#' its index was checked against the IRS.
#'
#' @param index The build index (column `object_id`), already filtered to
#'   scope, as returned by `fetch_gt_indices()`.
#' @param config Package config.
#' @param as_of Date of the build index snapshot. Batches the IRS published
#'   after this date are reported, not failed.
#' @param irs Optional IRS index as returned by `fetch_irs_indices()`. When
#'   supplied, no index file is downloaded (used by tests).
#' @param batch_dates Optional publication dates as returned by
#'   `irs_batch_dates()`. When supplied, the IRS server is not contacted.
#' @return A list for the manifest. When the gate is off: `enabled = FALSE`
#'   and `reason`. When it runs: `enabled = TRUE`, `passed`, `as_of`,
#'   `max_missing_share`, `min_batch_filings`, `irs_index_files` (one row
#'   per IRS index file: `url`, `retrieved_at_utc`, `bytes`, `sha256`,
#'   `rows`), `batches` (the per-batch table from
#'   `verify_index_coverage()`) and `failed`.
#' @details The gate runs in strict mode: a failed batch stops the build
#'   before extraction, so a manifest carrying `passed = FALSE` is never
#'   written. The IRS index years fetched run from the year after the
#'   earliest tax year in scope to the year of `as_of`.
#' @export
run_index_coverage_gate <- function(index,
                                    config,
                                    as_of = Sys.Date(),
                                    irs = NULL,
                                    batch_dates = NULL) {
  gate_config <- config$upstream$index_coverage_gate %||% list()
  enabled <- gate_config$enabled %||% TRUE

  if (!isTRUE(enabled)) {
    cli::cli_alert_warning(
      "index coverage gate: opted out in config (upstream.index_coverage_gate.enabled = false)"
    )
    return(list(enabled = FALSE, reason = "opted out in config"))
  }

  max_missing_share <- gate_config$max_missing_share %||% 0.05
  min_batch_filings <- as.integer(gate_config$min_batch_filings %||% 100L)
  local_cache_dir <- gate_config$local_cache_dir
  skip_sync <- isTRUE(gate_config$skip_sync)

  # IRS index files: the authoritative list of what the IRS has published.
  if (is.null(irs)) {
    index_years <- irs_index_years_for_scope(config$scope, as_of = as_of)
    irs <- fetch_irs_indices(
      index_years,
      config = config,
      local_cache_dir = local_cache_dir,
      skip_sync = skip_sync
    )
  }

  # Publication date per batch, from the ZIP's Last-Modified header.
  if (is.null(batch_dates)) {
    batch_dates <- irs_batch_dates(
      unique(irs$xml_batch_id),
      config = config,
      local_cache_dir = local_cache_dir,
      skip_sync = skip_sync
    )
  }

  result <- verify_index_coverage(
    index,
    irs,
    config$scope,
    batch_dates = batch_dates,
    as_of = as_of,
    min_batch_filings = min_batch_filings,
    max_missing_share = max_missing_share,
    strict = TRUE
  )

  sources <- attr(irs, "sources")
  irs_index_files <- if (is.null(sources)) {
    list()
  } else {
    sources[, c("url", "retrieved_at_utc", "bytes", "sha256", "rows"), drop = FALSE]
  }

  batches <- result$batches
  batches$published <- as.character(batches$published)

  list(
    enabled = TRUE,
    passed = result$passed,
    as_of = result$as_of,
    max_missing_share = max_missing_share,
    min_batch_filings = min_batch_filings,
    irs_index_files = irs_index_files,
    batches = batches,
    failed = as.list(result$failed)
  )
}
