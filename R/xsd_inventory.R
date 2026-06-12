#' Build the Layer 1 mechanical XSD inventory for one (tax_year, version)
#'
#' Enumerates every element reachable from the configured form roots in
#' an IRS XSD bundle, emitting one row per element with its full XPath,
#' parent path, declared XSD type, cardinality, and any
#' `xsd:documentation`. This is the "Layer 1" of the two-layer
#' concordance (ADR 0017 section 3): mechanical, never hand-edited,
#' regenerated on every IRS release. It is the inverse traversal of
#' `verify_xpath()`: that resolves a *known* path top-down; this
#' enumerates *all* paths by full depth-first descent.
#'
#' Reuses `load_xsd_schema()` (the same flattened element/complexType
#' index the verifier builds). The inventory is keyed by position
#' (XPath), so a shared complexType reused under several parents yields
#' one row per occurrence - that is why the inventory is large
#' (~10K rows per form-version), not a bug.
#'
#' @param tax_year Integer or character tax year.
#' @param version XSD version string. If the configured
#'   `xsd$version_aliases` redirects this (year, version) to another
#'   version's XSDs (e.g. 2024v5.1 -> 5.0), the alias is honored.
#' @param config Loaded config list.
#' @param xsd_dir Optional explicit XSD directory (overrides the
#'   cache-path + alias resolution).
#' @param roots Optional list of `list(name=, xpath=)` form roots to
#'   enumerate from. Defaults to 990 + 990PF + ReturnHeader.
#'
#' @return A data.frame, one row per reachable element, with columns:
#'   `tax_year`, `version`, `xpath`, `parent_path`, `element`,
#'   `xsd_type`, `is_leaf`, `truncated`, `min_occurs`, `max_occurs`,
#'   `repeating`, `annotation`. Deduplicated on `xpath`.
#'
#'   `repeating` is `TRUE` when the element itself or any ancestor on its
#'   path can occur more than once -- `maxOccurs="unbounded"` or a bounded
#'   `maxOccurs` > 1 (e.g. `ForeignCountryCd` at `maxOccurs=100`)
#'   (ADR 0004 section 1). It makes the non-repeating scalar-leaf universe
#'   a one-line filter (`is_leaf & !repeating`) and its complement the
#'   repeating-group universe. "Single-valued per filing" is the test, so a
#'   bounded-multi leaf is repeating, not scalar.
#' @export
build_xsd_inventory <- function(tax_year, version, config = load_config(),
                                xsd_dir = NULL, roots = NULL) {
  if (is.null(roots)) roots <- default_inventory_roots()
  if (is.null(xsd_dir)) xsd_dir <- inventory_xsd_dir(tax_year, version, config)
  if (!dir.exists(xsd_dir)) {
    stop(sprintf("XSD directory not found: %s", xsd_dir))
  }

  schema <- load_xsd_schema(xsd_dir)
  schema$groups <- index_xsd_groups(schema$docs, schema$ns)

  acc <- new.env(parent = emptyenv())
  acc$rows <- list()
  acc$n <- 0L

  for (r in roots) {
    cand <- pick_root_candidate(schema, r$name)
    if (is.null(cand)) {
      cli::cli_alert_warning(
        "inventory root {r$name} not found in {tax_year}v{version}"
      )
      next
    }
    rec <- list(name = r$name, type = cand$type,
                occ_node = cand$node, def_node = cand$node)
    parent_path <- sub("/[^/]+$", "", r$xpath)
    enumerate_element(rec, r$xpath, parent_path, schema,
                      visited = character(0), depth = 0L, acc = acc,
                      repeating = FALSE)
  }

  df <- inventory_rows_to_df(acc$rows, tax_year, version)
  df[!duplicated(df$xpath), , drop = FALSE]
}

#' Build the Layer 1 inventory across all configured (tax_year, version)
#' cells and concatenate into one frame.
#'
#' Loops `config$xsd$versions`, honoring `version_aliases` (a (year,
#' version) whose XSDs are inherited records the actually-used XSD
#' version in `xsd_version_used`). A cell that fails to build (missing
#' XSD cache, parse error) is warned and skipped, not fatal.
#'
#' @param config Loaded config list.
#' @param roots Optional form-root list (defaults to 990+990PF+header).
#' @return A data.frame of all cells' rows with an added
#'   `xsd_version_used` column.
#' @export
build_all_xsd_inventories <- function(config = load_config(), roots = NULL) {
  versions <- config$xsd$versions
  if (is.null(versions) || length(versions) == 0) {
    stop("config$xsd$versions is empty - nothing to inventory")
  }
  parts <- list()
  for (ty in names(versions)) {
    for (ver in versions[[ty]]) {
      inv <- tryCatch(
        build_xsd_inventory(ty, ver, config = config, roots = roots),
        error = function(e) {
          cli::cli_alert_warning("skip {ty}v{ver}: {conditionMessage(e)}")
          NULL
        }
      )
      if (is.null(inv)) next
      alias <- config$xsd$version_aliases[[as.character(ty)]][[as.character(ver)]]
      inv$xsd_version_used <- if (!is.null(alias) && !is.null(alias$xsd_from)) {
        as.character(alias$xsd_from)
      } else {
        as.character(ver)
      }
      parts[[length(parts) + 1]] <- inv
      cli::cli_alert_success("{ty}v{ver}: {nrow(inv)} elements")
    }
  }
  if (length(parts) == 0) stop("no inventory cells built")
  do.call(rbind, parts)
}

#' Build, write, and (optionally) publish the Layer 1 XSD inventory.
#'
#' Produces a single consolidated parquet plus a provenance manifest
#' under `concordance/layer1/{build_date}/` on S3 (with a `latest/`
#' mirror), per ADR 0017 section 3 (Layer 1 is the mechanical layer of
#' the NCCS-owned concordance).
#'
#' @param config Loaded config list.
#' @param out_dir Local directory to write into (default: a vintage dir
#'   under `out/layer1/`).
#' @param build_date `YYYY-MM-DD` string for the S3 vintage dir
#'   (default: today, UTC).
#' @param upload If TRUE, sync the local dir to S3.
#' @param roots Optional form-root list.
#' @return Invisibly, a list with `parquet_path`, `manifest_path`,
#'   `s3_prefix`, `rows`.
#' @export
publish_xsd_inventory <- function(config = load_config(), out_dir = NULL,
                                  build_date = NULL, upload = TRUE,
                                  roots = NULL) {
  build_date <- build_date %||% format(Sys.Date(), "%Y-%m-%d")
  inv <- build_all_xsd_inventories(config = config, roots = roots)

  if (is.null(out_dir)) out_dir <- file.path("out", "layer1", build_date)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  parquet_path <- file.path(out_dir, "layer1_xsd_inventory.parquet")
  arrow::write_parquet(inv, parquet_path,
                       compression = config$parquet$compression %||% "zstd")
  cli::cli_alert_success("wrote {parquet_path} ({nrow(inv)} rows)")

  manifest_path <- write_layer1_manifest(inv, parquet_path, build_date, config,
                                         roots %||% default_inventory_roots(),
                                         out_dir)

  s3_prefix <- layer1_s3_prefix(config, build_date)
  if (upload) {
    sync_layer1_to_s3(out_dir, s3_prefix, config)
    sync_layer1_to_s3(out_dir, layer1_s3_prefix(config, "latest"), config)
  }

  invisible(list(parquet_path = parquet_path, manifest_path = manifest_path,
                 s3_prefix = s3_prefix, rows = nrow(inv)))
}

#' S3 prefix for a Layer 1 vintage dir.
#' @noRd
layer1_s3_prefix <- function(config, build_date) {
  base <- config$vendored$nodc_concordance_s3_prefix %||%
    "s3://nccsdata/processed/efile/concordance/"
  paste0(sub("/?$", "/", base), "layer1/", build_date, "/")
}

#' Write the Layer 1 provenance manifest (per-cell coverage + sha256).
#' @noRd
write_layer1_manifest <- function(inv, parquet_path, build_date, config,
                                  roots, out_dir) {
  cells <- unique(inv[, c("tax_year", "version", "xsd_version_used")])
  per_cell <- lapply(seq_len(nrow(cells)), function(i) {
    rows <- inv$tax_year == cells$tax_year[i] & inv$version == cells$version[i]
    list(
      tax_year = cells$tax_year[i],
      version = cells$version[i],
      xsd_version_used = cells$xsd_version_used[i],
      aliased = !identical(cells$version[i], cells$xsd_version_used[i]),
      row_count = sum(rows)
    )
  })
  payload <- list(
    schema_version = 1L,
    artifact = "layer1_xsd_inventory",
    producer = "nccs-data-efile",
    producer_git_sha = git_head_sha(),
    build_date = build_date,
    build_timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    roots = vapply(roots, function(r) r$xpath, character(1)),
    xsd_source_s3_prefix = config$vendored$irs_xsd_cache_s3_prefix %||% NA_character_,
    total_rows = nrow(inv),
    file = list(
      name = basename(parquet_path),
      sha256 = digest_file_sha256(parquet_path),
      row_count = nrow(inv)
    ),
    cells = per_cell
  )
  path <- file.path(out_dir, "_layer1_manifest.json")
  jsonlite::write_json(payload, paste0(path, ".tmp"), pretty = TRUE,
                       auto_unbox = TRUE, na = "null")
  file.rename(paste0(path, ".tmp"), path)
  cli::cli_alert_success("wrote {path}")
  path
}

#' sha256 of a file (reuses the same approach as the NODC vendoring).
#' @noRd
digest_file_sha256 <- function(path) {
  digest::digest(file = path, algo = "sha256")
}

#' Sync a local Layer 1 dir to an S3 prefix via the AWS CLI.
#' @noRd
sync_layer1_to_s3 <- function(local_dir, s3_prefix, config) {
  profile <- config$aws$profile
  args <- c("s3", "sync", local_dir, s3_prefix)
  if (!is.null(profile)) args <- c(args, "--profile", profile)
  cli::cli_alert_info("aws {paste(args, collapse=' ')}")
  code <- system2("aws", args)
  if (code != 0) stop(sprintf("aws s3 sync failed (code %d) -> %s", code, s3_prefix))
  invisible(s3_prefix)
}

#' Phase 0.5 starting form roots (990 + 990PF + ReturnHeader).
#' @noRd
default_inventory_roots <- function() {
  list(
    list(name = "ReturnHeader", xpath = "/Return/ReturnHeader"),
    list(name = "IRS990",       xpath = "/Return/ReturnData/IRS990"),
    list(name = "IRS990PF",     xpath = "/Return/ReturnData/IRS990PF")
  )
}

#' Hard depth cap - a backstop against pathological recursion the
#' named-type cycle guard might miss. 990 trees are < 20 deep.
#' @noRd
INVENTORY_MAX_DEPTH <- 60L

#' Resolve the XSD directory for (tax_year, version), honoring the
#' config's version_aliases (e.g. 2024v5.1 inherits 2024v5.0 XSDs).
#' @noRd
inventory_xsd_dir <- function(tax_year, version, config) {
  alias <- config$xsd$version_aliases[[as.character(tax_year)]][[as.character(version)]]
  use_version <- if (!is.null(alias) && !is.null(alias$xsd_from)) {
    alias$xsd_from
  } else {
    version
  }
  xsd_cache_path(tax_year, use_version, config)
}

#' Index all named model groups (`<xs:group name=...>`) across the
#' bundle so `<xs:group ref=...>` references resolve during traversal.
#' @noRd
index_xsd_groups <- function(docs, ns) {
  groups <- list()
  for (doc in docs) {
    for (g in xml2::xml_find_all(doc, "//xs:group[@name]", ns)) {
      groups[[xml2::xml_attr(g, "name")]] <- g
    }
  }
  groups
}

#' Pick the best candidate node for a root/ref element name: prefer a
#' top-level (`<xs:schema>`-child) declaration over a local one, since
#' refs and form roots target globally-declared elements.
#' @noRd
pick_root_candidate <- function(schema, name) {
  cands <- schema$elements[[name]]
  if (is.null(cands) || length(cands) == 0) return(NULL)
  top <- Filter(function(c) is_top_level_element(c$node), cands)
  if (length(top) > 0) top[[1]] else cands[[1]]
}

#' Is this element declaration a direct child of `<xs:schema>`?
#' @noRd
is_top_level_element <- function(node) {
  p <- xml2::xml_parent(node)
  !inherits(p, "xml_missing") && xml2::xml_name(p) == "schema"
}

#' Recursive DFS: emit `rec` at `xpath`, then descend into its children.
#' A named complex type already on the current path (cycle) or the depth
#' cap stops descent; the element is still emitted with `truncated=TRUE`.
#' @noRd
enumerate_element <- function(rec, xpath, parent_path, schema,
                              visited, depth, acc, repeating) {
  children <- element_children(rec, schema)

  named_type <- !is.null(rec$type) && !is.na(rec$type) && rec$type != "(anonymous)"
  cycle <- named_type && rec$type %in% visited
  hit_cap <- depth >= INVENTORY_MAX_DEPTH
  truncated <- (cycle || hit_cap) && length(children) > 0
  if (cycle || hit_cap) children <- list()

  # This element repeats if it can occur more than once itself (maxOccurs
  # "unbounded" OR a bounded count > 1, e.g. ForeignCountryCd maxOccurs=100)
  # or sits anywhere under such an ancestor (ADR 0004 section 1). `repeating`
  # carries the ancestor state down the DFS; OR-in this element's own
  # cardinality before emitting and before passing the state to the children.
  self_max <- xml2::xml_attr(rec$occ_node, "maxOccurs")
  self_repeating <- !is.na(self_max) && (
    self_max == "unbounded" ||
      (!is.na(suppressWarnings(as.integer(self_max))) && as.integer(self_max) > 1L)
  )
  row_repeating <- isTRUE(repeating) || self_repeating

  emit_inventory_row(
    acc, xpath, parent_path, rec, schema,
    is_leaf = (length(children) == 0 && !truncated),
    truncated = truncated,
    repeating = row_repeating
  )

  if (length(children) == 0) return(invisible(NULL))
  next_visited <- if (named_type) c(visited, rec$type) else visited
  for (ch in children) {
    enumerate_element(ch, paste0(xpath, "/", ch$name), xpath, schema,
                      next_visited, depth + 1L, acc, repeating = row_repeating)
  }
  invisible(NULL)
}

#' Append one inventory row to the accumulator.
#' @noRd
emit_inventory_row <- function(acc, xpath, parent_path, rec, schema,
                               is_leaf, truncated, repeating) {
  occ <- rec$occ_node
  min_occurs <- xml2::xml_attr(occ, "minOccurs")
  if (is.na(min_occurs)) min_occurs <- "1"
  max_occurs <- xml2::xml_attr(occ, "maxOccurs")
  if (is.na(max_occurs)) max_occurs <- "1"

  acc$n <- acc$n + 1L
  acc$rows[[acc$n]] <- list(
    xpath = xpath,
    parent_path = parent_path,
    element = rec$name,
    xsd_type = rec$type %||% NA_character_,
    is_leaf = is_leaf,
    truncated = truncated,
    min_occurs = min_occurs,
    max_occurs = max_occurs,
    repeating = repeating,
    annotation = element_annotation(rec, schema$ns)
  )
  invisible(NULL)
}

#' Documentation text for an element: from its definition node, falling
#' back to the declaration node (the ref site). NA when absent/empty.
#' @noRd
element_annotation <- function(rec, ns) {
  a <- xml2::xml_find_first(rec$def_node, "./xs:annotation/xs:documentation", ns)
  if (inherits(a, "xml_missing") && !identical(rec$def_node, rec$occ_node)) {
    a <- xml2::xml_find_first(rec$occ_node, "./xs:annotation/xs:documentation", ns)
  }
  if (inherits(a, "xml_missing")) return(NA_character_)
  txt <- trimws(xml2::xml_text(a))
  if (!nzchar(txt)) NA_character_ else txt
}

#' Child element records for `rec`: the direct content-model elements of
#' its complex type (and any `complexContent/extension` base), resolving
#' `ref`s to their global declarations. Empty for leaf/value elements.
#' @noRd
element_children <- function(rec, schema) {
  out <- list()
  for (container in content_containers(rec, schema)) {
    for (decl in collect_model_elements(container, schema, character(0))) {
      cr <- resolve_child_record(decl, schema)
      if (!is.null(cr)) out[[length(out) + 1]] <- cr
    }
  }
  out
}

#' The complexType node(s) whose content model defines `rec`'s children:
#' the element's named type (or inline anonymous type), plus a single
#' `complexContent/extension` base if present. Empty list => leaf
#' (simpleType / primitive / typeless element carries a value, no
#' child elements).
#' @noRd
content_containers <- function(rec, schema) {
  ns <- schema$ns
  ty <- rec$type
  if (is.null(ty) || is.na(ty)) return(list())

  ct <- if (ty == "(anonymous)") {
    node <- xml2::xml_find_first(rec$def_node, "./xs:complexType", ns)
    if (inherits(node, "xml_missing")) return(list())
    node
  } else {
    # Named simpleTypes (USAmountType, TextType, ...) are not in the
    # complex_types index -> NULL -> leaf.
    schema$complex_types[[ty]]
  }
  if (is.null(ct)) return(list())

  out <- list(ct)
  ext <- xml2::xml_find_first(ct, "./xs:complexContent/xs:extension[@base]", ns)
  if (!inherits(ext, "xml_missing")) {
    base <- sub("^[^:]+:", "", xml2::xml_attr(ext, "base"))
    base_ct <- schema$complex_types[[base]]
    if (!is.null(base_ct)) out[[length(out) + 1]] <- base_ct
  }
  out
}

#' Collect the direct content-model `xs:element` declarations under a
#' node, recursing through model groups (sequence/choice/all,
#' complexContent/extension/restriction, and named group refs) but
#' STOPPING at any nested complexType/simpleType - those belong to a
#' child element and are visited when we descend into that child.
#' @noRd
collect_model_elements <- function(node, schema, seen_groups) {
  out <- list()
  for (ch in xml2::xml_children(node)) {
    nm <- xml2::xml_name(ch)
    if (nm == "element") {
      out[[length(out) + 1]] <- ch
    } else if (nm %in% c("sequence", "choice", "all",
                         "complexContent", "extension", "restriction")) {
      out <- c(out, collect_model_elements(ch, schema, seen_groups))
    } else if (nm == "group") {
      ref <- xml2::xml_attr(ch, "ref")
      if (!is.na(ref)) {
        g_name <- sub("^[^:]+:", "", ref)
        g <- schema$groups[[g_name]]
        if (!is.null(g) && !(g_name %in% seen_groups)) {
          out <- c(out, collect_model_elements(g, schema, c(seen_groups, g_name)))
        }
      }
    }
    # skip: annotation, attribute, attributeGroup, anyAttribute, any,
    # complexType, simpleType
  }
  out
}

#' Build a child record from a content-model `<xs:element>` declaration.
#' For a named element, type comes from `@type`/inline. For a `ref`, the
#' cardinality stays on the ref site (`occ_node`) but type and
#' definition come from the referenced global element (`def_node`).
#' @noRd
resolve_child_record <- function(decl, schema) {
  name_attr <- xml2::xml_attr(decl, "name")
  if (!is.na(name_attr)) {
    ty <- xml2::xml_attr(decl, "type")
    if (!is.na(ty)) {
      ty <- sub("^[^:]+:", "", ty)
    } else {
      inline <- xml2::xml_find_first(decl, "./xs:complexType", schema$ns)
      ty <- if (!inherits(inline, "xml_missing")) "(anonymous)" else NA_character_
    }
    return(list(name = name_attr, type = ty, occ_node = decl, def_node = decl))
  }

  ref_attr <- xml2::xml_attr(decl, "ref")
  if (!is.na(ref_attr)) {
    ref_name <- sub("^[^:]+:", "", ref_attr)
    cands <- schema$elements[[ref_name]]
    if (is.null(cands) || length(cands) == 0) {
      return(list(name = ref_name, type = NA_character_,
                  occ_node = decl, def_node = decl))
    }
    top <- Filter(function(c) is_top_level_element(c$node), cands)
    pick <- if (length(top) > 0) top[[1]] else cands[[1]]
    return(list(name = ref_name, type = pick$type,
                occ_node = decl, def_node = pick$node))
  }

  NULL
}

#' Assemble accumulated row records into a typed data.frame.
#' @noRd
inventory_rows_to_df <- function(rows, tax_year, version) {
  cols <- c("xpath", "parent_path", "element", "xsd_type", "is_leaf",
            "truncated", "min_occurs", "max_occurs", "repeating", "annotation")
  if (length(rows) == 0) {
    empty <- data.frame(tax_year = character(0), version = character(0),
                        stringsAsFactors = FALSE)
    for (cl in cols) empty[[cl]] <- if (cl %in% c("is_leaf", "truncated", "repeating")) {
      logical(0)
    } else {
      character(0)
    }
    return(empty)
  }
  chr <- function(key) vapply(rows, function(r) {
    v <- r[[key]]
    if (is.null(v) || is.na(v)) NA_character_ else as.character(v)
  }, character(1))
  lgl <- function(key) vapply(rows, function(r) isTRUE(r[[key]]), logical(1))
  data.frame(
    tax_year = as.character(tax_year),
    version = as.character(version),
    xpath = chr("xpath"),
    parent_path = chr("parent_path"),
    element = chr("element"),
    xsd_type = chr("xsd_type"),
    is_leaf = lgl("is_leaf"),
    truncated = lgl("truncated"),
    min_occurs = chr("min_occurs"),
    max_occurs = chr("max_occurs"),
    repeating = lgl("repeating"),
    annotation = chr("annotation"),
    stringsAsFactors = FALSE
  )
}
