# verify_xpath is now an inventory lookup (Phase 0.5), not an XSD walk.
mk_inv <- function() {
  data.frame(
    tax_year = "2022",
    version  = "5-0",  # IRS folder convention; verify_xpath normalizes
    xpath = c("/Return/ReturnData/IRS990/GovernmentGrantsAmt",
              "/Return/ReturnData/IRS990/OrgName"),
    xsd_type = c("USAmountType", "StringType"),
    is_leaf = c(TRUE, TRUE),
    stringsAsFactors = FALSE
  )
}

test_that("verify_xpath finds a claim and reports its type", {
  r <- verify_xpath("/Return/ReturnData/IRS990/GovernmentGrantsAmt", 2022, "5.0",
                    expected_type = "USAmountType", inventory = mk_inv())
  expect_true(r$found)
  expect_equal(r$actual_type, "USAmountType")
  expect_true(r$is_leaf)
  expect_true(r$matches_expected)
})

test_that("verify_xpath flags a type mismatch", {
  r <- verify_xpath("/Return/ReturnData/IRS990/OrgName", 2022, "5.0",
                    expected_type = "USAmountType", inventory = mk_inv())
  expect_true(r$found)
  expect_equal(r$actual_type, "StringType")
  expect_false(r$matches_expected)
})

test_that("verify_xpath reports not-found for an absent xpath", {
  r <- verify_xpath("/Return/ReturnData/IRS990/Nope", 2022, "5.0",
                    inventory = mk_inv())
  expect_false(r$found)
  expect_true(is.na(r$actual_type))
  expect_true(is.na(r$matches_expected))  # no expected_type supplied
})

test_that("verify_xpath normalizes version (dotted matches hyphenated cell)", {
  dotted <- verify_xpath("/Return/ReturnData/IRS990/GovernmentGrantsAmt",
                         2022, "5.0", inventory = mk_inv())
  hyphen <- verify_xpath("/Return/ReturnData/IRS990/GovernmentGrantsAmt",
                         2022, "5-0", inventory = mk_inv())
  expect_true(dotted$found)
  expect_true(hyphen$found)
})
