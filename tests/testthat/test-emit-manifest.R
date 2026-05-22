test_that("emit_manifest writes manifest with sha256 per file and required keys", {
  out_dir <- tempfile()
  dir.create(out_dir)
  on.exit(unlink(out_dir, recursive = TRUE), add = TRUE)

  # write a couple of dummy files in lieu of real parquets
  p1 <- file.path(out_dir, "government_grants.parquet")
  p2 <- file.path(out_dir, "program_related_investments.parquet")
  writeBin(charToRaw("hello"), p1)
  writeBin(charToRaw("world"), p2)

  path <- emit_manifest(
    vintage = "v2026.06",
    phase = "phase0",
    scope = list(forms = c("990", "990PF"), tax_years = c(2023, 2024)),
    parquet_paths = c(p1, p2),
    inputs = list(
      nodc_concordance_sha = "deadbeef",
      nodc_concordance_s3_path = "s3://nccsdata/.../deadbeef_2026-06-15.csv",
      gt_lake_snapshot_timestamp_utc = "2026-06-15T00:00:00Z",
      irs_xsd_cache_prefix = "s3://nccsdata/processed/efile/schemas/"
    ),
    xsd_verification = list(passed = TRUE, checks_run = 20L, mismatches = list()),
    value_distribution = list(per_field = list(
      government_grants = list(null_rate = 0.4)
    )),
    producer_git_sha = "abc123",
    out_dir = out_dir
  )

  expect_true(file.exists(path))
  m <- jsonlite::read_json(path)
  expect_equal(m$schema_version, 1)
  expect_equal(m$producer, "nccs-data-efile")
  expect_equal(m$vintage, "v2026.06")
  expect_equal(m$phase, "phase0")
  expect_equal(m$producer_git_sha, "abc123")
  expect_equal(length(m$files), 2)
  expect_true(nzchar(m$files[[1]]$sha256))
  expect_equal(m$files[[1]]$bytes, 5)
  expect_equal(m$xsd_verification$checks_run, 20)
  expect_equal(m$xsd_verification$passed, TRUE)
})
