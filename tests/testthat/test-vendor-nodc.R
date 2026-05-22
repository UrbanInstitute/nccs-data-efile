test_that("nodc_raw_url builds the expected GitHub raw URL", {
  expect_equal(
    nccs.data.efile:::nodc_raw_url("abc123"),
    "https://raw.githubusercontent.com/Nonprofit-Open-Data-Collective/irs-efile-master-concordance-file/abc123/concordance.csv"
  )
})

test_that("nodc_s3_uri appends a trailing slash and date stamp", {
  uri <- nccs.data.efile:::nodc_s3_uri(
    "abc123",
    "s3://nccsdata/processed/efile/concordance",
    today = as.Date("2026-06-15")
  )
  expect_equal(uri, "s3://nccsdata/processed/efile/concordance/abc123_2026-06-15.csv")
})

test_that("nodc_s3_uri tolerates a trailing slash on the prefix", {
  uri <- nccs.data.efile:::nodc_s3_uri(
    "abc123",
    "s3://nccsdata/processed/efile/concordance/",
    today = as.Date("2026-06-15")
  )
  expect_equal(uri, "s3://nccsdata/processed/efile/concordance/abc123_2026-06-15.csv")
})

test_that("vendor_nodc errors when SHA is not pinned", {
  cfg <- list(
    vendored = list(nodc_concordance_sha = NULL,
                    nodc_concordance_s3_prefix = "s3://x/"),
    aws = list(profile = "thiya")
  )
  expect_error(vendor_nodc(config = cfg), "not pinned")
})
