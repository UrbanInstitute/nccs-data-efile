# Synthetic NODC frame: PC variable keyed by `variable_name`, PF variable
# keyed by `variable_name_new` (mirroring the real split), each with
# multiple xpath variants.
mk_nodc <- function() {
  data.frame(
    xpath = c("/Return/ReturnData/IRS990/Form990PartVIII/GovernmentGrants",
              "/Return/ReturnData/IRS990/GovernmentGrants",
              "/Return/ReturnData/IRS990/GovernmentGrantsAmt",
              "/Return/ReturnData/IRS990PF/SumOfProgramRelatedInvestments/Total",
              "/Return/ReturnData/IRS990PF/SumOfProgramRelatedInvstGrp/TotalAmt"),
    variable_name = c("F9_GG", "F9_GG", "F9_GG", "F9_PF_OLD", "F9_PF_OLD"),
    variable_name_new = c(NA, NA, NA, "PF_TOT", "PF_TOT"),
    data_type_simple = "numeric",
    stringsAsFactors = FALSE
  )
}
mk_dict <- function(nodc_var, xpath_claims, data_type = "double") {
  data.frame(nccs_name = "f", data_type = data_type,
             nodc_variable_name = nodc_var, xpath_claims = xpath_claims,
             stringsAsFactors = FALSE)
}

test_that("agreement via variable_name (PC scheme)", {
  d <- mk_dict("F9_GG", "2024:5.0:/Return/ReturnData/IRS990/GovernmentGrantsAmt")
  r <- compare_dictionary_to_nodc(d, mk_nodc())
  expect_equal(r$results$status, "xpath_agrees")
})

test_that("agreement via variable_name_new (PF scheme)", {
  d <- mk_dict("PF_TOT", "2024:5.0:/Return/ReturnData/IRS990PF/SumOfProgramRelatedInvstGrp/TotalAmt")
  r <- compare_dictionary_to_nodc(d, mk_nodc())
  expect_equal(r$results$status, "xpath_agrees")  # matched the new-name column
})

test_that("an xpath NODC does not list is a divergence", {
  d <- mk_dict("F9_GG", "2024:5.0:/Return/ReturnData/IRS990/MadeUpAmt")
  r <- compare_dictionary_to_nodc(d, mk_nodc())
  expect_equal(r$results$status, "xpath_diverges")
  expect_equal(r$summary$n_diverges, 1)
})

test_that("a missing NODC variable is a broken link", {
  d <- mk_dict("GHOST", "2024:5.0:/Return/ReturnData/IRS990/GovernmentGrantsAmt")
  r <- compare_dictionary_to_nodc(d, mk_nodc())
  expect_equal(r$results$status, "nodc_variable_absent")
})

test_that("no NODC variable name => no_nodc_link", {
  d <- mk_dict("", "2024:5.0:/Return/ReturnData/IRS990/GovernmentGrantsAmt")
  r <- compare_dictionary_to_nodc(d, mk_nodc())
  expect_equal(r$results$status, "no_nodc_link")
})

test_that("coverage counts distinct vars across both name columns", {
  r <- compare_dictionary_to_nodc(
    mk_dict("F9_GG", "2024:5.0:/Return/ReturnData/IRS990/GovernmentGrantsAmt"),
    mk_nodc())
  expect_equal(r$summary$nodc_total_variables, 2)  # F9_GG + PF_TOT
  expect_equal(r$summary$n_agrees, 1)
})

test_that("normalize_nodc fills missing comparison columns", {
  raw <- data.frame(xpath = "/a", variable_name = "V", stringsAsFactors = FALSE)
  n <- normalize_nodc(raw, "src.csv")
  expect_true(all(c("variable_name_new", "data_type_simple", "form_type",
                    "description", "source_file") %in% names(n)))
  expect_true(is.na(n$variable_name_new))
  expect_equal(n$source_file, "src.csv")
})

test_that("comparison never errors on a clean dictionary", {
  expect_no_error(
    compare_dictionary_to_nodc(
      mk_dict("F9_GG", "2024:5.0:/Return/ReturnData/IRS990/GovernmentGrantsAmt"),
      mk_nodc()))
})
