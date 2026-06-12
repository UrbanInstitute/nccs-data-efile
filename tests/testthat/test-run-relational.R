# run_relational() end-to-end on the objects path: a synthetic plan + two
# synthetic filings on disk -> assembled, partitioned tables with a dictionary,
# best-effort marker, and manifest.

mini_inventory <- function() {
  d <- data.frame(
    xpath = c(
      "/Return/ReturnHeader/Filer/EIN",
      "/Return/ReturnData/IRS990/GovernmentGrantsAmt",
      "/Return/ReturnData/IRS990/TaxPeriodBeginDt",
      "/Return/ReturnData/IRS990PF/SumOfProgramRelatedInvstGrp/TotalAmt"),
    xsd_type = c("EINType", "USAmountType", "DateType", "USAmountType"),
    is_leaf = TRUE, repeating = FALSE, annotation = NA_character_,
    stringsAsFactors = FALSE)
  d
}

mini_config <- function(local_dir) {
  list(
    parallelism = list(plan = "sequential"),
    staging = list(mode = "objects"),
    parquet = list(compression = "zstd"),
    extract = list(max_file_mb = 50),
    output = list(local_dir = local_dir),
    vendored = list(nodc_concordance_s3_prefix = "s3://nccsdata/processed/efile/concordance/"))
}

write_min_filing <- function(dir, name, body) {
  p <- file.path(dir, name)
  writeLines(sprintf('<?xml version="1.0"?>\n<Return xmlns="http://www.irs.gov/efile">%s</Return>', body), p)
  p
}

test_that("run_relational writes partitioned tables + dictionary + marker + manifest", {
  plan <- build_relational_plan(mini_inventory())
  fdir <- tempfile("filings_"); dir.create(fdir)
  x990 <- write_min_filing(fdir, "a.xml", paste0(
    "<ReturnHeader><Filer><EIN>001234567</EIN></Filer></ReturnHeader>",
    "<ReturnData><IRS990><GovernmentGrantsAmt>75000</GovernmentGrantsAmt>",
    "<TaxPeriodBeginDt>2022-01-01</TaxPeriodBeginDt></IRS990></ReturnData>"))
  xpf <- write_min_filing(fdir, "b.xml", paste0(
    "<ReturnHeader><Filer><EIN>987654321</EIN></Filer></ReturnHeader>",
    "<ReturnData><IRS990PF><SumOfProgramRelatedInvstGrp><TotalAmt>0</TotalAmt>",
    "</SumOfProgramRelatedInvstGrp></IRS990PF></ReturnData>"))
  idx <- data.frame(
    filing_receipt_id = c("a", "b"), ein = c("001234567", "987654321"),
    tax_year = c(2022L, 2022L), form_type = c("990", "990PF"),
    object_id = c("a", "b"), local_path = c(x990, xpf), stringsAsFactors = FALSE)

  out_root <- tempfile("relout_"); dir.create(out_root)
  future::plan(future::sequential)
  res <- run_relational(config = mini_config(out_root), vintage = "vTEST",
                        index = idx, plan = plan)

  expect_equal(res$vintage, "vTEST")
  td <- file.path(res$out_dir, "f990_header")
  expect_true(dir.exists(file.path(td, "data")))                 # partitioned dataset
  expect_true(file.exists(file.path(td, "_dictionary.csv")))
  expect_true(file.exists(file.path(td, "_TIER.txt")))
  expect_true(file.exists(file.path(td, "_manifest.json")))
  # partitioned by tax_year (Hive dir)
  expect_true(any(grepl("tax_year=2022", list.dirs(file.path(td, "data")))))

  # the data round-trips with the right typed value (read the partition part
  # file directly — open_dataset()'s collect needs dplyr, a non-dep)
  read_parts <- function(data_dir) {
    f <- list.files(data_dir, pattern = "\\.parquet$", recursive = TRUE, full.names = TRUE)
    as.data.frame(data.table::rbindlist(lapply(f, arrow::read_parquet),
                                        use.names = TRUE, fill = TRUE))
  }
  ds <- read_parts(file.path(td, "data"))
  expect_equal(ds$GovernmentGrantsAmt[ds$filing_receipt_id == "a"], 75000)

  # returnheader has a row from both forms; EIN string preserved
  rh <- read_parts(file.path(res$out_dir, "returnheader", "data"))
  expect_equal(nrow(rh), 2)
  expect_true("001234567" %in% rh$Filer_EIN)

  # manifest marks the tier best-effort / uncontracted
  man <- jsonlite::read_json(file.path(td, "_manifest.json"))
  expect_false(man$contracted)
  expect_true(man$best_effort)
  expect_equal(man$row_count, 1L)
  expect_equal(man$partition, "tax_year")
  expect_true(nzchar(man$producer_git_sha))
})
