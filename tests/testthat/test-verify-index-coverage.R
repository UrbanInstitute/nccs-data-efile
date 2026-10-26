irs_fixture <- function() {
  data.frame(
    object_id = sprintf("obj%02d", 1:12),
    return_type = c(rep("990", 10), "990EZ", "990PF"),
    tax_period = c(rep("202312", 5), rep("202406", 5), "202312", "202312"),
    tax_year = c(rep(2023L, 5), rep(2023L, 5), 2023L, 2023L),
    tax_year_ambiguous = c(rep(FALSE, 5), rep(TRUE, 5), FALSE, FALSE),
    xml_batch_id = c(rep("2025_TEOS_XML_01A", 5), rep("2025_TEOS_XML_09A", 5),
                     "2025_TEOS_XML_01A", "2025_TEOS_XML_01A"),
    index_year = 2025L,
    stringsAsFactors = FALSE
  )
}
dates_fixture <- data.frame(
  xml_batch_id = c("2025_TEOS_XML_01A", "2025_TEOS_XML_09A"),
  published = as.Date(c("2025-02-19", "2025-11-19")),
  stringsAsFactors = FALSE
)
# Scope runs to 2024 so the June-2024 period ends in the fixture are unambiguous.
scope <- list(forms = c("990", "990PF"), tax_years = 2023:2024)
scope_2023 <- list(forms = c("990", "990PF"), tax_years = 2023L)
# obj01-05 and obj12 are batch 01A's six in-scope filings; obj06-10 are 09A's.
covered_01a <- data.frame(object_id = c(sprintf("obj%02d", 1:5), "obj12"), stringsAsFactors = FALSE)
all_covered <- data.frame(object_id = sprintf("obj%02d", 1:12), stringsAsFactors = FALSE)

test_that("tax year follows the period end convention and flags non-December ends", {
  expect_equal(nccs.data.efile:::irs_tax_year(c("202312", "202406", "202501")), c(2023L, 2023L, 2024L))
  expect_equal(nccs.data.efile:::irs_tax_year_ambiguous(c("202312", "202406")), c(FALSE, TRUE))
})

test_that("batch name month parses the IRS batch id", {
  expect_equal(nccs.data.efile:::batch_name_month(c("2025_TEOS_XML_09A", "junk")),
               as.Date(c("2025-09-01", NA)))
})

test_that("the gate passes when every batch is covered", {
  r <- verify_index_coverage(all_covered, irs_fixture(), scope, batch_dates = dates_fixture,
                             as_of = as.Date("2025-12-15"), min_batch_filings = 1L)
  expect_true(r$passed)
  expect_equal(r$batches$status, c("ok", "ok"))
  expect_equal(r$batches$n_irs, c(6L, 5L))  # 990EZ row excluded by scope
  expect_equal(r$batches$published, dates_fixture$published)
})

test_that("the gate fails on a batch the build index skipped, naming its publication date", {
  expect_error(
    verify_index_coverage(covered_01a, irs_fixture(), scope, batch_dates = dates_fixture,
                          as_of = as.Date("2025-12-15"), min_batch_filings = 1L),
    "2025_TEOS_XML_09A \\(published 2025-11-19\\): 5 of 5"
  )
  r <- verify_index_coverage(covered_01a, irs_fixture(), scope, batch_dates = dates_fixture,
                             as_of = as.Date("2025-12-15"), min_batch_filings = 1L, strict = FALSE)
  expect_false(r$passed)
  expect_equal(r$failed, "2025_TEOS_XML_09A")
})

test_that("a batch published after the snapshot does not fail, even if its name month is earlier", {
  # 09A is named for September but was published 2025-11-19; a 2025-10-09 snapshot predates it.
  r <- verify_index_coverage(covered_01a, irs_fixture(), scope, batch_dates = dates_fixture,
                             as_of = as.Date("2025-10-09"), min_batch_filings = 1L)
  expect_true(r$passed)
  expect_equal(r$batches$status[r$batches$xml_batch_id == "2025_TEOS_XML_09A"], "after_snapshot")
})

test_that("a batch with no publication date is treated as before the snapshot and marked", {
  no_date <- dates_fixture; no_date$published[2] <- as.Date(NA)
  r <- verify_index_coverage(covered_01a, irs_fixture(), scope, batch_dates = no_date,
                             as_of = as.Date("2025-10-09"), min_batch_filings = 1L, strict = FALSE)
  expect_false(r$passed)
  expect_equal(r$batches$status[2], "missing (date_unknown)")
})

test_that("small under-covered batches are reported but do not fail", {
  r <- verify_index_coverage(covered_01a, irs_fixture(), scope, batch_dates = dates_fixture,
                             as_of = as.Date("2025-12-15"), min_batch_filings = 100L)
  expect_true(r$passed)
  expect_equal(r$batches$status[2], "small")
})

test_that("ambiguous short-year rows at the scope boundary leave the denominator", {
  # 09A's five rows end in June 2024 with estimated tax year 2023 = max(scope):
  # they may be TY2024 short-year returns, so they are excluded, not failed.
  r <- verify_index_coverage(covered_01a, irs_fixture(), scope_2023, batch_dates = dates_fixture,
                             as_of = as.Date("2025-12-15"), min_batch_filings = 1L)
  b <- r$batches[r$batches$xml_batch_id == "2025_TEOS_XML_09A", ]
  expect_equal(b$n_irs, 0L)
  expect_equal(b$n_ambiguous, 5L)
  expect_true(r$passed)
  # With scope extended past 2023 the same rows are unambiguous and count.
  r2 <- verify_index_coverage(covered_01a, irs_fixture(), scope,
                              batch_dates = dates_fixture, as_of = as.Date("2025-12-15"),
                              min_batch_filings = 1L, strict = FALSE)
  expect_equal(r2$failed, "2025_TEOS_XML_09A")
})

test_that("filings without a batch id are reported but never fail", {
  irs <- irs_fixture()
  irs$xml_batch_id[1:5] <- "no_batch_id"   # obj01-05 lose their batch; the index lacks all five
  index <- data.frame(object_id = sprintf("obj%02d", 6:12), stringsAsFactors = FALSE)
  r <- verify_index_coverage(index, irs, scope, batch_dates = dates_fixture,
                             as_of = as.Date("2025-12-15"), min_batch_filings = 1L)
  expect_true(r$passed)
  expect_equal(r$batches$status[r$batches$xml_batch_id == "no_batch_id"], "no_batch_id")
})

test_that("irs_batch_dates reads cached dates without the network", {
  dir <- tempfile(); dir.create(dir)
  utils::write.csv(data.frame(xml_batch_id = "2025_TEOS_XML_09A", published = "2025-11-19",
                              source_url = "u", retrieved_at_utc = "t"),
                   file.path(dir, "batch-dates.csv"), row.names = FALSE)
  d <- irs_batch_dates(c("2025_TEOS_XML_09A", "no_batch_id"), config = list(), local_cache_dir = dir, skip_sync = TRUE)
  expect_equal(d$xml_batch_id, "2025_TEOS_XML_09A")
  expect_equal(d$published, as.Date("2025-11-19"))
})

test_that("index years span the scope's first filing year to the snapshot year", {
  expect_equal(nccs.data.efile:::irs_index_years_for_scope(list(tax_years = 2020:2024), as.Date("2026-06-08")),
               2021:2026)
})

# ---- run_index_coverage_gate(): the manifest block ------------------------

test_that("the gate runner records an opt-out in the manifest block", {
  cfg <- list(scope = scope, upstream = list(index_coverage_gate = list(enabled = FALSE)))
  block <- run_index_coverage_gate(all_covered, cfg)
  expect_false(block$enabled)
  expect_equal(block$reason, "opted out in config")
})

test_that("the gate runner returns the manifest block when every batch is covered", {
  irs <- irs_fixture()
  attr(irs, "sources") <- data.frame(
    url = "https://example.invalid/index_2025.csv", path = "index_2025.csv",
    retrieved_at_utc = "2025-12-15T00:00:00Z", bytes = 10L, sha256 = "abc", rows = 12L,
    stringsAsFactors = FALSE
  )
  cfg <- list(scope = scope,
              upstream = list(index_coverage_gate = list(enabled = TRUE, min_batch_filings = 1)))
  block <- run_index_coverage_gate(all_covered, cfg, as_of = as.Date("2025-12-15"),
                                   irs = irs, batch_dates = dates_fixture)
  expect_true(block$enabled)
  expect_true(block$passed)
  expect_equal(block$as_of, "2025-12-15")
  expect_equal(block$max_missing_share, 0.05)
  expect_equal(block$min_batch_filings, 1L)
  expect_equal(names(block$irs_index_files), c("url", "retrieved_at_utc", "bytes", "sha256", "rows"))
  expect_equal(block$batches$xml_batch_id, c("2025_TEOS_XML_01A", "2025_TEOS_XML_09A"))
  expect_type(block$batches$published, "character")
  expect_length(block$failed, 0)
})

test_that("the gate runner stops the build when a published batch is missing", {
  cfg <- list(scope = scope,
              upstream = list(index_coverage_gate = list(enabled = TRUE, min_batch_filings = 1)))
  expect_error(
    run_index_coverage_gate(covered_01a, cfg, as_of = as.Date("2025-12-15"),
                            irs = irs_fixture(), batch_dates = dates_fixture),
    "2025_TEOS_XML_09A"
  )
})

test_that("a partial IRS index cache is an error, not a pass", {
  cache_dir <- tempfile("irs-cache-")
  dir.create(cache_dir)
  on.exit(unlink(cache_dir, recursive = TRUE), add = TRUE)
  writeLines(
    c("RETURN_ID,FILING_TYPE,EIN,TAX_PERIOD,SUB_DATE,TAXPAYER_NAME,RETURN_TYPE,DLN,OBJECT_ID,XML_BATCH_ID",
      "1,EFILE,000000001,202312,2024-05-01,ORG,990,1,obj01,2024_TEOS_XML_05A"),
    file.path(cache_dir, "index_2024.csv")
  )
  # Only 2024 is cached; 2025 is requested too. The missing year must stop
  # the read rather than be skipped, or the check would pass on part of
  # the IRS record.
  expect_error(
    fetch_irs_indices(2024:2025, config = list(), local_cache_dir = cache_dir, skip_sync = TRUE),
    "2025"
  )
  # The complete cache reads fine.
  irs <- fetch_irs_indices(2024L, config = list(), local_cache_dir = cache_dir, skip_sync = TRUE)
  expect_equal(irs$object_id, "obj01")
  expect_equal(irs$xml_batch_id, "2024_TEOS_XML_05A")

  # The same partial cache through the runner: error, not enabled/passed.
  cfg <- list(scope = list(forms = "990", tax_years = 2023:2024),
              upstream = list(index_coverage_gate = list(enabled = TRUE, skip_sync = TRUE,
                                                         local_cache_dir = cache_dir)))
  expect_error(
    run_index_coverage_gate(data.frame(object_id = "obj01"), cfg, as_of = as.Date("2025-12-15")),
    "2025"
  )
})
