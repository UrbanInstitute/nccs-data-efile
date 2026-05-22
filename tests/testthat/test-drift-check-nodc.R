test_that("summarize_nodc_diff counts adds, removes, and changes by key", {
  old_df <- data.frame(
    variable_name = c("a", "b", "c"),
    description   = c("alpha", "beta", "gamma"),
    stringsAsFactors = FALSE
  )
  new_df <- data.frame(
    variable_name = c("a", "b", "d"),         # c removed, d added
    description   = c("alpha", "BETA!", "delta"),  # b changed
    stringsAsFactors = FALSE
  )

  s <- nccs.data.efile:::summarize_nodc_diff(old_df, new_df)

  expect_equal(s$key, "variable_name")
  expect_equal(s$rows_added, 1L)
  expect_equal(s$rows_removed, 1L)
  expect_equal(s$rows_changed, 1L)
  expect_equal(s$added_keys, "d")
  expect_equal(s$removed_keys, "c")
  expect_equal(s$sample$variable_name, "b")
})

test_that("summarize_nodc_diff falls back to first column when variable_name absent", {
  old_df <- data.frame(id = c("x", "y"), v = c(1, 2), stringsAsFactors = FALSE)
  new_df <- data.frame(id = c("x", "z"), v = c(1, 9), stringsAsFactors = FALSE)
  s <- nccs.data.efile:::summarize_nodc_diff(old_df, new_df)
  expect_equal(s$key, "id")
  expect_equal(s$rows_added, 1L)
  expect_equal(s$rows_removed, 1L)
  expect_equal(s$rows_changed, 0L)
})

test_that("drift_check_nodc errors when SHA is not pinned", {
  cfg <- list(vendored = list(nodc_concordance_sha = NULL))
  expect_error(drift_check_nodc(config = cfg), "not pinned")
})
