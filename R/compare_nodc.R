#' Compare the NCCS Layer 2 dictionary against the NODC concordance
#'
#' The Phase 0.5 end-state (ADR 0017 section 3) demotes NODC from a
#' vendored build input to a *comparison artifact*: at each NCCS
#' release an automated, informational diff reports where the curated
#' Layer 2 dictionary agrees with, diverges from, or is uncovered by
#' NODC's `concordance.csv`. It never blocks a build - it is a review
#' signal and a prioritization signal for growing Layer 2.
#'
#' For each NCCS field carrying a `nodc_variable_name`, the comparison
#' checks the link both ways:
#'   - `xpath_agrees`        every XPath the NCCS field claims is among
#'                           NODC's known variants for that variable.
#'   - `xpath_diverges`      the NCCS field claims an XPath NODC does
#'                           not list (NCCS diverged, or NODC is stale).
#'   - `nodc_variable_absent`the referenced NODC variable is gone (a
#'                           broken NCCS->NODC link).
#'   - `no_nodc_link`        the NCCS field declares no NODC variable.
#'
#' @param dict Layer 2 dictionary (from `load_dictionary()`).
#' @param nodc NODC concordance data.frame (from
#'   `load_nodc_concordance()`).
#' @param config Loaded config list.
#' @return Invisibly, a list with `summary` (named counts + coverage)
#'   and `results` (per-field data.frame).
#' @export
compare_dictionary_to_nodc <- function(dict, nodc, config = load_config()) {
  # NODC keys vary by source: the PC concordance uses `variable_name`
  # (e.g. F9_08_REV_CONTR_GOVT_GRANT); the PF foundation files carry a
  # second `variable_name_new` column (e.g. PF_09_PROG_RLTD_INVEST_AMT_TOT).
  # The NCCS dictionary references whichever scheme it was curated from,
  # so match against both.
  if (!"variable_name_new" %in% names(nodc)) nodc$variable_name_new <- NA_character_
  dtype_col <- intersect(c("data_type_simple", "data_type_xsd"), names(nodc))
  dtype_col <- if (length(dtype_col) > 0) dtype_col[[1]] else NA_character_
  claims <- expand_xpath_claims(dict)

  results <- do.call(rbind, lapply(seq_len(nrow(dict)), function(i) {
    field <- dict$nccs_name[i]
    nodc_var <- dict$nodc_variable_name[i]
    nccs_xpaths <- unique(claims$xpath[claims$field == field])
    base <- data.frame(
      field = field, nodc_variable_name = nodc_var %||% NA_character_,
      status = NA_character_,
      nccs_xpaths = paste(nccs_xpaths, collapse = " | "),
      nodc_xpaths = NA_character_,
      nccs_data_type = dict$data_type[i] %||% NA_character_,
      nodc_data_type = NA_character_,
      stringsAsFactors = FALSE
    )
    if (is.null(nodc_var) || is.na(nodc_var) || !nzchar(nodc_var)) {
      base$status <- "no_nodc_link"
      return(base)
    }
    rows <- nodc[(!is.na(nodc$variable_name) & nodc$variable_name == nodc_var) |
                 (!is.na(nodc$variable_name_new) & nodc$variable_name_new == nodc_var),
                 , drop = FALSE]
    if (nrow(rows) == 0) {
      base$status <- "nodc_variable_absent"
      return(base)
    }
    if (!is.na(dtype_col)) base$nodc_data_type <- paste(unique(rows[[dtype_col]]), collapse = " | ")
    if ("xpath" %in% names(rows)) {
      nodc_xpaths <- unique(rows$xpath)
      base$nodc_xpaths <- paste(nodc_xpaths, collapse = " | ")
      base$status <- if (all(nccs_xpaths %in% nodc_xpaths)) "xpath_agrees" else "xpath_diverges"
    } else {
      base$status <- "linked_no_xpath_col"
    }
    base
  }))

  # Count distinct *logical* variables: NODC carries both an old
  # `variable_name` and a new `variable_name_new` for PF rows, so a
  # naive union double-counts each PF variable. Coalesce to the new
  # name when present.
  logical_var <- ifelse(!is.na(nodc$variable_name_new) & nzchar(nodc$variable_name_new),
                        nodc$variable_name_new, nodc$variable_name)
  nodc_total <- length(unique(stats::na.omit(logical_var)))
  linked <- results$status %in% c("xpath_agrees", "xpath_diverges", "linked_no_xpath_col")
  summary <- list(
    n_fields = nrow(results),
    n_linked = sum(linked),
    n_agrees = sum(results$status == "xpath_agrees"),
    n_diverges = sum(results$status == "xpath_diverges"),
    n_absent = sum(results$status == "nodc_variable_absent"),
    n_no_link = sum(results$status == "no_nodc_link"),
    nodc_total_variables = nodc_total,
    nccs_coverage = if (nodc_total > 0) sum(linked) / nodc_total else NA_real_
  )

  if (summary$n_diverges > 0 || summary$n_absent > 0) {
    cli::cli_alert_warning(
      "NODC comparison: {summary$n_diverges} diverging, {summary$n_absent} broken link(s) - review")
  }
  cli::cli_alert_info(sprintf(
    "NODC comparison: %d/%d NCCS fields agree with NODC; Layer 2 covers %d of %d NODC variables (%.2f%%)",
    summary$n_agrees, summary$n_fields, summary$n_linked, nodc_total,
    100 * (summary$nccs_coverage %||% 0)))

  invisible(list(summary = summary, results = results))
}

#' Load the full NODC concordance at a pinned SHA (PC + PF)
#'
#' NODC splits its concordance by form family: the root `concordance.csv`
#' covers Form 990 (PC), while Form 990-PF lives in per-part files under
#' `02-concordance-foundations/`. Loading only the root (what
#' `read_nodc_at` does) makes every PF field look absent. This assembles
#' both into one frame normalized to the columns the comparison needs.
#'
#' @param config Loaded config list.
#' @param sha NODC commit SHA. Defaults to the pinned
#'   `config$vendored$nodc_concordance_sha`.
#' @param include_pf Include the 990-PF foundation files. TRUE by default.
#' @return A data.frame with `xpath`, `variable_name`,
#'   `variable_name_new`, `data_type_simple`, `form_type`, `description`,
#'   `source_file`.
#' @export
load_nodc_concordance <- function(config = load_config(), sha = NULL,
                                  include_pf = TRUE) {
  sha <- sha %||% config$vendored$nodc_concordance_sha
  if (is.null(sha) || !nzchar(sha)) {
    stop("NODC concordance SHA is not pinned (config$vendored$nodc_concordance_sha)")
  }
  parts <- list(normalize_nodc(read_nodc_at(sha), "concordance.csv"))
  if (include_pf) {
    for (p in nodc_foundation_paths(sha)) {
      df <- tryCatch(read_nodc_csv(sha, p), error = function(e) {
        cli::cli_alert_warning("skip NODC file {p}: {conditionMessage(e)}")
        NULL
      })
      if (!is.null(df)) parts[[length(parts) + 1]] <- normalize_nodc(df, p)
    }
  }
  do.call(rbind, parts)
}

#' Columns the comparison needs; sources are normalized to these.
#' @noRd
NODC_COMPARE_COLS <- c("xpath", "variable_name", "variable_name_new",
                       "data_type_simple", "form_type", "description")

#' Select/create the comparison columns from one NODC source frame.
#' @noRd
normalize_nodc <- function(df, source_file) {
  for (cn in NODC_COMPARE_COLS) if (!cn %in% names(df)) df[[cn]] <- NA_character_
  df <- df[, NODC_COMPARE_COLS, drop = FALSE]
  df$source_file <- source_file
  df
}

#' Raw-content URL for a path in the NODC repo at a SHA.
#' @noRd
nodc_raw_path_url <- function(sha, path) {
  sprintf("https://raw.githubusercontent.com/%s/%s/%s",
          "Nonprofit-Open-Data-Collective/irs-efile-master-concordance-file",
          sha, path)
}

#' Download + read one NODC CSV at a path.
#' @noRd
read_nodc_csv <- function(sha, path) {
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)
  utils::download.file(nodc_raw_path_url(sha, path), tmp, mode = "wb", quiet = TRUE)
  utils::read.csv(tmp, stringsAsFactors = FALSE, check.names = FALSE)
}

#' Paths of the 990-PF foundation concordance CSVs at a SHA (excludes
#' the dead/unclear-xpath files - those are retired mappings).
#' @noRd
nodc_foundation_paths <- function(sha) {
  # Keep the jq trivial (no pipes/parens to confuse the shell); filter
  # in R.
  out <- system2(
    "gh",
    c("api",
      sprintf("repos/%s/git/trees/%s?recursive=1",
              "Nonprofit-Open-Data-Collective/irs-efile-master-concordance-file", sha),
      "--jq", ".tree[].path"),
    stdout = TRUE, stderr = FALSE
  )
  out <- out[nzchar(out)]
  out <- out[grepl("^02-concordance-foundations/.*\\.csv$", out)]
  out[!grepl("dead|unclear", out, ignore.case = TRUE)]
}
