test_that("parse_gt_index_csv normalizes camelCase columns and keeps url/return_version", {
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)
  utils::write.csv(
    data.frame(
      BuildTs       = c("ts1", "ts2"),
      EIN           = c("111", "222"),
      FormType      = c("990", "990PF"),
      ObjectId      = c("obj1", "obj2"),
      ReturnVersion = c("2024v5.0", "2024v5.0"),
      TaxPeriod     = c("202412", "202412"),
      TaxYear       = c("2024", "2024"),
      URL           = c(
        "https://gt990datalake-rawdata.s3.amazonaws.com/EfileData/XmlFiles/obj1_public.xml",
        "https://gt990datalake-rawdata.s3.amazonaws.com/EfileData/XmlFiles/obj2_public.xml"
      ),
      stringsAsFactors = FALSE
    ),
    tmp, row.names = FALSE
  )

  df <- nccs.data.efile:::parse_gt_index_csv(tmp)
  expect_setequal(
    names(df),
    c("filing_receipt_id", "ein", "tax_period", "tax_year",
      "form_type", "return_version", "object_id", "url")
  )
  expect_equal(df$tax_year, c(2024L, 2024L))
  expect_equal(df$return_version, c("2024v5.0", "2024v5.0"))
  expect_equal(df$filing_receipt_id, c("obj1", "obj2"))
})

test_that("parse_gt_index_csv errors when required columns are missing", {
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)
  utils::write.csv(data.frame(FOO = 1), tmp, row.names = FALSE)
  expect_error(nccs.data.efile:::parse_gt_index_csv(tmp), "missing columns")
})

test_that("filter_gt_index applies forms and tax_years scope", {
  df <- data.frame(
    filing_receipt_id = letters[1:4],
    ein = c("1","2","3","4"),
    tax_period = c("202012","202112","202212","202312"),
    tax_year = c(2020L, 2021L, 2022L, 2023L),
    form_type = c("990","990PF","990EZ","990"),
    object_id = c("a","b","c","d"),
    stringsAsFactors = FALSE
  )
  scope <- list(forms = c("990","990PF"), tax_years = c(2021, 2022))
  out <- nccs.data.efile:::filter_gt_index(df, scope)
  expect_equal(out$filing_receipt_id, "b")
})

test_that("filter_gt_index honors index_filter regex", {
  df <- data.frame(
    filing_receipt_id = c("a","b"),
    ein = c("1","2"),
    tax_period = c("202012","202012"),
    tax_year = c(2020L, 2020L),
    form_type = c("990","990"),
    object_id = c("keep_this", "drop_this"),
    stringsAsFactors = FALSE
  )
  scope <- list(index_filter = "^keep")
  out <- nccs.data.efile:::filter_gt_index(df, scope)
  expect_equal(out$object_id, "keep_this")
})

test_that("url_to_s3_uri inverts virtual-hosted https URLs", {
  urls <- c(
    "https://gt990datalake-rawdata.s3.amazonaws.com/EfileData/XmlFiles/obj1_public.xml",
    "https://gt990datalake-rawdata.s3.amazonaws.com/990xmls/obj2_public.xml",
    "ftp://other.example/x"
  )
  out <- nccs.data.efile:::url_to_s3_uri(urls)
  expect_equal(out[[1]],
               "s3://gt990datalake-rawdata/EfileData/XmlFiles/obj1_public.xml")
  expect_equal(out[[2]],
               "s3://gt990datalake-rawdata/990xmls/obj2_public.xml")
  expect_true(is.na(out[[3]]))
})

