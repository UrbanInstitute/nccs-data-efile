mk_inv <- function() {
  data.frame(
    tax_year = c("2022", "2023", "2024", "2024", "2024"),
    version  = c("5-0",  "5-1",  "5.0",  "5.0",  "5.0"),  # IRS folder convention
    xpath = c("/Return/ReturnData/IRS990/A",
              "/Return/ReturnData/IRS990/A",
              "/Return/ReturnData/IRS990/A",
              "/Return/ReturnData/IRS990/B",     # container (non-leaf)
              "/Return/ReturnData/IRS990/Txt"),  # leaf, but text-typed
    xsd_type = c("USAmountType", "USAmountType", "USAmountType",
                 "IRS990Type", "TextType"),
    is_leaf = c(TRUE, TRUE, TRUE, FALSE, TRUE),
    stringsAsFactors = FALSE
  )
}
mk_dict <- function(claims, data_type = "double") {
  data.frame(nccs_name = "f", data_type = data_type,
             xpath_claims = claims, stringsAsFactors = FALSE)
}

test_that("claims resolve across the dotted<->hyphenated version split", {
  d <- mk_dict(paste("2022:5.0:/Return/ReturnData/IRS990/A",
                     "2023:5.1:/Return/ReturnData/IRS990/A",
                     "2024:5.0:/Return/ReturnData/IRS990/A", sep = "; "))
  r <- verify_dictionary_against_inventory(d, mk_inv(), strict = FALSE)
  expect_true(r$passed)
  expect_equal(r$n_ok, 3)            # 5.0 matched 5-0, 5.1 matched 5-1
  expect_equal(r$n_missing, 0)
})

test_that("a claimed XPath absent from the cell is a hard failure", {
  d <- mk_dict("2024:5.0:/Return/ReturnData/IRS990/MISSING")
  r <- verify_dictionary_against_inventory(d, mk_inv(), strict = FALSE)
  expect_false(r$passed)
  expect_equal(r$n_missing, 1)
  expect_error(
    verify_dictionary_against_inventory(d, mk_inv(), strict = TRUE),
    "do not resolve"
  )
})

test_that("a claim pointing at a container element fails (not a leaf)", {
  d <- mk_dict("2024:5.0:/Return/ReturnData/IRS990/B")
  r <- verify_dictionary_against_inventory(d, mk_inv(), strict = FALSE)
  expect_false(r$passed)
  expect_equal(r$n_not_leaf, 1)
})

test_that("a gated-schema cell with no inventory is unverifiable, not broken", {
  d <- mk_dict("2023:6.0:/Return/ReturnData/IRS990/A")  # no (2023, 6.0) cell
  r <- verify_dictionary_against_inventory(d, mk_inv(), strict = TRUE)  # must not error
  expect_true(r$passed)
  expect_equal(r$n_unverifiable, 1)
  expect_equal(r$results$status, "unverifiable_no_cell")
})

test_that("coarse type check flags a numeric claim on a text element", {
  d <- mk_dict("2024:5.0:/Return/ReturnData/IRS990/Txt", data_type = "double")
  r <- verify_dictionary_against_inventory(d, mk_inv(), strict = FALSE)
  expect_true(r$passed)                 # type mismatch is a warning, not fatal
  expect_equal(r$n_type_warn, 1)
  expect_false(r$results$type_plausible[1])
})

test_that("version normalization is symmetric", {
  expect_equal(canon_version("5-0"), "5.0")
  expect_equal(canon_version("5.0"), "5.0")
  expect_equal(canon_version("4-1"), "4.1")
})
