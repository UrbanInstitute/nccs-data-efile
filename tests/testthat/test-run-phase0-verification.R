# run_phase0_verification() builds the inventory (needs the XSD cache), so the
# end-to-end path isn't exercised in CI. These cover the pure mapping from a
# gate result to the manifest's xsd_verification block, and the alias derivation.

mk_gate <- function(status) {
  list(
    passed = all(status == "ok"),
    results = data.frame(
      field = paste0("f", seq_along(status)),
      tax_year = "2024", version = "5.0",
      xpath = paste0("/x/", seq_along(status)),
      status = status,
      xsd_type = "USAmountType",
      type_plausible = TRUE,
      stringsAsFactors = FALSE
    )
  )
}
empty_dict <- function() {
  data.frame(nccs_name = character(0), data_type = character(0),
             xpath_claims = character(0), stringsAsFactors = FALSE)
}

test_that("xsd_verification_block preserves the manifest shape", {
  blk <- nccs.data.efile:::xsd_verification_block(
    mk_gate(c("ok", "ok")), empty_dict(), load_config())
  expect_true(blk$passed)
  expect_equal(blk$checks_run, 2)
  expect_length(blk$mismatches, 0)
  expect_true(all(c("passed", "checks_run", "mismatches", "aliases") %in% names(blk)))
})

test_that("xsd_verification_block lists only non-ok claims as mismatches", {
  blk <- nccs.data.efile:::xsd_verification_block(
    mk_gate(c("ok", "missing_xpath")), empty_dict(), load_config())
  expect_false(blk$passed)
  expect_length(blk$mismatches, 1)
  expect_equal(blk$mismatches[[1]]$status, "missing_xpath")
  expect_false(blk$mismatches[[1]]$found)
})

test_that("inscope_aliases derives version inheritances for dictionary cells", {
  # A claim on 2024v5.1 (aliased to 5.0 in config) should surface; a 2024v5.0
  # claim should not.
  dict <- data.frame(
    nccs_name = "f", data_type = "double",
    xpath_claims = "2024:5.0:/x; 2024:5.1:/x",
    stringsAsFactors = FALSE)
  aliases <- nccs.data.efile:::inscope_aliases(dict, load_config())
  vers <- vapply(aliases, function(a) a$version, character(1))
  expect_true("5.1" %in% vers)
  expect_false("5.0" %in% vers)
})
