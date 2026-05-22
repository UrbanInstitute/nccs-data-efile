#' Emit a per-output dictionary CSV
#'
#' Writes `{name}_dictionary.csv` describing the columns of an output
#' parquet file. See ADR 0001 section 10.
#'
#' Columns produced:
#'   - `column_name`
#'   - `data_type`
#'   - `description`
#'   - `unit`
#'   - `source_xpath`
#'   - `source_nodc_variable_name`
#'   - `nodc_concordance_sha`
#'   - `irs_instruction_citation`
#'
#' @param output_name Base name for the emitted file (the
#'   `government_grants` part of `government_grants_dictionary.csv`).
#' @param column_names Character vector of columns in the emitted
#'   parquet. Entries not present in `dict` get a row of `NA`s -
#'   useful for key columns like `ein` that are not in the layer-2
#'   dictionary.
#' @param dict A layer-2 dictionary data.frame (see
#'   `load_dictionary()`).
#' @param tax_year,version Resolves the per-(year, version) XPath for
#'   `source_xpath`.
#' @param nodc_concordance_sha Pinned NODC SHA at build time.
#' @param out_dir Directory to write the CSV into.
#'
#' @return Invisibly, the path to the written file.
#' @export
emit_dictionary <- function(output_name,
                            column_names,
                            dict,
                            tax_year,
                            version,
                            nodc_concordance_sha,
                            out_dir) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  rows <- lapply(column_names, function(col) {
    dict_row <- dict[dict$nccs_name == col, , drop = FALSE]
    if (nrow(dict_row) == 0) {
      data.frame(
        column_name = col,
        data_type = NA_character_,
        description = NA_character_,
        unit = NA_character_,
        source_xpath = NA_character_,
        source_nodc_variable_name = NA_character_,
        nodc_concordance_sha = nodc_concordance_sha,
        irs_instruction_citation = NA_character_,
        stringsAsFactors = FALSE
      )
    } else {
      data.frame(
        column_name = col,
        data_type = dict_row$data_type[[1]] %||% NA_character_,
        description = dict_row$description[[1]] %||% NA_character_,
        unit = dict_row$unit[[1]] %||% NA_character_,
        source_xpath = parse_xpath_claim(
          dict_row$xpath_claims[[1]], tax_year, version
        ),
        source_nodc_variable_name = dict_row$nodc_variable_name[[1]] %||% NA_character_,
        nodc_concordance_sha = nodc_concordance_sha,
        irs_instruction_citation = dict_row$irs_instruction_citation[[1]] %||% NA_character_,
        stringsAsFactors = FALSE
      )
    }
  })
  out <- do.call(rbind, rows)
  path <- file.path(out_dir, sprintf("%s_dictionary.csv", output_name))
  utils::write.csv(out, path, row.names = FALSE, na = "")
  cli::cli_alert_success("wrote {path}")
  invisible(path)
}
