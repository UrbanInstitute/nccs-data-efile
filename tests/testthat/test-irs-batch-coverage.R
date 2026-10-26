# summarise_batch_coverage() and complete_through_batch() on fixtures.
# Reading the IRS index and the release header tables needs the network
# and is not tested here.

irs_rows <- data.frame(
  object_id = sprintf("obj%02d", 1:10),
  return_type = c(rep("990", 4), rep("990EZ", 2), rep("990PF", 3), "990T"),
  xml_batch_id = c(rep("2026_TEOS_XML_01A", 3), rep("2026_TEOS_XML_02A", 3),
                   rep("2026_TEOS_XML_01A", 2), "2026_TEOS_XML_03A", "2026_TEOS_XML_01A"),
  stringsAsFactors = FALSE
)
header_rows <- data.frame(
  object_id = c("obj01", "obj02", "obj03", "obj04", "obj07"),
  source_host = c("gt990datalake-rawdata.s3.amazonaws.com", "gt990datalake-rawdata.s3.amazonaws.com",
                  "nccs-efile.s3.us-east-1.amazonaws.com", "gt990datalake-rawdata.s3.amazonaws.com", "x"),
  stringsAsFactors = FALSE
)
batch_dates <- data.frame(
  xml_batch_id = c("2026_TEOS_XML_01A", "2026_TEOS_XML_02A", "2026_TEOS_XML_03A"),
  published = as.Date(c("2026-02-01", "2026-03-01", "2026-11-01")),
  stringsAsFactors = FALSE
)

test_that("coverage is counted per batch with the XML source split", {
  report <- summarise_batch_coverage(irs_rows, header_rows, forms = c("990", "990EZ"),
                                     build_date = as.Date("2026-10-09"), batch_dates = batch_dates)
  expect_equal(report$xml_batch_id, c("2026_TEOS_XML_01A", "2026_TEOS_XML_02A"))
  # 01A: obj01-03 all found, two from GivingTuesday and one from the patch store.
  expect_equal(report$n_irs, c(3, 3))
  expect_equal(report$n_found, c(3, 1))
  expect_equal(report$n_from_givingtuesday, c(2, 1))
  expect_equal(report$n_from_nccs_patch, c(1, 0))
  expect_equal(report$status, c("complete", "partial"))
  # The 990T row and the 990-PF rows are out of scope for this release.
  expect_false("2026_TEOS_XML_03A" %in% report$xml_batch_id)
})

test_that("a batch the IRS published after the build is not counted as missing", {
  report <- summarise_batch_coverage(irs_rows, header_rows, forms = "990PF",
                                     build_date = as.Date("2026-10-09"), batch_dates = batch_dates)
  expect_equal(report$status[report$xml_batch_id == "2026_TEOS_XML_03A"], "after_build")
  expect_equal(report$status[report$xml_batch_id == "2026_TEOS_XML_01A"], "partial")
  expect_equal(report$n_from_other[report$xml_batch_id == "2026_TEOS_XML_01A"], 1)
})

test_that("complete-through is the last batch before the first gap", {
  report <- data.frame(
    xml_batch_id = c("2026_TEOS_XML_01A", "2026_TEOS_XML_02A", "2026_TEOS_XML_03A", "no_batch_id"),
    status = c("complete", "complete", "after_build", "partial"),
    missing_share = c(0, 0, 1, 0.5),
    stringsAsFactors = FALSE
  )
  expect_equal(complete_through_batch(report), "2026_TEOS_XML_02A")
  # Three stragglers in a batch of 120,000 do not move the cutoff back.
  report$status[2] <- "partial"
  report$missing_share[2] <- 3 / 120000
  expect_equal(complete_through_batch(report), "2026_TEOS_XML_02A")
  # A real gap does.
  report$missing_share[2] <- 0.02
  expect_equal(complete_through_batch(report), "2026_TEOS_XML_01A")
  report$status[1] <- "missing"
  report$missing_share[1] <- 1
  expect_true(is.na(complete_through_batch(report)))
  report$status <- "complete"
  report$missing_share <- 0
  expect_equal(complete_through_batch(report), "2026_TEOS_XML_03A")
})
