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

First Phase 0 vintage `v2026.05` published to
`s3://nccsdata/processed/efile/phase0/v2026.05/` with a `latest/`
mirror. An initial publish (producer git SHA `0a7048d`, 2026-05-29)
carried the 2022/2023 null defect documented below; it was corrected
by a full re-extract and **republished 2026-05-29 17:07 ET (producer
git SHA `a9c32e5`, manifest `build_timestamp_utc`
2026-05-29T21:07:21Z)**, which is the accepted artifact. Both parquets
(GG 1,412,695 rows; PRI 526,807), their dictionary and quality
companions, and `_manifest.json` present, no scratch `_chunks/` leak
(acceptance criterion 1). Forms 990 + 990-PF, tax years 2020-2024.
NODC pinned at SHA `49f62af015ad56c4857273eff633166ba6c1a4da`,
mirrored to `processed/efile/concordance/`.
`nccs-contracts/decisions/0017` reconciled to Executed and
`contracts/efile.yml` populated from the published artifact
(acceptance criterion 6).

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

A defect was found in the initial v2026.05 publish (SHA `0a7048d`)
while finalizing gate 5, fixed in the dictionary, and cleared by the
re-extract republished as SHA `a9c32e5` (see **Shipped** and
**Held-out validation** for the post-fix evidence):

- **Symptom:** `government_grants` and `program_related_investments_total`
  were 100% null for tax years **2022 and 2023** in the initial
  publish (2020/2021/2024 had normal ~0.60-0.73 null rates).
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
- **Consequence (resolved):** the initial publish was materially
  incomplete for 2022-2023 (~1.27M filings across both fields returned
  spurious nulls). v2026.05 was re-extracted in full and republished
  (SHA `a9c32e5`, 2026-05-29 17:07 ET). Post-fix per-year null rates in
  the published parquets are normal — GG: 2020=.60, 2021=.60, 2022=.66,
  2023=.68, 2024=.73; PRI ~.62 across all years — and the rebuilt
  manifest's sampled `value_distribution` null rates fell to GG 0.661 /
  PRI 0.609 (vs. the buggy 0.797 / 0.767). A build-time guard,
  `verify_claim_coverage()`, now hard-stops any future build whose
  dictionary leaves an in-scope `(year, version)` unresolved (commit
  `a9c32e5`), so this class of defect cannot ship silently again.

The buggy manifest's sampled `value_distribution` null rates
(gov_grants 0.797, PRI 0.767) ran high — and PRI tripped its null-rate
floor — precisely because two of five years were entirely null.

### Held-out validation results

Acceptance criterion 5 (independent `xmlstarlet` re-extraction, ADR
0017) was first run via `spot_check_vintage()` at the initial publish
(20/20 agree) but, given the 2022/2023 null defect above, could not
exercise those years' resolution path — every sampled 2022/2023 value
was `NA` on both sides, so agreement was the trivial `NA == NA`.

Against the rebuilt vintage (SHA `a9c32e5`), a held-out re-extraction
was run that deliberately targets the previously-broken years:
**12/12 agree.** Twelve real 2022/2023 filings (both forms) were
sampled from the published parquets, their raw XML fetched from the GT
lake (`EfileData/XmlFiles/<object_id>_public.xml`), and the value
re-extracted with `xmlstarlet` independently of the producer's
extractor; all twelve matched the parquet exactly. The sample
exercises every version key that was broken: `2022v5.0`, `2023v5.0`,
`2023v5.1`, and `2023v6.0` (the tuple that had been missing entirely),
across both Form 990 (`GovernmentGrantsAmt`) and Form 990-PF
(`SumOfProgramRelatedInvstGrp/TotalAmt`). Criterion 5 is satisfied for
the corrected vintage.

### v2026.06 — perf-only re-extract (accepted 2026-06-09)

Second Phase 0 vintage `v2026.06` published to
`s3://nccsdata/processed/efile/phase0/v2026.06/` with a `latest/`
mirror (producer git SHA `22b131b`, manifest `build_timestamp_utc`
2026-06-08T20:18:00Z). This vintage is the output of the parse-cost
refactor (drop `xml_ns_strip` → namespace-aware XPath, commit
`c3673ae`) plus enabling the strict distribution gate with thresholds
pinned from v2026.05 (commit `649823d`). It is the first vintage built
under `verification.strict: true`.

**Behavior-preserving.** Row counts (GG 1,412,695; PRI 526,807) and
per-column null rates (GG 0.6417; PRI 0.6178) are identical to
v2026.05 to four decimals. A perf-only refactor that leaves the output
distribution unchanged is the intended result — it confirms the
namespace-aware XPath change did not alter extraction semantics, only
cost.

**Gates (acceptance criteria 1–4).** All seven files present in both
`v2026.06/` and `latest/`. `xsd_verification.passed == true` (80
checks; the `found:false` mismatches are the dead XPath variants — one
variant per (field, year, version) resolves, which is the pass
condition). Strict distribution gate passed: sampled null rates within
the pinned bands (GG [0.55, 0.78], PRI [0.50, 0.72]). Per-year row
counts non-zero for every (form, year) in scope. `extract_error_count`
= `size_capped_count` = 4 (the >50 MB giants, skipped and recorded, not
silently dropped).

**Performance.** Wall-clock was noticeably shorter than v2026.05 —
roughly ~5 hours faster on the same c5.18xlarge scale run — consistent
with the parse-cost root cause (sub-cap straggler ZIPs whose
`xml_ns_strip` step cliffed to ~24 min on the worst-case 36 MB file;
see the v2026.06 parse-cost analysis). The exact end-to-end runtime
was not captured before the instance was terminated; only the
qualitative delta is on record.

**Accepted threshold note (acceptance criterion 3 — written note).**
The strict gate evaluates a *stratified sample* (≤1000 rows per
year×form, ~5,000 per field; `verify_value_distribution.R:36`), not the
population. The full-population `_quality.json` carries values outside
the configured `[0, 1.0e10]` value band that the sample did not
contain:

- `government_grants` max = 13,197,193,142 (> configured `max: 1.0e10`)
  and min = −5,653,277 (< configured `min: 0`).
- `program_related_investments_total` min = −55,000 (< `min: 0`).

These were investigated against source XML and **accepted as
real-as-filed**, not extraction defects:

- The GG max (object_id `202212739349300946`, EIN 98-0593375, TY2021)
  and the recurring ~$9–12B GG filer (EIN 31-4379427, **Battelle
  Memorial Institute**, which manages federal national labs) both
  match their source `<GovernmentGrantsAmt>` exactly. The `1.0e10`
  ceiling was set in v2026.05 without knowledge that Battelle-class
  mega-grantees exist in the tail; the bound is too low, the data is
  correct.
- The negatives each pair with a negative `TotalContributionsAmt` on
  the same return (the whole contributions section is negative —
  consistent with prior-year grant clawbacks/refunds or restatements)
  and match the source XML exactly (object_ids `202321309349301607`,
  `202231369349305503`).

Follow-up (not blocking acceptance): the distribution gate's min/max
checks are order statistics and cannot be bounded by a sample. Compute
min/max over the full population (keep null-rate on the sample, where a
proportion is fine), and widen the GG `max` band to admit Battelle-class
filers — otherwise the gate can pass or fail stochastically on whether
a tail row lands in the sample. Tracked separately from this ADR.
