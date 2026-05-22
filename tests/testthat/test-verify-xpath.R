make_fixture_xsd <- function(dir) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  xsd <- '<?xml version="1.0"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
  <xs:element name="Return" type="ReturnType"/>

  <xs:complexType name="ReturnType">
    <xs:sequence>
      <xs:element name="ReturnData" type="ReturnDataType"/>
    </xs:sequence>
  </xs:complexType>

  <xs:complexType name="ReturnDataType">
    <xs:sequence>
      <xs:element name="IRS990" type="IRS990Type"/>
    </xs:sequence>
  </xs:complexType>

  <xs:complexType name="IRS990Type">
    <xs:sequence>
      <xs:element name="GovernmentGrantsAmt" type="USAmountType"/>
      <xs:element name="OrgName" type="StringType"/>
    </xs:sequence>
  </xs:complexType>
</xs:schema>'
  writeLines(xsd, file.path(dir, "test.xsd"))
  dir
}

test_that("verify_xpath matches expected type on a hit", {
  dir <- make_fixture_xsd(file.path(tempdir(), "xsd-hit"))
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  r <- verify_xpath(
    xpath = "/Return/ReturnData/IRS990/GovernmentGrantsAmt",
    tax_year = 2024, version = "v1.0",
    expected_type = "USAmountType",
    xsd_dir = dir
  )
  expect_true(r$found)
  expect_equal(r$actual_type, "USAmountType")
  expect_true(r$matches_expected)
  expect_equal(r$path_to_element, "/Return/ReturnData/IRS990/GovernmentGrantsAmt")
})

test_that("verify_xpath flags type mismatch", {
  dir <- make_fixture_xsd(file.path(tempdir(), "xsd-mismatch"))
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  r <- verify_xpath(
    xpath = "/Return/ReturnData/IRS990/OrgName",
    tax_year = 2024, version = "v1.0",
    expected_type = "USAmountType",
    xsd_dir = dir
  )
  expect_true(r$found)
  expect_equal(r$actual_type, "StringType")
  expect_false(r$matches_expected)
})

test_that("verify_xpath reports not-found when element missing", {
  dir <- make_fixture_xsd(file.path(tempdir(), "xsd-miss"))
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  r <- verify_xpath(
    xpath = "/Return/ReturnData/IRS990/NonExistentAmt",
    tax_year = 2024, version = "v1.0",
    expected_type = "USAmountType",
    xsd_dir = dir
  )
  expect_false(r$found)
  expect_true(is.na(r$actual_type))
  expect_false(r$matches_expected)
})

test_that("parse_xpath_steps rejects unsupported syntax", {
  expect_error(nccs.data.efile:::parse_xpath_steps("Return/Foo"), "absolute")
  expect_error(nccs.data.efile:::parse_xpath_steps("/Return/Foo[1]"), "unsupported")
  expect_error(nccs.data.efile:::parse_xpath_steps("/Return/*"), "unsupported")
})

test_that("parse_xpath_steps strips namespace prefixes", {
  expect_equal(
    nccs.data.efile:::parse_xpath_steps("/tns:Return/tns:ReturnData"),
    c("Return", "ReturnData")
  )
})
