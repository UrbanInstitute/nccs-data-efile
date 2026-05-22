test_that("config.yml is shipped and parseable", {
  path <- system.file("config.yml", package = "nccs.data.efile")
  expect_true(nzchar(path))

  cfg <- yaml::read_yaml(path)
  expect_true("default" %in% names(cfg))
  expect_true("scope" %in% names(cfg$default))
  expect_true("verification" %in% names(cfg$default))
})
