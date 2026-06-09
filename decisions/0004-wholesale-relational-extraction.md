# 0004 — Wholesale Relational Extraction: Producer Architecture

- **Status:** Accepted (planning; implementation pending)
- **Date:** 2026-06-09
- **Deciders:** sole maintainer
- **Implements:** [[nccs-contracts 0028]] (wholesale extraction to a normalized relational tier — the strategic mandate; this ADR owns the *how*)
- **Inherits from:** [[0001-producer-design]], [[0002-phase-0-pri-gov-grants-slice]], [[0003-two-layer-concordance]]

## Context

`nccs-contracts/decisions/0028` committed the producer to **wholesale
extraction to a normalized relational destination, rolled out
incrementally (scalar-first)**, and pinned the contract-surface calls:
the raw relational tier is the NCCS-owned *researcher catalog* —
published best-effort/uncontracted under
`s3://nccsdata/processed/efile/relational/{table}/`, XSD-faithful, no
stability guarantee; the curated Layer 2 views are the contracted,
guaranteed surface; the existing `phase0/` outputs are grandfathered as
the first curated views. 0028 explicitly defers the *how* — extractor
design, schemas, column naming, repeating-group representation,
partitioning, build mechanics — to this ADR.

The enabling asset already exists ([[0003-two-layer-concordance]]): the
Layer 1 inventory enumerates every element per `(tax_year, version)`
with `is_leaf`, `max_occurs`, and `parent_path` — exactly the metadata
needed to mechanically separate the non-repeating scalar universe from
repeating groups.

## Decision — the architecture

### 1. The scalar-leaf set (what "wholesale-scalar" extracts)

A field is in the header-table universe iff, in the Layer 1 inventory,
it is a **leaf** (`is_leaf == TRUE`) and **non-repeating** — no element
on its `parent_path` (nor itself) has `max_occurs == "unbounded"`. A
filing occurs at most once, so each such field is single-valued per
filing.

Computing "non-repeating" requires walking each leaf's ancestor chain
against the inventory. We add a derived boolean column **`repeating`**
to the Layer 1 inventory output (`xsd_inventory.R`) — TRUE if the
element or any ancestor is unbounded — so the scalar set is a one-line
filter (`is_leaf & !repeating`) and the repeating universe (for the
deferred child tables) is its complement.

### 2. Extraction engine — extend, don't replace

Reuse the existing per-filing path (namespace-aware parse, ZIP-bulk
staging, `max_file_mb` cap, `furrr` parallelism). The only change is
what gets pulled: a new `extract_filing_relational()` parses the DOM
once and pulls **every scalar-leaf** for the filing's `(form, version)`
(driven by the inventory slice), instead of only the dictionary's
claims. The existing `extract_filing()` (dictionary-driven) stays for
the grandfathered curated views. Marginal cost is low — the parse
dominates ([[0003]] / parse-cost work), so pulling ~1.5K leaves costs
≈ pulling two.

### 3. Output — per-form header tables, relational layout

- **One header table per form body**: `f990_header`, `f990pf_header`,
  plus `returnheader` (shared filing metadata, joined by key). Schedules
  become their own header tables as roots widen (see §6 / Open items).
- **Key:** `filing_receipt_id` (+ `ein`, `tax_year`, `form_type`
  carried for convenience), so child tables (§5) and curated views (§7)
  join cleanly.
- **Columns union across schema versions** within a form: the column
  set is the union of that form's scalar leaves over all in-scope
  versions; a filing populates the columns its version defines, the rest
  null. (Versions are mostly additive; the inventory makes the union
  mechanical.)
- **Column naming (raw tier = XSD-faithful, NOT snake_case):** the
  element's path **relative to the form root**, segments joined by `_`
  — e.g. `/Return/ReturnData/IRS990/GovernmentGrantsAmt` →
  `GovernmentGrantsAmt`; a nested
  `…/IRS990/Form990PartVIII/SomethingGrp/Amt` → `Form990PartVIII_SomethingGrp_Amt`.
  This is deterministic and **collision-free** (two leaves with the same
  local name under different parents get distinct names). The full XPath,
  XSD type, and any `xsd:documentation` are carried in each table's
  dictionary for traceability. snake_case naming is deliberately *not*
  done here — that is the curated views' job (§7), per 0028.
- **Typing:** map `xsd_type` → parquet type via a small table
  (amount/decimal/integer/count → numeric; date types → date; boolean →
  bool; text/string → string; unknown → string). Generalizes the numeric
  type-class check from [[0003]]. On coercion failure, keep the raw
  string (the raw tier favors fidelity over strictness).

### 4. Layout, partitioning, provenance

`s3://nccsdata/processed/efile/relational/{table}/{vintage}/`, parquet,
partitioned by `tax_year`, zstd. Each table+vintage ships a `_manifest.json`
(producer SHA, inputs, row counts, checksums — [[0014]] shape) and a
`_dictionary.csv` (column → full XPath, XSD type, annotation). Provenance
is shipped **even though the tier is uncontracted** — best-effort is
about *stability*, not *traceability*. Every published artifact is
plainly marked best-effort/uncontracted (in the manifest and a tier
README) so no consumer mistakes "published" for "pinned" (0028's
accepted tradeoff).

### 5. Repeating-group child tables — modeled now, built on demand

Each repeating group (an element with `max_occurs == "unbounded"`, e.g.
grants, officers) maps to its own table
`relational/{form}_{group}/`, **one row per occurrence**, keyed by
`filing_receipt_id` + a 1-based `occurrence_index`, columns = the scalar
leaves *within* that group (path relative to the group root, same naming
rule). Implementation is **deferred to first demand** (0028 §3); the
header design above is already compatible — child tables join back by
`filing_receipt_id`, no header rework needed.

### 6. Roots / coverage

The scalar set is bounded by the inventory's roots (currently
990 + 990PF + ReturnHeader — [[0003]]). Widening to schedules / 990-EZ
is a `default_inventory_roots()` change that must precede emitting their
tables (an un-enumerated form has no inventory rows to extract).

### 7. Curated views (Layer 2) over the raw tier

A curated view selects specific raw columns, renames to form-agnostic
`snake_case`, attaches IRS-instruction citations, and publishes to the
**contracted** curated surface with a manifest + deprecation policy
([[0013]]/[[0014]]). The existing `phase0/` outputs (`government_grants`,
`program_related_investments`) **are** the first curated views and are
grandfathered at their current path, still produced by the existing
dictionary-driven path. Re-homing them as views-over-raw (so there is
one extraction path, not two) is a later increment, not a v1 blocker.

## Build sequence

1. **Inventory `repeating` flag** — add the derived ancestor-cardinality
   column to `xsd_inventory.R`; republish Layer 1. *(small)*
2. **Relational scalar extractor** — `extract_filing_relational()`
   (parse once → all non-repeating scalar leaves) + per-form assembly +
   type mapping. *(core)*
3. **Publish** — `relational/{table}/{vintage}/` + manifest + dictionary
   + best-effort marker. Local small-scope run, then EC2 scale.
4. **Acceptance** — spot-check raw values vs source XML; row counts vs
   index; sparsity/null profile per table; confirm `phase0/` curated
   outputs unchanged.
5. *(deferred)* repeating-group child tables on first demand (§5).
6. *(deferred)* curated-views mechanism; migrate `phase0/` to
   views-over-raw (§7).

## Acceptance criteria — "v1 (scalar) is done" when:

1. `f990_header`, `f990pf_header`, `returnheader` are published under
   `relational/` with manifests + dictionaries, covering the
   non-repeating scalar-leaf universe for 990 + 990PF, 2020–2024.
2. A held-out spot-check (independent re-extraction from source XML)
   agrees on a sample of columns/filings.
3. The tier is unmistakably marked best-effort/uncontracted.
4. The grandfathered `phase0/` curated outputs are byte-for-byte
   unaffected.

## Open items

1. **Column-name collisions across versions** — if the IRS *moves* an
   element (different parent path in a later version), the union yields
   two columns for one concept. Acceptable for the raw tier (it is
   XSD-faithful — the move is real); curated views reconcile it. Confirm
   no *within-version* collisions (the relative-path rule should prevent
   them).
2. **`returnheader` shared-table vs per-form fold** — modeled as a
   separate table here; revisit if the join proves awkward downstream.
3. **Storage footprint** at scale (full scalar universe × ~2M filings) —
   measure on the first scale run; scalars compress well, repeating
   groups stay demand-gated.
4. **When to migrate `phase0/` to views-over-raw** — deferred; pick it up
   once the raw tier is stable and a second curated view is needed.

## Consequences

**Positive.** A complete scalar surface at near-zero marginal extraction
cost; any future scalar request is "author a view," not "extract +
republish." The engine, inventory, and key all extend cleanly to the
repeating-group increment. The NCCS-owned researcher catalog gets built
as a by-product.

**Negative / accepted.** Two extraction paths coexist until `phase0/`
migrates to views (a deliberate, deferred consolidation). The raw tier's
XSD-faithful column names are ugly by design — fidelity over
friendliness — and the friendliness lives only in curated views.
Storage grows. The repeating-group model is committed on paper but
unproven until the first child table is built.
