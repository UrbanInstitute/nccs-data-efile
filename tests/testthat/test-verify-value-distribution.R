make_extracted <- function(n_per_cell = 50, gov_grants = NULL) {
  set.seed(1)
  base <- expand.grid(
    tax_year = c(2023L, 2024L),
    form_type = c("990", "990PF"),
    KEEP.OUT.ATTRS = FALSE,
    stringsAsFactors = FALSE
  )
  rows <- list()
  for (i in seq_len(nrow(base))) {
    rep <- base[rep(i, n_per_cell), , drop = FALSE]
    rep$government_grants <- if (is.null(gov_grants)) {
      ifelse(runif(n_per_cell) < 0.4, NA, runif(n_per_cell, 0, 1e5))
    } else {
      gov_grants
    }
    rows[[i]] <- rep
  }
  do.call(rbind, rows)
}

test_that("verify_value_distribution passes when distribution is in spec", {
  cfg <- list(
    verification = list(
      sample_size_per_form_year = 100,
      fields = list(
        government_grants = list(
          type = "double", min = 0, max = 1e10,
          null_rate_min = 0.20, null_rate_max = 0.60
        )
      )
    )
  )
  df <- make_extracted(50)
  r <- verify_value_distribution(df, config = cfg, strict = FALSE)
  expect_true(r$passed)
  expect_equal(length(r$breaches), 0)
  expect_true(!is.null(r$per_field$government_grants))
})

test_that("verify_value_distribution flags out-of-range max", {
  cfg <- list(
    verification = list(
      sample_size_per_form_year = 100,
      fields = list(
        government_grants = list(
          type = "double", min = 0, max = 100,
          null_rate_min = 0, null_rate_max = 1
        )
      )
    )
  )
  df <- make_extracted(50, gov_grants = rep(50000, 50))  # exceeds max=100
  r <- verify_value_distribution(df, config = cfg, strict = FALSE)
  expect_false(r$passed)
  expect_true(any(vapply(r$breaches, function(b) b$reason == "max above configured ceiling", logical(1))))
  expect_true(any(vapply(r$breaches, function(b) identical(b$field, "government_grants"), logical(1))))
})

test_that("verify_value_distribution flags null_rate breach", {
  cfg <- list(
    verification = list(
      sample_size_per_form_year = 100,
      fields = list(
        government_grants = list(
          type = "double", min = 0, max = 1e10,
          null_rate_min = 0, null_rate_max = 0.10
        )
      )
    )
  )
  df <- make_extracted(50, gov_grants = rep(NA_real_, 50))  # 100% null
  r <- verify_value_distribution(df, config = cfg, strict = FALSE)
  expect_false(r$passed)
  expect_true(any(vapply(r$breaches, function(b) b$reason == "null_rate above configured ceiling", logical(1))))
})

test_that("verify_value_distribution errors in strict mode on breach", {
  cfg <- list(
    verification = list(
      sample_size_per_form_year = 100,
      fields = list(
        government_grants = list(
          type = "double", min = 0, max = 100,
          null_rate_min = 0, null_rate_max = 1
        )
      )
    )
  )
  df <- make_extracted(50, gov_grants = rep(5000, 50))
  expect_error(
    verify_value_distribution(df, config = cfg, strict = TRUE),
    "strict mode"
  )
})
