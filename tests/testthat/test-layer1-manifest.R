# Exercises the Layer 1 provenance manifest without needing cached XSDs:
# hand-build a tiny two-cell inventory (one aliased) and assert the
# manifest records per-cell coverage, the alias flag, and totals.
test_that("write_layer1_manifest records per-cell coverage and aliasing", {
  inv <- data.frame(
    tax_year = c("2024", "2024", "2024"),
    version = c("5.0", "5.1", "5.1"),
    xpath = c("/Return/ReturnData/IRS990/A",
              "/Return/ReturnData/IRS990/A",
              "/Return/ReturnData/IRS990/B"),
    parent_path = "/Return/ReturnData/IRS990",
    element = c("A", "A", "B"),
    xsd_type = "USAmountType",
    is_leaf = TRUE, truncated = FALSE,
    min_occurs = "0", max_occurs = "1", annotation = NA_character_,
    xsd_version_used = c("5.0", "5.0", "5.0"),  # 5.1 inherits 5.0
    stringsAsFactors = FALSE
  )
  out_dir <- tempfile(); dir.create(out_dir)
  on.exit(unlink(out_dir, recursive = TRUE), add = TRUE)
  pq <- file.path(out_dir, "layer1_xsd_inventory.parquet")
  arrow::write_parquet(inv, pq)

  path <- write_layer1_manifest(inv, pq, "2026-06-09", load_config(),
                                default_inventory_roots(), out_dir)
  m <- jsonlite::read_json(path)

  expect_equal(m$artifact, "layer1_xsd_inventory")
  expect_equal(m$total_rows, 3)
  expect_equal(m$file$row_count, 3)
  expect_true(nzchar(m$file$sha256))
  cells <- m$cells
  expect_equal(length(cells), 2)            # (2024,5.0) and (2024,5.1)
  aliased <- Filter(function(c) isTRUE(c$aliased), cells)
  expect_equal(length(aliased), 1)          # only 5.1 is aliased
  expect_equal(aliased[[1]]$version, "5.1")
  expect_equal(aliased[[1]]$xsd_version_used, "5.0")
})
