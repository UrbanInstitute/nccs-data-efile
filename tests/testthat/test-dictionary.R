test_that("resolve_xpath returns the matching tuple", {
  dict <- data.frame(
    nccs_name = c("government_grants", "pri_total"),
    xpath_claims = c(
      "2023:v1.0:/Return/ReturnData/IRS990/Gov; 2024:v1.0:/Return/ReturnData/IRS990/GovV2",
      "2024:v1.0:/Return/ReturnData/IRS990PF/PRI"
    ),
    stringsAsFactors = FALSE
  )

  expect_equal(
    resolve_xpath(dict, "government_grants", 2024, "v1.0"),
    "/Return/ReturnData/IRS990/GovV2"
  )
  expect_equal(
    resolve_xpath(dict, "pri_total", 2024, "v1.0"),
    "/Return/ReturnData/IRS990PF/PRI"
  )
})

test_that("resolve_xpath returns NA when no tuple matches", {
  dict <- data.frame(
    nccs_name = "x",
    xpath_claims = "2024:v1.0:/A/B",
    stringsAsFactors = FALSE
  )
  expect_true(is.na(resolve_xpath(dict, "x", 2023, "v1.0")))
  expect_true(is.na(resolve_xpath(dict, "x", 2024, "v2.0")))
  expect_true(is.na(resolve_xpath(dict, "missing_field", 2024, "v1.0")))
})

test_that("resolve_xpath preserves colons inside the XPath", {
  dict <- data.frame(
    nccs_name = "x",
    xpath_claims = "2024:v1.0:/tns:Return/tns:Data",
    stringsAsFactors = FALSE
  )
  expect_equal(resolve_xpath(dict, "x", 2024, "v1.0"),
               "/tns:Return/tns:Data")
})

test_that("resolve_xpath errors on duplicate dictionary rows", {
  dict <- data.frame(
    nccs_name = c("dup", "dup"),
    xpath_claims = c("2024:v1.0:/a", "2024:v1.0:/b"),
    stringsAsFactors = FALSE
  )
  expect_error(resolve_xpath(dict, "dup", 2024, "v1.0"), "2 rows")
})
