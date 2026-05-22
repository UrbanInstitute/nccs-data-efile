test_that("emit_quality writes a JSON with row count, null rates, per-year counts", {
  df <- data.frame(
    ein = c("1","2","3","4"),
    tax_year = c(2023L, 2023L, 2024L, 2024L),
    government_grants = c(100, NA, 200, 300),
    stringsAsFactors = FALSE
  )
  out_dir <- tempfile()
  on.exit(unlink(out_dir, recursive = TRUE), add = TRUE)

  path <- emit_quality("government_grants", df, out_dir = out_dir)
  expect_true(file.exists(path))

  payload <- jsonlite::read_json(path)
  expect_equal(payload$row_count, 4)
  expect_equal(payload$null_rate_per_column$government_grants, 0.25)
  expect_equal(payload$null_rate_per_column$ein, 0)
  expect_equal(payload$per_year_counts$`2023`, 2)
  expect_equal(payload$per_year_counts$`2024`, 2)
  expect_equal(payload$numeric_summary$government_grants$min, 100)
  expect_equal(payload$numeric_summary$government_grants$max, 300)
})

test_that("emit_quality counts extract errors when column present", {
  df <- data.frame(
    tax_year = c(2024L, 2024L, 2024L),
    x = c(1, 2, NA),
    `_extract_error` = c(NA, NA, "boom"),
    stringsAsFactors = FALSE, check.names = FALSE
  )
  out_dir <- tempfile()
  on.exit(unlink(out_dir, recursive = TRUE), add = TRUE)
  path <- emit_quality("x", df, out_dir = out_dir)
  payload <- jsonlite::read_json(path)
  expect_equal(payload$extract_error_count, 1)
})
