make_990_xml <- function(amt) {
  tmp <- tempfile(fileext = ".xml")
  xml <- sprintf('<?xml version="1.0"?>
<Return xmlns="http://www.irs.gov/efile">
  <ReturnHeader>
    <Filer><EIN>123456789</EIN></Filer>
    <ReturnTypeCd>990</ReturnTypeCd>
  </ReturnHeader>
  <ReturnData>
    <IRS990>
      <GovernmentGrantsAmt>%s</GovernmentGrantsAmt>
    </IRS990>
  </ReturnData>
</Return>', amt)
  writeLines(xml, tmp)
  tmp
}

test_that("run_phase0 produces parquet + dictionary + quality + manifest end-to-end", {
  skip_if_not_installed("arrow")

  out_dir <- tempfile("phase0-")
  on.exit(unlink(out_dir, recursive = TRUE), add = TRUE)

  xmls <- vapply(c(1000, 2000, 3000, NA), function(a) {
    if (is.na(a)) make_990_xml("") else make_990_xml(a)
  }, character(1))
  on.exit(unlink(xmls), add = TRUE)

  index <- data.frame(
    filing_receipt_id = sprintf("r%d", seq_along(xmls)),
    ein = "123456789",
    tax_year = 2024L,
    form_type = "990",
    local_path = xmls,
    s3_key = NA_character_,
    stringsAsFactors = FALSE
  )

  dict <- data.frame(
    nccs_name = "government_grants",
    description = "Total gov grants",
    unit = "USD",
    data_type = "double",
    forms_applicable = "990",
    nodc_variable_name = "F9_GVT_GRT",
    irs_instruction_citation = "Form 990 line 1e",
    xpath_claims = "2024:v1.0:/Return/ReturnData/IRS990/GovernmentGrantsAmt",
    notes = "",
    stringsAsFactors = FALSE
  )

  cfg <- list(
    parallelism = list(plan = "sequential", workers = 1L),
    scope = list(forms = "990", tax_years = 2024L),
    parquet = list(compression = "uncompressed"),
    phase0_outputs = list(
      list(name = "government_grants", fields = "government_grants")
    ),
    verification = list(
      sample_size_per_form_year = 100,
      fields = list(
        government_grants = list(
          type = "double", min = 0, max = 1e10,
          null_rate_min = 0, null_rate_max = 1
        )
      )
    ),
    output = list(phase = "phase0", local_dir = out_dir),
    vendored = list(nodc_concordance_sha = "deadbeef")
  )

  summary <- run_phase0(
    config = cfg, dict = dict, vintage = "v2026.06",
    xsd_version = "v1.0", out_dir = out_dir,
    skip_xsd_verification = TRUE, index = index
  )

  expect_equal(summary$n_filings, 4)
  expect_true(file.exists(file.path(out_dir, "government_grants.parquet")))
  expect_true(file.exists(file.path(out_dir, "government_grants_dictionary.csv")))
  expect_true(file.exists(file.path(out_dir, "government_grants_quality.json")))
  expect_true(file.exists(file.path(out_dir, "_manifest.json")))

  written <- arrow::read_parquet(file.path(out_dir, "government_grants.parquet"))
  expect_equal(nrow(written), 4)
  expect_setequal(
    names(written),
    c("filing_receipt_id", "ein", "tax_year", "form_type", "government_grants")
  )
  expect_equal(sort(written$government_grants[!is.na(written$government_grants)]),
               c(1000, 2000, 3000))
})
