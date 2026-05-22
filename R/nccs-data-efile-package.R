#' nccs.data.efile: NCCS IRS Form 990 E-File Producer
#'
#' Producer pipeline for extracting structured data from IRS Form 990
#' series e-file XML filings. Reads from the GT data lake (primary) or
#' IRS direct (fallback), applies the NCCS-owned layer-2 dictionary,
#' verifies XPath claims against pinned IRS XSDs, and publishes
#' versioned parquet outputs to s3://nccsdata/processed/efile/.
#'
#' Design pinned in decisions/0001-producer-design.md.
#'
#' @keywords internal
"_PACKAGE"
