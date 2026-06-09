test_that("tail_diagnostics returns empty list for all-NA / empty input", {
  expect_identical(tail_diagnostics(c(NA, NA)), list())
  expect_identical(tail_diagnostics(numeric(0)), list())
})

test_that("tail_diagnostics reports order statistics over the full vector", {
  x <- c(NA, 1:100)
  d <- tail_diagnostics(x)
  expect_equal(d$min, 1)
  expect_equal(d$max, 100)
  expect_equal(d$p50, stats::quantile(1:100, 0.5, names = FALSE))
  expect_equal(d$n_negative, 0)
  expect_equal(d$n_zero, 0)
})

test_that("tail_diagnostics counts negatives and zeros", {
  d <- tail_diagnostics(c(-5, 0, 0, 10))
  expect_equal(d$n_negative, 1)
  expect_equal(d$n_zero, 2)
})

test_that("tail-mass concentration detects a heavy tail", {
  # One filing carries ~all the dollars -> top 0.1% share near 1.
  x <- c(rep(1, 999), 1e9)
  d <- tail_diagnostics(x)
  expect_gt(d$top_0_1pct_mass_share, 0.99)
  # A flat distribution concentrates mass near the fraction itself.
  flat <- tail_diagnostics(rep(100, 1000))
  expect_lt(flat$top_1pct_mass_share, 0.02)
})

test_that("tail-mass share is NA when total mass is non-positive", {
  d <- tail_diagnostics(c(-10, -20, 0))
  expect_true(is.na(d$top_1pct_mass_share))
})

test_that("configured bounds drive out-of-band counts", {
  d <- tail_diagnostics(c(-5, 1, 2, 1e11), configured_min = 0, configured_max = 1e10)
  expect_equal(d$n_below_configured_min, 1)
  expect_equal(d$n_above_configured_max, 1)
})
