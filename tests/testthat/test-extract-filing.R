make_990_fixture <- function() {
  tmp <- tempfile(fileext = ".xml")
  xml <- '<?xml version="1.0"?>
<Return xmlns="http://www.irs.gov/efile">
  <ReturnHeader>
    <Filer><EIN>123456789</EIN></Filer>
    <ReturnTypeCd>990</ReturnTypeCd>
  </ReturnHeader>
  <ReturnData>
    <IRS990>
      <GovernmentGrantsAmt>42000</GovernmentGrantsAmt>
      <OrgName>Example Org</OrgName>
    </IRS990>
  </ReturnData>
</Return>'
  writeLines(xml, tmp)
  tmp
}

test_that("extract_filing pulls the configured XPath value and coerces type", {
  xml_path <- make_990_fixture()
  on.exit(unlink(xml_path), add = TRUE)

  dict <- data.frame(
    nccs_name    = c("government_grants", "org_name"),
    data_type    = c("double", "string"),
    xpath_claims = c(
      "2024:v1.0:/Return/ReturnData/IRS990/GovernmentGrantsAmt",
      "2024:v1.0:/Return/ReturnData/IRS990/OrgName"
    ),
    stringsAsFactors = FALSE
  )

  row <- list(
    local_path = xml_path,
    filing_receipt_id = "rcpt-1",
    ein = "123456789",
    tax_year = 2024,
    form_type = "990"
  )

  out <- extract_filing(row, dict, version = "v1.0")
  expect_equal(out$government_grants, 42000)
  expect_equal(out$org_name, "Example Org")
  expect_true(is.na(out[["_extract_error"]]))
  expect_equal(out$ein, "123456789")
  expect_equal(out$tax_year, 2024L)
})

test_that("extract_filing skips fields whose XPath does not match the (year, version)", {
  xml_path <- make_990_fixture()
  on.exit(unlink(xml_path), add = TRUE)

  dict <- data.frame(
    nccs_name    = "government_grants",
    data_type    = "double",
    xpath_claims = "2023:v1.0:/Return/ReturnData/IRS990/GovernmentGrantsAmt",
    stringsAsFactors = FALSE
  )
  row <- list(local_path = xml_path, tax_year = 2024, form_type = "990")
  out <- extract_filing(row, dict, version = "v1.0")
  expect_true(is.na(out$government_grants))
})

test_that("extract_filing returns NA row + error on parse failure", {
  bad <- tempfile(fileext = ".xml")
  writeLines("<<not xml>>", bad)
  on.exit(unlink(bad), add = TRUE)

  dict <- data.frame(
    nccs_name = "x", data_type = "double",
    xpath_claims = "2024:v1.0:/a", stringsAsFactors = FALSE
  )
  row <- list(local_path = bad, tax_year = 2024, form_type = "990")
  out <- extract_filing(row, dict, version = "v1.0")
  expect_true(is.na(out$x))
  expect_false(is.na(out[["_extract_error"]]))
})

test_that("ns_qualify_xpath prefixes every element step", {
  expect_equal(
    nccs.data.efile:::ns_qualify_xpath(
      "/Return/ReturnData/IRS990/GovernmentGrantsAmt", "e"),
    "/e:Return/e:ReturnData/e:IRS990/e:GovernmentGrantsAmt"
  )
})

test_that("extract_filing is namespace-aware (no xml_ns_strip) with extra namespaces present", {
  # Real IRS e-file XML declares xsi alongside the default efile namespace.
  # The extractor must resolve values via the bound default namespace, not
  # by stripping. This is the regression guard for the v2026.06 fix.
  tmp <- tempfile(fileext = ".xml")
  writeLines(paste0(
    '<?xml version="1.0"?>\n',
    '<Return xmlns="http://www.irs.gov/efile" ',
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ',
    'returnVersion="2024v5.1">\n',
    '  <ReturnData><IRS990>',
    '<GovernmentGrantsAmt>42000</GovernmentGrantsAmt>',
    '</IRS990></ReturnData>\n</Return>'), tmp)
  on.exit(unlink(tmp), add = TRUE)

  dict <- data.frame(
    nccs_name    = "government_grants",
    data_type    = "double",
    xpath_claims = "2024:v1.0:/Return/ReturnData/IRS990/GovernmentGrantsAmt",
    stringsAsFactors = FALSE
  )
  row <- list(local_path = tmp, tax_year = 2024, form_type = "990")
  out <- extract_filing(row, dict, version = "v1.0")
  expect_equal(out$government_grants, 42000)
  expect_true(is.na(out[["_extract_error"]]))
})

test_that("s3_uri_to_https builds a virtual-hosted URL", {
  expect_equal(
    nccs.data.efile:::s3_uri_to_https("s3://gt990datalake-rawdata/990xmls/123_public.xml"),
    "https://gt990datalake-rawdata.s3.amazonaws.com/990xmls/123_public.xml"
  )
  expect_error(nccs.data.efile:::s3_uri_to_https("https://x.example/y"), "not an s3")
})
