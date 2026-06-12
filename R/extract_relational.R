#' Wholesale relational (scalar) extraction — ADR 0004 step 2.
#'
#' Where `extract_filing()` pulls only the curated dictionary's claims, the
#' relational path pulls **every non-repeating scalar leaf** for a filing's
#' form, driven by the Layer 1 inventory's `is_leaf & !repeating` set (the
#' `repeating` flag added in ADR 0004 step 1). One parse of the DOM feeds every
#' leaf, so the marginal cost over the dictionary path is small — the parse
#' dominates (see the parse-cost note in `extract_filing`).
#'
#' The output is the raw, XSD-faithful researcher tier: per-form *header* tables
#' (`f990_header`, `f990pf_header`) plus the shared `returnheader`, one row per
#' filing, columns named by the element's path **relative to the form root**
#' (NOT snake_case — that is the curated views' job). Best-effort / uncontracted
#' (ADR 0004 section 4 / nccs-contracts 0028).
#'
#' This file is the in-memory machinery (extract + assemble + type). Publishing
#' to `relational/{table}/{vintage}/` with a manifest + dictionary is ADR 0004
#' step 3.
#' @name extract_relational
NULL

#' NA-safe vectorized TRUE test (inventory flags are logical, but be safe across
#' a parquet round-trip).
#' @noRd
isTRUE_vec <- function(x) !is.na(x) & as.logical(x)

#' The relational tables and the form roots / form_types they cover.
#' `returnheader` is shared (present in every filing, joined by key); each form
#' body is its own table. Widening to schedules is adding entries here once the
#' inventory roots cover them (ADR 0004 section 6).
#' @noRd
default_relational_tables <- function() {
  list(
    list(table = "returnheader",  root = "/Return/ReturnHeader",
         forms = c("990", "990PF")),
    list(table = "f990_header",   root = "/Return/ReturnData/IRS990",
         forms = "990"),
    list(table = "f990pf_header", root = "/Return/ReturnData/IRS990PF",
         forms = "990PF")
  )
}

#' Map an XSD type name to a relational column target type. Complete over the
#' types observed among scalar leaves in the Layer 1 inventory; unknown -> string
#' (the raw tier favors fidelity, and string never loses leading zeros — EIN,
#' ZIP, state/country codes must stay string).
#' @noRd
relational_target_type <- function(xsd_type) {
  if (is.null(xsd_type) || is.na(xsd_type)) return("string")
  if (grepl("Amount|Decimal|Ratio|Percent", xsd_type)) return("double")
  if (grepl("Count|Cnt|Qty|Integer|Year", xsd_type)) return("int")
  if (identical(xsd_type, "BooleanType")) return("bool")
  if (identical(xsd_type, "DateType")) return("date")
  "string"
}

#' Column name = element path relative to the form root, '/' -> '_'.
#'   /Return/ReturnData/IRS990/GovernmentGrantsAmt          -> GovernmentGrantsAmt
#'   /Return/ReturnHeader/Filer/EIN                         -> Filer_EIN
#' Deterministic and collision-free (distinct paths -> distinct names).
#' @noRd
relational_column_name <- function(xpath, root) {
  prefix <- paste0(root, "/")
  rel <- ifelse(startsWith(xpath, prefix), substring(xpath, nchar(prefix) + 1L), NA)
  gsub("/", "_", rel)
}

#' Build the relational extraction plan from a Layer 1 inventory.
#'
#' For each table, the column set is the union of that form's non-repeating
#' scalar leaves over every (tax_year, version) cell in the inventory — a filing
#' populates the columns its version defines, the rest stay null (ADR 0004
#' section 3).
#'
#' @param inventory A Layer 1 inventory data.frame (must carry `xpath`,
#'   `xsd_type`, `is_leaf`, `repeating`, and ideally `annotation`).
#' @param tables Table/root spec; defaults to 990 + 990PF + returnheader.
#' @return A named list (by table) of `list(table, root, forms, leaves)` where
#'   `leaves` is a data.frame of `xpath, col_name, xsd_type, target_type,
#'   annotation` — the per-table dictionary, deduplicated on `xpath`.
#' @export
build_relational_plan <- function(inventory, tables = default_relational_tables()) {
  req <- c("xpath", "xsd_type", "is_leaf", "repeating")
  miss <- setdiff(req, names(inventory))
  if (length(miss)) stop("inventory missing columns: ", paste(miss, collapse = ", "))
  scal <- inventory[isTRUE_vec(inventory$is_leaf) & !isTRUE_vec(inventory$repeating), ,
                    drop = FALSE]

  plan <- list()
  for (t in tables) {
    under <- startsWith(scal$xpath, paste0(t$root, "/"))
    rows <- scal[under, , drop = FALSE]
    rows <- rows[!duplicated(rows$xpath), , drop = FALSE]
    rows <- rows[order(rows$xpath), , drop = FALSE]
    if (nrow(rows) == 0) {
      cli::cli_alert_warning("relational plan: no scalar leaves under {t$root} ({t$table})")
    }
    leaves <- data.frame(
      xpath = rows$xpath,
      col_name = relational_column_name(rows$xpath, t$root),
      xsd_type = rows$xsd_type,
      target_type = vapply(rows$xsd_type, relational_target_type, character(1)),
      annotation = if ("annotation" %in% names(rows)) rows$annotation else NA_character_,
      stringsAsFactors = FALSE
    )
    dup <- leaves$col_name[duplicated(leaves$col_name)]
    if (length(dup)) {
      stop(sprintf("column-name collision in %s: %s (distinct xpaths -> same name)",
                   t$table, paste(unique(dup), collapse = ", ")))
    }
    plan[[t$table]] <- list(table = t$table, root = t$root, forms = t$forms,
                            leaves = leaves)
  }
  plan
}

#' Extract one filing into its relational table rows.
#'
#' Parses the DOM **once** and, for each table the filing's `form_type` maps to
#' (always `returnheader`, plus the matching form body), pulls every scalar leaf
#' in the plan as raw text (typing is deferred to assembly). Mirrors
#' `extract_filing`'s robustness: fetch/parse/oversize failures yield a keyed
#' skeleton row with `_extract_error` set, never an abort.
#'
#' @param row A single index row (list/1-row df) with `filing_receipt_id`, `ein`,
#'   `tax_year`, `form_type`, and `s3_key` or `local_path`.
#' @param plan A plan from `build_relational_plan()`.
#' @param max_bytes Unzipped-XML size cap; see `extract_filing`.
#' @return A named list (by table) of one-row data.frames (keys + raw-string
#'   value columns + `_extract_error`), for the tables this filing populates.
#' @export
extract_filing_relational <- function(row, plan, max_bytes = 50e6) {
  row <- as.list(row)
  form <- as.character(row$form_type %||% NA)
  tabs <- Filter(function(t) form %in% t$forms, plan)
  if (length(tabs) == 0) return(list())

  keys <- function() data.frame(
    filing_receipt_id = as.character(row$filing_receipt_id %||% NA),
    ein               = as.character(row$ein %||% NA),
    tax_year          = as.integer(row$tax_year %||% NA),
    form_type         = as.character(row$form_type %||% NA),
    stringsAsFactors  = FALSE
  )
  skeleton <- function(leaves, err) {
    df <- keys()
    for (cn in leaves$col_name) df[[cn]] <- NA_character_
    df[["_extract_error"]] <- err
    df
  }
  err_out <- function(err) stats::setNames(
    lapply(tabs, function(t) skeleton(t$leaves, err)), vapply(tabs, `[[`, "", "table"))

  xml_path <- tryCatch(obtain_xml(row),
                       error = function(e) structure(NA, error = conditionMessage(e)))
  if (length(xml_path) == 1 && is.na(xml_path)) {
    return(err_out(attr(xml_path, "error", exact = TRUE) %||% "obtain_xml failed"))
  }
  on.exit(if (isTRUE(attr(xml_path, "tempfile"))) unlink(xml_path), add = TRUE)
  fsize <- file.size(xml_path)
  if (!is.na(fsize) && max_bytes > 0 && fsize > max_bytes) {
    return(err_out(sprintf("file too large: %.0f MB (> %.0f MB cap), skipped",
                           fsize / 1e6, max_bytes / 1e6)))
  }
  doc <- tryCatch(xml2::read_xml(xml_path), error = function(e) e)
  if (inherits(doc, "error")) return(err_out(conditionMessage(doc)))

  out <- list()
  for (t in tabs) {
    df <- keys()
    for (i in seq_len(nrow(t$leaves))) {
      v <- tryCatch(eval_xpath_value(doc, t$leaves$xpath[[i]], type = "string"),
                    error = function(e) NA)
      df[[t$leaves$col_name[[i]]]] <- if (length(v) && !is.na(v)) as.character(v) else NA_character_
    }
    df[["_extract_error"]] <- NA_character_
    out[[t$table]] <- df
  }
  out
}

#' Coerce a raw-string value column to its target type, falling back to the raw
#' string on ANY coercion loss (a non-empty source value that becomes NA). The
#' fallback is whole-column: the raw tier keeps fidelity over a clean type.
#' @noRd
coerce_relational_column <- function(x, target) {
  x <- as.character(x)
  if (target == "string" || all(is.na(x))) return(x)
  present <- !is.na(x) & nzchar(x)
  out <- switch(
    target,
    double = suppressWarnings(as.numeric(x)),
    int    = suppressWarnings(as.integer(x)),
    bool   = {
      lo <- tolower(x)
      ifelse(lo %in% c("true", "1", "yes"), TRUE,
             ifelse(lo %in% c("false", "0", "no"), FALSE, NA))
    },
    date   = suppressWarnings(as.Date(x, format = "%Y-%m-%d")),
    x
  )
  if (any(present & is.na(out))) return(x)  # coercion lost a real value -> keep raw
  out
}

#' Extract a batch of filings into assembled, typed relational tables.
#'
#' Runs `extract_filing_relational()` in parallel (`furrr`), unions each table's
#' rows (filling version-absent columns with NA), then types every value column
#' per the plan with the raw-string fallback. Returns the header tables in
#' memory; publishing is ADR 0004 step 3.
#'
#' @param index A data.frame of index rows (see `fetch_gt_indices()`).
#' @param plan A plan from `build_relational_plan()`.
#' @param max_bytes Per-filing size cap.
#' @param progress Show a furrr progress bar.
#' @return A named list (by table) of typed data.frames.
#' @export
extract_filings_relational <- function(index, plan, max_bytes = 50e6,
                                       progress = FALSE) {
  rows <- split(index, seq_len(nrow(index)))
  per_filing <- furrr::future_map(
    rows, function(r) extract_filing_relational(r, plan, max_bytes = max_bytes),
    .options = furrr::furrr_options(seed = TRUE), .progress = progress
  )

  out <- list()
  for (tname in names(plan)) {
    parts <- lapply(per_filing, function(pf) pf[[tname]])
    parts <- parts[!vapply(parts, is.null, logical(1))]
    if (length(parts) == 0) {
      out[[tname]] <- NULL
      next
    }
    tbl <- as.data.frame(data.table::rbindlist(parts, use.names = TRUE, fill = TRUE))
    leaves <- plan[[tname]]$leaves
    for (i in seq_len(nrow(leaves))) {
      cn <- leaves$col_name[[i]]
      if (cn %in% names(tbl)) {
        tbl[[cn]] <- coerce_relational_column(tbl[[cn]], leaves$target_type[[i]])
      }
    }
    out[[tname]] <- tbl
  }
  out
}
