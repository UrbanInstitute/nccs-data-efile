irs_fixture <- function() {
  data.frame(
    object_id = sprintf("obj%02d", 1:12),
    return_type = c(rep("990", 10), "990EZ", "990PF"),
    tax_period = c(rep("202312", 5), rep("202406", 5), "202312", "202312"),
    tax_year = c(rep(2023L, 5), rep(2023L, 5), 2023L, 2023L),
    xml_batch_id = c(rep("2025_TEOS_XML_01A", 5), rep("2025_TEOS_XML_09A", 5),
                     "2025_TEOS_XML_01A", "2025_TEOS_XML_01A"),
    index_year = 2025L,
    stringsAsFactors = FALSE
  )
}
scope <- list(forms = c("990", "990PF"), tax_years = 2023L)

test_that("tax year follows the period end convention", {
  expect_equal(nccs.data.efile:::irs_tax_year(c("202312", "202406", "202501")), c(2023L, 2023L, 2024L))
})

test_that("batch release month parses the IRS batch id", {
  expect_equal(nccs.data.efile:::batch_release_month(c("2025_TEOS_XML_09A", "junk")),
               as.Date(c("2025-09-01", NA)))
})

test_that("the gate passes when every batch is covered", {
  index <- data.frame(object_id = sprintf("obj%02d", 1:12), stringsAsFactors = FALSE)
  r <- verify_index_coverage(index, irs_fixture(), scope, as_of = as.Date("2025-10-15"),
                             min_batch_filings = 1L)
  expect_true(r$passed)
  expect_equal(r$batches$status, c("ok", "ok"))
  expect_equal(r$batches$n_irs, c(6L, 5L))  # 990EZ row excluded by scope
})

# obj01-05 and obj12 are batch 01A's six in-scope filings; obj06-10 are 09A's.
covered_01a <- data.frame(object_id = c(sprintf("obj%02d", 1:5), "obj12"), stringsAsFactors = FALSE)

test_that("the gate fails on a batch the build index skipped", {
  index <- covered_01a
  expect_error(
    verify_index_coverage(index, irs_fixture(), scope, as_of = as.Date("2025-10-15"),
                          min_batch_filings = 1L),
    "2025_TEOS_XML_09A: 5 of 5"
  )
  r <- verify_index_coverage(index, irs_fixture(), scope, as_of = as.Date("2025-10-15"),
                             min_batch_filings = 1L, strict = FALSE)
  expect_false(r$passed)
  expect_equal(r$failed, "2025_TEOS_XML_09A")
})

test_that("batches released after the snapshot do not fail the gate", {
  index <- covered_01a
  r <- verify_index_coverage(index, irs_fixture(), scope, as_of = as.Date("2025-08-20"),
                             min_batch_filings = 1L)
  expect_true(r$passed)
  expect_equal(r$batches$status[r$batches$xml_batch_id == "2025_TEOS_XML_09A"], "after_snapshot")
})

test_that("a batch from the snapshot month is treated as after the snapshot", {
  r <- verify_index_coverage(covered_01a, irs_fixture(), scope, as_of = as.Date("2025-09-30"),
                             min_batch_filings = 1L)
  expect_true(r$passed)
  expect_equal(r$batches$status[r$batches$xml_batch_id == "2025_TEOS_XML_09A"], "after_snapshot")
})

test_that("small under-covered batches are reported but do not fail", {
  index <- covered_01a
  r <- verify_index_coverage(index, irs_fixture(), scope, as_of = as.Date("2025-10-15"),
                             min_batch_filings = 100L)
  expect_true(r$passed)
  expect_equal(r$batches$status[2], "small")
})

test_that("filings without a batch id are reported but never fail", {
  irs <- irs_fixture()
  irs$xml_batch_id[6:10] <- "no_batch_id"
  r <- verify_index_coverage(covered_01a, irs, scope, as_of = as.Date("2025-10-15"), min_batch_filings = 1L)
  expect_true(r$passed)
  expect_equal(r$batches$status[r$batches$xml_batch_id == "no_batch_id"], "no_batch_id")
})

test_that("index years span the scope's first filing year to the snapshot year", {
  expect_equal(nccs.data.efile:::irs_index_years_for_scope(list(tax_years = 2020:2024), as.Date("2026-06-08")),
               2021:2026)
})
