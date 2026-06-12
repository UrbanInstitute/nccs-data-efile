# Relational scalar extraction (ADR 0004 step 2): naming, typing, union/NA-fill,
# and the returnheader-shared-across-forms path. Uses a synthetic inventory
# (the plan input) + synthetic filing XML on disk (via local_path).

# A minimal Layer 1 inventory: returnheader + 990 body + 990PF body, with a
# repeating element and a bounded-multi leaf that must NOT enter the scalar set,
# and a version-only column (present in one cell) to test union/NA-fill.
fixture_inventory <- function() {
  rows <- function(...) data.frame(..., stringsAsFactors = FALSE)
  base <- rows(
    xpath = c(
      "/Return/ReturnHeader/Filer/EIN",
      "/Return/ReturnHeader/TaxYr",
      "/Return/ReturnData/IRS990/GovernmentGrantsAmt",
      "/Return/ReturnData/IRS990/Organization501c3Ind",
      "/Return/ReturnData/IRS990/TaxPeriodBeginDt",
      "/Return/ReturnData/IRS990/ForeignCountryCd",     # bounded-multi -> excluded
      "/Return/ReturnData/IRS990/GrantsGrp/Amt",        # under repeating -> excluded
      "/Return/ReturnData/IRS990PF/SumOfProgramRelatedInvstGrp/TotalAmt"
    ),
    xsd_type = c("EINType", "YearType", "USAmountType", "BooleanType",
                 "DateType", "CountryType", "USAmountType", "USAmountType"),
    is_leaf = c(TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE),
    repeating = c(FALSE, FALSE, FALSE, FALSE, FALSE, TRUE, TRUE, FALSE),
    annotation = NA_character_
  )
  base$tax_year <- "2022"; base$version <- "5.0"
  # a second cell (2024 v5.1) that adds one extra 990 column -> tests the union
  extra <- rows(
    xpath = "/Return/ReturnData/IRS990/NewInThisVersionAmt",
    xsd_type = "USAmountType", is_leaf = TRUE, repeating = FALSE,
    annotation = NA_character_
  )
  extra$tax_year <- "2024"; extra$version <- "5.1"
  rbind(base, extra)
}

write_filing <- function(dir, name, body) {
  p <- file.path(dir, name)
  writeLines(sprintf(
    '<?xml version="1.0"?>\n<Return xmlns="http://www.irs.gov/efile">%s</Return>', body), p)
  p
}

test_that("plan derives scalar columns, names, and target types; excludes repeating", {
  plan <- build_relational_plan(fixture_inventory())
  expect_setequal(names(plan), c("returnheader", "f990_header", "f990pf_header"))

  f990 <- plan$f990_header$leaves
  # excluded: bounded-multi leaf and a leaf under a repeating group
  expect_false("ForeignCountryCd" %in% f990$col_name)
  expect_false("GrantsGrp_Amt" %in% f990$col_name)
  # included, with relative-path names + mapped types
  expect_true(all(c("GovernmentGrantsAmt", "Organization501c3Ind",
                    "TaxPeriodBeginDt", "NewInThisVersionAmt") %in% f990$col_name))
  tt <- setNames(f990$target_type, f990$col_name)
  expect_equal(tt[["GovernmentGrantsAmt"]], "double")
  expect_equal(tt[["Organization501c3Ind"]], "bool")
  expect_equal(tt[["TaxPeriodBeginDt"]], "date")

  # returnheader names are relative to ITS root; EIN stays string (leading zeros)
  rh <- plan$returnheader$leaves
  expect_true("Filer_EIN" %in% rh$col_name)
  expect_equal(setNames(rh$target_type, rh$col_name)[["Filer_EIN"]], "string")
})

test_that("a 990 filing yields returnheader + f990_header with typed values", {
  plan <- build_relational_plan(fixture_inventory())
  dir <- tempfile("rel_"); dir.create(dir)
  xml <- write_filing(dir, "f990.xml", paste0(
    "<ReturnHeader><Filer><EIN>001234567</EIN></Filer><TaxYr>2022</TaxYr></ReturnHeader>",
    "<ReturnData><IRS990>",
    "<GovernmentGrantsAmt>75000</GovernmentGrantsAmt>",
    "<Organization501c3Ind>true</Organization501c3Ind>",
    "<TaxPeriodBeginDt>2022-01-01</TaxPeriodBeginDt>",
    "</IRS990></ReturnData>"))
  row <- list(filing_receipt_id = "9", ein = "001234567", tax_year = 2022L,
              form_type = "990", local_path = xml)

  res <- extract_filing_relational(row, plan)
  expect_setequal(names(res), c("returnheader", "f990_header"))  # no PF body
  b <- res$f990_header
  expect_equal(b$GovernmentGrantsAmt, "75000")          # raw string pre-assembly
  expect_true(is.na(b$NewInThisVersionAmt))             # version-absent -> NA
  expect_equal(res$returnheader$Filer_EIN, "001234567") # leading zero intact
  expect_true(is.na(b[["_extract_error"]]))
})

test_that("assembly unions columns across forms/versions and types each column", {
  plan <- build_relational_plan(fixture_inventory())
  dir <- tempfile("rel_"); dir.create(dir)
  x990 <- write_filing(dir, "a.xml", paste0(
    "<ReturnHeader><Filer><EIN>001234567</EIN></Filer></ReturnHeader>",
    "<ReturnData><IRS990><GovernmentGrantsAmt>75000</GovernmentGrantsAmt>",
    "<Organization501c3Ind>true</Organization501c3Ind></IRS990></ReturnData>"))
  xpf <- write_filing(dir, "b.xml", paste0(
    "<ReturnHeader><Filer><EIN>987654321</EIN></Filer></ReturnHeader>",
    "<ReturnData><IRS990PF><SumOfProgramRelatedInvstGrp><TotalAmt>0</TotalAmt>",
    "</SumOfProgramRelatedInvstGrp></IRS990PF></ReturnData>"))
  idx <- data.frame(
    filing_receipt_id = c("a", "b"), ein = c("001234567", "987654321"),
    tax_year = c(2022L, 2022L), form_type = c("990", "990PF"),
    local_path = c(x990, xpf), stringsAsFactors = FALSE)

  future::plan(future::sequential)  # deterministic, no worker spawn
  tabs <- extract_filings_relational(idx, plan)

  # returnheader has a row from BOTH filings
  expect_equal(nrow(tabs$returnheader), 2)
  expect_setequal(tabs$returnheader$Filer_EIN, c("001234567", "987654321"))
  # f990 body: one row; amount typed to double
  expect_equal(nrow(tabs$f990_header), 1)
  expect_type(tabs$f990_header$GovernmentGrantsAmt, "double")
  expect_equal(tabs$f990_header$GovernmentGrantsAmt, 75000)
  expect_type(tabs$f990_header$Organization501c3Ind, "logical")
  expect_true(tabs$f990_header$Organization501c3Ind)
  # f990pf body: one row, PRI total typed double (0)
  expect_equal(nrow(tabs$f990pf_header), 1)
  expect_equal(tabs$f990pf_header$SumOfProgramRelatedInvstGrp_TotalAmt, 0)
})

test_that("column type falls back to raw string on a coercion loss", {
  expect_equal(coerce_relational_column(c("1", "2", "3"), "double"), c(1, 2, 3))
  # one un-coercible value demotes the whole column to raw string (fidelity)
  expect_equal(coerce_relational_column(c("1", "oops", "3"), "double"),
               c("1", "oops", "3"))
  # absent (NA) values never trigger the fallback
  expect_equal(coerce_relational_column(c("1", NA, "3"), "double"), c(1, NA, 3))
})
