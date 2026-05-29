# 0002 — Phase 0 Build: PRI and Government Grants Vertical Slice

- **Status:** Accepted (planning; not yet executed)
- **Date:** 2026-05-22
- **Deciders:** sole maintainer
- **Inherits from:** [[0001-producer-design]]
- **Inherits from (nccs-contracts):** [[0007-efile-urban-owned-producer]], [[0014-standardize-manifest-shape]], [[0017-efile-phase-0-vertical-slice]]

## Context

`nccs-contracts/decisions/0017` resolved the strategic decisions
around Phase 0: ship two columns first, vendor NODC at a pinned
SHA, build trust-verification at extraction time, transition to an
NCCS-owned two-layer concordance in Phase 0.5, GT data lake as
primary upstream. `decisions/0001` in this repo settled the
producer-internal design (R, package layout, S3 paths, EC2
production / laptop dev split).

What neither of those documents pins is the **build sequence**:
which scripts get written in which order, what counts as "done"
for Phase 0, how to validate, and what gets handed back to
`nccs-contracts` at the end.

This ADR is that build playbook. It is deliberately narrow — only
the PRI and government-grants slice. Phase 1+ work falls under
later ADRs in this repo.

The two fields:

| `nccs_name` | Form | Source | NODC `variable_name` |
|---|---|---|---|
| `government_grants` | 990 | Part VIII line 1e | `F9_08_REV_CONTR_GOVT_GRANT` |
| `program_related_investments_total` | 990-PF | Part IX-B aggregate | `PF_09_PROG_RLTD_INVEST_AMT_TOT` |

XPath variants for each (verified via inspection of NODC
`concordance.csv` during the parent session's 2026-05-22 recon):

- `government_grants` (990):
  - `/Return/ReturnData/IRS990/Form990PartVIII/GovernmentGrants`
  - `/Return/ReturnData/IRS990/GovernmentGrants`
  - `/Return/ReturnData/IRS990/GovernmentGrantsAmt`
- `program_related_investments_total` (990PF):
  - `/Return/ReturnData/IRS990PF/SumOfProgramRelatedInvestments/Total`
  - `/Return/ReturnData/IRS990PF/SumOfProgramRelatedInvstGrp/TotalAmt`

## Decision — build sequence

Four phases (B–D from the parent session's ramp, plus a final
reconcile beat E). Each phase has a clear deliverable, validation
step, and commit point.

### Phase B — Vendoring + layer-2 seed (½ day)

**Goal:** NODC concordance is mirrored to S3 at a pinned SHA, and
`inst/concordance/nccs_dictionary.csv` carries the two Phase 0
rows with IRS instruction citations captured.

**Files:**

- `inst/config.yml` — initial config with `vendored.nodc_concordance_sha`,
  empty scope, default parallelism = 4 (laptop), output flags off.
- `R/vendor_nodc.R` — exposes `vendor_nodc_concordance(sha)`. Pulls
  raw GitHub URL at SHA, computes sha256 of the fetched content,
  uploads to `s3://nccsdata/processed/efile/concordance/{sha}_{YYYY-MM-DD}.csv`
  using `aws.s3::put_object` (or shell-out to `aws s3 cp` —
  whichever lands cleaner; pin in implementation). Idempotent.
- `inst/concordance/nccs_dictionary.csv` — Phase 0 seed, two rows.
  Columns per [[0001-producer-design]] §7.
- `tests/testthat/test-vendor-nodc.R` — verifies the vendoring
  function is idempotent and that the mirrored file's sha256
  matches the pulled content.

**Validation:**

- `aws s3 ls s3://nccsdata/processed/efile/concordance/` shows the
  mirrored file at the pinned SHA.
- `inst/concordance/nccs_dictionary.csv` has 2 rows with non-empty
  `irs_instruction_citation` values.

**Commit:** "Phase B — vendor NODC concordance at SHA, seed layer-2
dictionary with PRI and gov_grants."

### Phase C — XSD verifier (1–2 days)

**Goal:** the IRS XSDs for 2020+ are mirrored to S3, and the five
XPath claims for the two fields are verified to resolve to
`USAmount`-typed elements across all (tax_year, sub-version)
combinations.

**Files:**

- `R/fetch_xsds.R` — downloads IRS XSD ZIPs for tax years 2020–
  current from the IRS TY pages. Unpacks. Uploads each
  `(tax_year, version)` directory to
  `s3://nccsdata/processed/efile/schemas/{tax_year}/{version}/`.
  Idempotent: if the target prefix has the expected `meta.json`
  marker with matching sha256, skip.
- `R/verify_xpath.R` — given `(xpath, tax_year, version,
  expected_type)`, walks the XSD and returns
  `list(found, actual_type, path_to_element, matches_expected)`.
  Pure function; testable.
- `R/run_phase0_verification.R` — iterates over all (tax_year ×
  sub-version × XPath) combinations for the five Phase 0 XPath
  claims (3 × 990, 2 × 990PF). Returns a structured report.
- `inst/scripts/phase0_verify.R` — entrypoint script for the
  verifier. Loads config, calls `run_phase0_verification`, writes
  report to `out/phase0_verification_report.json` (local) or
  uploads to a sandbox S3 prefix (CI).
- `tests/testthat/test-verify-xpath.R` — unit tests with hand-
  curated XSD fixtures: known-good XPaths return `matches_expected
  = TRUE`; deliberately-wrong XPaths return `FALSE` with the
  actual element type.

**Validation:**

- `out/phase0_verification_report.json` shows all 5 × N
  (tax_year × version) combinations passing.
- Any mismatch is investigated before Phase D begins. A mismatch
  is a signal that either NODC's XPath claim is wrong for that
  version, or the IRS introduced a rename. Either way, the
  layer-2 dictionary row needs an updated `xpath_claims` entry.

**Commit:** "Phase C — XSD verifier for Phase 0 XPath claims;
mirror IRS XSDs to S3."

### Phase D — Extractor, manifest emission, publish (2–3 days)

**Goal:** end-to-end pipeline reads GT data lake indices, applies
the layer-2 dictionary, extracts the two fields per filing, writes
parquet + dictionary + quality.json + manifest, publishes to
`s3://nccsdata/processed/efile/phase0/v{YYYY.MM}/`.

**Files:**

- `R/fetch_gt_indices.R` — anonymous `aws s3 sync` of
  `s3://gt990datalake-rawdata/Indices/990xmls/`. Parses JSON
  manifests. Returns a data.frame of (S3 key, EIN, form_type,
  tax_year, filing_receipt_id). Filtered by config scope.
- `R/extract_filing.R` — given one index row + the layer-2
  dictionary slice for that form, anonymous S3 read of the XML,
  applies each XPath variant (first non-null wins), returns
  `list(ein, tax_year, form_type, filing_receipt_id, value)`.
- `R/extract_all.R` — drives `extract_filing` over the filtered
  index with `furrr::future_map_dfr`. Parallelism from config.
- `R/write_outputs.R` — assembles per-form data.frame, writes
  parquet (zstd) via `arrow::write_parquet`, computes
  `*_dictionary.csv` from the layer-2 dictionary rows used,
  computes `*_quality.json` (row count, null rate, value range,
  per-year counts, per-form counts).
- `R/assemble_manifest.R` — emits `_manifest.json` per
  [[0001-producer-design]] §10 schema, including the
  `xsd_verification` block (loaded from Phase C's report),
  `value_distribution` block (computed from Phase D's outputs),
  and `inputs` block (NODC SHA, GT snapshot timestamp).
- `R/publish.R` — uploads the vintage directory to
  `s3://nccsdata/processed/efile/phase0/v{YYYY.MM}/` via shell-out
  to `aws s3 cp --recursive`. Server-side copy to
  `phase0/latest/`. Refuses to overwrite an existing vintage
  unless `--force` flag is set.
- `inst/scripts/run_phase0.R` — top-level entrypoint:
  vendor_nodc → fetch_gt_indices → run verification → extract_all →
  write_outputs → assemble_manifest → publish.
- `tests/testthat/test-extract-filing.R` — unit tests against the
  hand-curated XML fixtures in `tests/testthat/fixtures/`
  (5–10 real 990 and 990-PF filings).

**Validation:**

- Local dev run: scope = `{forms: [990, 990PF], tax_years: [2024],
  index_filter: "first 1000 keys per form"}`. Runs in <10 minutes
  on laptop. Outputs land in `out/`. Manual sanity-check on the
  two parquets — sensible value ranges, expected null rates,
  manifest reads cleanly.
- EC2 production run: scope = `{forms: [990, 990PF], tax_years:
  [2020, 2021, 2022, 2023, 2024], no filter}`. Runs on a
  provisioned c5.18xlarge. Publishes to
  `s3://nccsdata/processed/efile/phase0/v2026.06/` (or whichever
  vintage matches the run month).
- The published vintage's `_manifest.json` is downloadable, parses
  cleanly, and `xsd_verification.passed == true`.

**Commit:** "Phase D — extractor, manifest, publish; first Phase 0
vintage."

### Phase E — Reconcile to nccs-contracts (½ day)

**Goal:** the contracts repo reflects executed-state for the
Phase 0 work.

**Actions in `nccs-contracts`:**

- Flip [[0017-efile-phase-0-vertical-slice]] Status to
  `Accepted (partially executed YYYY-MM-DD) — see Outcome`.
- Add Outcome section: what shipped (Phase 0 vintage at
  `s3://nccsdata/processed/efile/phase0/v2026.MM/`), what
  diverged or deferred (anything that didn't go to plan).
- Update `contracts/efile.yml`:
  - `manifest.path` → actual path
  - `producer.publish_path` → `inst/scripts/run_phase0.R`
  - `s3.versioned_template` → confirmed pattern
  - `schema.source` → first vintage's `*_dictionary.csv` paths

**Actions in `sector-in-brief-data` (separate beat, separate
commit):**

- Add `panel_gov_grants.R` and `panel_pf_pri.R`.
- Wire panels in dashboard's `R/data_server_args.R`.
- Bump `sector-in-brief-data` to a new vintage that includes the
  two new panels.

**Commit (contracts): "Reconcile ADR 0017 to partially executed
after first Phase 0 vintage."**

## Acceptance criteria — "Phase 0 is done" when:

1. A vintage is published at
   `s3://nccsdata/processed/efile/phase0/v{YYYY.MM}/` containing
   `government_grants.parquet`, `program_related_investments.parquet`,
   their dictionary and quality companions, and `_manifest.json`.
2. The manifest's `xsd_verification.passed == true`.
3. The manifest's `value_distribution.*.null_rate` and `range` are
   within configured thresholds (per
   [[0001-producer-design]] §6); any threshold breach was
   investigated and either resolved or accepted with a written
   note in the manifest.
4. The vintage's parquet row counts are non-zero for each
   (form_type, tax_year) combination in scope.
5. A held-out spot-check of 10 random filings per form, manually
   extracting the value from the source XML and comparing to the
   parquet, agrees in every case.
6. `nccs-contracts/decisions/0017` has been flipped to partially
   executed, with an Outcome section documenting what shipped.

## Test plan

**Unit tests (run on every PR in this repo):**

- `test-vendor-nodc.R` — idempotency, sha256 integrity, S3 round-trip.
- `test-verify-xpath.R` — known-good and known-bad XPath claims
  against hand-curated XSD fixtures.
- `test-extract-filing.R` — extraction over the 5–10 real XML
  fixtures; null handling; multiple XPath variant resolution
  (first non-null wins).
- `test-assemble-manifest.R` — manifest shape matches the schema
  in `inst/manifest_schema.json`.

**Integration tests (run manually, or weekly via cron):**

- Small-scope end-to-end run (first 100 keys × 990 × 2024); compare
  output to a checked-in golden manifest.

**Held-out validation (manual, one-time per vintage):**

- 20 filings (10 per form) randomly sampled from the published
  vintage. Manual XPath extraction from the source XML; compare to
  the parquet value. Document in the vintage's `Outcome` section
  of this ADR after Phase E.

## Open items

These get pinned during execution:

1. **First NODC SHA to pin.** Captured at Phase B start. Likely
   the latest `master` SHA as of the start date.
2. **EC2 provisioning approach.** Defer per [[0001-producer-design]]
   Follow-up #1; shell script is the working assumption.
3. **Test fixtures.** Curate 5–10 real 990 + 990-PF XMLs from the
   GT lake; commit to `tests/testthat/fixtures/`. Pre-Phase D.
4. **The first vintage's value-distribution thresholds.** Phase D's
   first run produces the *actual* distribution; document it in
   the vintage's Outcome and amend [[0001-producer-design]] §6
   if the placeholder thresholds were wrong.
5. **CI workflow file.** `.github/workflows/r-cmd-check.yml` and
   `.github/workflows/testthat.yml` to land alongside Phase B.
   Standard R-package CI; nothing producer-specific.

## Consequences

**Positive:**

- The work has a concrete sequence with named files and named
  validation steps. Reduces the "what do I do today" cost during
  execution.
- Acceptance criteria are written down before code is written; the
  "done" line is auditable.
- The reconcile beat (Phase E) is treated as a first-class part of
  the plan, not an afterthought.

**Negative:**

- The plan will divert. File names will change; phase splits will
  blur; some steps will turn out larger than estimated. The
  Outcome section after execution is where the divergence gets
  recorded honestly. This ADR's value is as a starting reference,
  not a contract.
- The 4–6 day total estimate across Phases B–D is rough. If a
  phase blows out (most likely Phase C, where XSD-walking against
  IRS oddities can surprise), the rest of the schedule slips
  proportionally.

## Outcome

### Shipped

First Phase 0 vintage `v2026.05` published 2026-05-29 to
`s3://nccsdata/processed/efile/phase0/v2026.05/` with a `latest/`
mirror (producer git SHA `0a7048d`). Both parquets, their dictionary
and quality companions, and `_manifest.json` present (acceptance
criterion 1). Forms 990 + 990-PF, tax years 2020-2024. NODC pinned at
SHA `49f62af015ad56c4857273eff633166ba6c1a4da`, mirrored to
`processed/efile/concordance/`. `nccs-contracts/decisions/0017`
reconciled to Executed and `contracts/efile.yml` populated from the
published artifact (acceptance criterion 6).

### Gate 5 — IRS instruction spot-check (ADR 0017 §2.3), 2026-05-29

Completed and signed off. Both layer-2 dictionary rows now carry
verified `irs_instruction_citation` values (the prior "(CONFIRM
PAGE)" placeholders are removed), cross-referenced against the actual
IRS instructions:

- **`government_grants`** — Form 990 Part VIII (Statement of Revenue)
  line 1e, "Government grants (contributions)". 2024 Instructions for
  Form 990, p. 39. Part/line stable across TY2020-2024. The
  instruction text confirms the NODC semantic: contributions in the
  form of grants/similar payments from local/state/federal/foreign
  government sources, *received* by the filer — distinct from line 2
  program-service revenue and from Schedule I grants paid *to*
  governments.
- **`program_related_investments_total`** — Form 990-PF "Summary of
  Program-Related Investments", aggregate (sum of lines 1-3). 2024
  Instructions for Form 990-PF, p. 31. **Form-renumbering caught
  here:** this section is **Part VIII-B for TY2021-2024** but **Part
  IX-B for TY2020** (the IRS renumbered Form 990-PF after the 2020
  revision; the NODC `PF_09_` variable name is 2020-anchored). The
  prior citation's flat "Part IX-B" was wrong for four of the five
  in-scope years. The version-agnostic XPath
  (`SumOfProgramRelatedInvstGrp/TotalAmt`) resolves across all years
  regardless, so the data was unaffected by the citation error — only
  the human-facing reference was stale.

### Diverged or deferred — 2022/2023 version-string null bug

A defect was found in v2026.05 while finalizing gate 5 and fixed in
the same dictionary change:

- **Symptom:** `government_grants` and `program_related_investments_total`
  are 100% null for tax years **2022 and 2023** in the published
  v2026.05 (2020/2021/2024 have normal ~0.60-0.73 null rates).
- **Cause:** the layer-2 `xpath_claims` tuples for 2022/2023 used
  hyphenated version strings (`2022:4-0`, `2023:5-1`, …). At extraction
  `resolve_xpath` matches the GT index `return_version` parsed by
  `parse_return_version`, which yields the dotted IRS form
  (`2022v4.0` → `4.0`). Hyphen ≠ dot, so no tuple matched for those
  years and every value fell through to `NA`. The hyphenated form
  came from the IRS XSD *folder* naming (which is why the manifest's
  `xsd_verification` block, driven off the XSD side, shows hyphens for
  2022/2023 and dots elsewhere) — the two sides used different
  conventions and only the extraction side mattered for the value.
- **Fix:** version strings for 2022/2023 normalized to dots to match
  `parse_return_version` output; a `2023:6.0` tuple was added. The
  XSD-verification side that legitimately uses hyphenated folder names
  is unaffected.
- **Consequence:** v2026.05 must be rebuilt and republished; it is
  materially incomplete for 2022-2023 (~1.27M filings across both
  fields returned spurious nulls). Tracked in `contracts/efile.yml`
  Open items.

This is also why the published manifest's sampled `value_distribution`
null rates (gov_grants 0.797, PRI 0.767) ran high and PRI tripped its
null-rate floor: two of five years were entirely null.

### Held-out validation results

Acceptance criterion 5 (independent `xmlstarlet` re-extraction of 10
filings per form, ADR 0017) was run via `spot_check_vintage()` at
publish but, given the 2022/2023 null defect above, did not exercise
those years' resolution path. Re-run against the rebuilt vintage and
record agreement counts here.
