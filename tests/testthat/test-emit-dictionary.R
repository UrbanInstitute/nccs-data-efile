test_that("emit_dictionary writes the configured columns with NA fallback", {
  dict <- data.frame(
    nccs_name = "government_grants",
    description = "Total government grants",
    unit = "USD",
    data_type = "double",
    forms_applicable = "990",
    nodc_variable_name = "F9_08_REV_TOT_GVT_GRT",
    irs_instruction_citation = "Form 990 Instr. p27 line 1e",
    xpath_claims = "2024:v1.0:/Return/ReturnData/IRS990/Gov",
    notes = "",
    stringsAsFactors = FALSE
  )
  out_dir <- tempfile()
  on.exit(unlink(out_dir, recursive = TRUE), add = TRUE)

  path <- emit_dictionary(
    output_name = "government_grants",
    column_names = c("ein", "tax_year", "government_grants"),
    dict = dict,
    tax_year = 2024,
    version = "v1.0",
    nodc_concordance_sha = "deadbeef",
    out_dir = out_dir
  )

  expect_true(file.exists(path))
  written <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "")
  expect_setequal(
    names(written),
    c("column_name", "data_type", "description", "unit",
      "source_xpath", "source_nodc_variable_name",
      "nodc_concordance_sha", "irs_instruction_citation")
  )
  expect_equal(written$column_name, c("ein", "tax_year", "government_grants"))
  expect_true(all(is.na(written$source_xpath[1:2])))
  expect_equal(written$source_xpath[3], "/Return/ReturnData/IRS990/Gov")
  expect_equal(written$nodc_concordance_sha, rep("deadbeef", 3))
})
