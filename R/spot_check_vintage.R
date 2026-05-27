#' Held-out spot-check of a published Phase 0 vintage
#'
#' Samples N random filings per form_type from a vintage's parquet
#' files, fetches each source XML, extracts the value via
#' `xmlstarlet` (a different XML toolchain than the package's own
#' `xml2`-based extractor), and compares to the value in the parquet.
#' Satisfies ADR 0002 acceptance criterion 5.
#'
#' Independence is structural: the production extractor goes through
#' `xml2::read_xml` -> `xml_ns_strip` -> `xml_find_first`, while this
#' spot-check goes through a separate `xmlstarlet` process with
#' explicit namespace binding on the IRS efile namespace. A bug in
#' one path is unlikely to mirror in the other.
#'
#' @param vintage_dir Local path to the vintage directory, OR an
#'   `s3://...` URI. Remote vintages are pulled to a temp dir.
#' @param n_per_form How many filings per `form_type` to sample.
#'   ADR 0002 specifies 10.
#' @param index Optional pre-loaded GT index data.frame. When `NULL`,
#'   calls `fetch_gt_indices()` to recover URL + return_version.
#' @param config Loaded config list.
#' @param dict Layer-2 dictionary; used to look up the documented
#'   XPath per `(tax_year, version)`.
#' @param seed Random seed for reproducibility.
#' @param report_path Optional path to write a JSON report.
#'
#' @return A list with `n`, `agree`, `disagree`, `per_form`, and a
#'   data.frame `details` (one row per sampled filing).
#' @export
spot_check_vintage <- function(vintage_dir,
                               n_per_form = 10,
                               index = NULL,
                               config = load_config(),
                               dict = load_dictionary(),
                               seed = 42,
                               report_path = NULL) {
  if (!nzchar(Sys.which("xmlstarlet"))) {
    stop("xmlstarlet not on PATH - install via `apt-get install xmlstarlet`")
  }

  local_dir <- if (startsWith(vintage_dir, "s3://")) {
    tmp <- tempfile("vintage_")
    dir.create(tmp)
    cli::cli_alert_info("syncing {vintage_dir} -> {tmp}")
    args <- c("s3", "sync", vintage_dir, tmp)
    if (!is.null(config$aws$profile))
      args <- c(args, "--profile", config$aws$profile)
    status <- system2("aws", args, stdout = FALSE, stderr = FALSE)
    if (!identical(status, 0L)) {
      stop(sprintf("aws s3 sync %s failed (exit %s)", vintage_dir, status))
    }
    tmp
  } else {
    vintage_dir
  }

  # Load every parquet in the vintage and union the per-output rows
  # into one tall frame keyed by filing_receipt_id + field.
  parquets <- list.files(local_dir, pattern = "\\.parquet$", full.names = TRUE)
  if (length(parquets) == 0) {
    stop(sprintf("no parquets under %s", local_dir))
  }
  tall <- list()
  for (p in parquets) {
    df <- as.data.frame(arrow::read_parquet(p))
    keys <- c("filing_receipt_id", "ein", "tax_year", "form_type")
    field_cols <- setdiff(names(df), keys)
    for (fc in field_cols) {
      tall[[length(tall) + 1]] <- data.frame(
        filing_receipt_id = df$filing_receipt_id,
        form_type         = df$form_type,
        tax_year          = df$tax_year,
        field             = fc,
        parquet_value     = df[[fc]],
        stringsAsFactors  = FALSE
      )
    }
  }
  tall <- do.call(rbind, tall)

  # Recover URL + return_version via the GT index.
  if (is.null(index)) {
    cli::cli_alert_info("fetching GT index for url + return_version lookup")
    index <- fetch_gt_indices(config = config)
  }
  idx_join <- index[, c("filing_receipt_id", "url", "return_version")]
  joined <- merge(tall, idx_join, by = "filing_receipt_id", all.x = TRUE)

  # Sample n_per_form per form_type (across all fields).
  set.seed(seed)
  per_form <- split(joined, joined$form_type)
  picks <- lapply(per_form, function(g) {
    if (nrow(g) <= n_per_form) g else g[sample(nrow(g), n_per_form), ]
  })
  sample_df <- do.call(rbind, picks)
  rownames(sample_df) <- NULL

  # For each sampled row: download the XML, extract via xmlstarlet,
  # compare to the parquet value.
  details <- vector("list", nrow(sample_df))
  for (i in seq_len(nrow(sample_df))) {
    r <- sample_df[i, ]
    cli::cli_alert_info("[{i}/{nrow(sample_df)}] {r$form_type} {r$filing_receipt_id} -> {r$field}")
    pv <- parse_return_version(r$return_version)
    xp <- parse_xpath_claim(
      dict$xpath_claims[dict$nccs_name == r$field][[1]],
      pv$tax_year, pv$version
    )
    xml_val <- tryCatch(
      xmlstarlet_extract(r$url, xp),
      error = function(e) list(value = NA, error = conditionMessage(e))
    )
    parq_v <- r$parquet_value
    xml_v  <- xml_val$value
    agree <- if (is.na(parq_v) && is.na(xml_v)) TRUE
             else if (is.na(parq_v) || is.na(xml_v)) FALSE
             else isTRUE(all.equal(as.numeric(parq_v), as.numeric(xml_v)))

    details[[i]] <- data.frame(
      filing_receipt_id = r$filing_receipt_id,
      form_type         = r$form_type,
      field             = r$field,
      return_version    = r$return_version,
      xpath_used        = xp %||% NA_character_,
      parquet_value     = parq_v,
      xml_value         = xml_v,
      agree             = agree,
      xml_error         = xml_val$error %||% NA_character_,
      stringsAsFactors  = FALSE
    )
  }
  details <- do.call(rbind, details)

  per_form_summary <- stats::aggregate(
    details$agree,
    by = list(form_type = details$form_type, field = details$field),
    FUN = function(x) c(n = length(x), agree = sum(x))
  )
  per_form_summary <- data.frame(
    form_type = per_form_summary$form_type,
    field     = per_form_summary$field,
    n         = as.integer(per_form_summary$x[, "n"]),
    agree     = as.integer(per_form_summary$x[, "agree"]),
    stringsAsFactors = FALSE
  )

  result <- list(
    n = nrow(details),
    agree = sum(details$agree),
    disagree = sum(!details$agree),
    per_form = per_form_summary,
    details = details,
    vintage_dir = vintage_dir,
    generated_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  )

  cli::cli_alert_info("agreement: {result$agree}/{result$n}")
  print(per_form_summary)
  if (result$disagree > 0) {
    cli::cli_alert_warning("disagreements: {result$disagree}")
    print(details[!details$agree, ])
  }

  if (!is.null(report_path)) {
    dir.create(dirname(report_path), recursive = TRUE, showWarnings = FALSE)
    jsonlite::write_json(
      result, report_path,
      pretty = TRUE, auto_unbox = TRUE, na = "null"
    )
    cli::cli_alert_success("wrote {report_path}")
  }
  invisible(result)
}

#' Extract a value from an IRS efile XML via xmlstarlet (shell-out).
#'
#' The IRS efile XML carries a default namespace
#' `xmlns="http://www.irs.gov/efile"`. xmlstarlet requires explicit
#' namespace binding, so each step of the input XPath is prefixed
#' with the bound prefix `e:` before being passed to `xmlstarlet sel`.
#'
#' @noRd
xmlstarlet_extract <- function(url, xpath, ns_prefix = "e",
                               ns_uri = "http://www.irs.gov/efile") {
  if (is.null(xpath) || is.na(xpath) || !nzchar(xpath)) {
    return(list(value = NA, error = "no xpath for this (year, version)"))
  }
  tmp <- tempfile(fileext = ".xml")
  on.exit(unlink(tmp), add = TRUE)
  utils::download.file(url, tmp, mode = "wb", quiet = TRUE)

  prefixed <- prefix_xpath(xpath, ns_prefix)
  out <- suppressWarnings(system2(
    "xmlstarlet",
    c("sel", "-N", sprintf("%s=%s", ns_prefix, ns_uri),
      "-t", "-v", prefixed, tmp),
    stdout = TRUE, stderr = TRUE
  ))
  if (length(out) == 0 || !nzchar(out[[1]])) {
    return(list(value = NA, error = NA_character_))
  }
  v <- suppressWarnings(as.numeric(out[[1]]))
  list(value = v, error = NA_character_)
}

#' Prefix every step of an absolute XPath with a namespace prefix.
#' `/Return/ReturnData/IRS990/X` -> `/e:Return/e:ReturnData/e:IRS990/e:X`
#' @noRd
prefix_xpath <- function(xpath, prefix) {
  steps <- strsplit(sub("^/", "", xpath), "/", fixed = TRUE)[[1]]
  paste0("/", paste(paste0(prefix, ":", steps), collapse = "/"))
}
