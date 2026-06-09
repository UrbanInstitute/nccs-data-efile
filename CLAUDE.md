# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`nccs.data.efile` is the Urban-owned producer of the contracted **e-file tier** of the NCCS data system — structured data extracted from IRS Form 990-series e-file XML. It is a proper R package (not a loose script pipeline like the sibling `nccs-data-core`), driven by the exported `run_phase0()`.

**Phase 0 is LIVE** and deliberately narrow — two filing-grain fields:

| field | source | form |
|---|---|---|
| `government_grants` | Form 990 Part VIII line 1e | 990 |
| `program_related_investments_total` | Form 990-PF "Summary of PRI" aggregate | 990-PF |

Scope: forms 990 + 990-PF, tax years 2020–2024. Output is per-filing parquet (`ein × tax_year × form_type × filing_receipt_id × value`) under `s3://nccsdata/processed/efile/phase0/{vintage}/` with a `latest/` mirror. Current vintage **v2026.06** (producer SHA `22b131b`) is a perf-only re-extract of the first vintage v2026.05 — same field set, behavior-preserving.

Aggregation to dashboard grain is **not** done here; it stays in the downstream `sector-in-brief-data` consumer.

## Pipeline architecture

`run_phase0()` (`R/run_phase0.R`) drives the build end-to-end; `inst/scripts/run_phase0.R` is the CLI entry point. The stages, each a gate that aborts the build on failure:

1. **Schema verification** — `run_phase0_verification()` builds the Layer 1 XSD inventory once and verifies the **dictionary's own** `xpath_claims` against it via `verify_dictionary_against_inventory()`: each claim must resolve to a *leaf* element whose XSD type is consistent with the field's `data_type` (numeric `double`/`int` → a numeric XSD type, hard). This replaced the former per-claim XSD re-walk driven by a hand-maintained `phase0_claims` list (retired in Phase 0.5). Always strict; produces the manifest's `xsd_verification` block. (`verify_xpath()` is the single-cell lookup primitive.) Behind `skip_xsd_verification` (needs the XSD cache).
2. **Index fetch** — `fetch_gt_indices()` reads the GivingTuesday data lake's JSON filing indices.
3. **Claim coverage** — `verify_claim_coverage()` (demand-side): every in-scope `(tax_year, version)` in the index must resolve to an XPath claim, or the build hard-stops.
4. **Extract** — `extract_filings()` / `extract_filing()`: parallel (`furrr`) per-filing XML parse + XPath eval, via the ZIP-bulk staging path.
5. **Value-distribution gate** — `verify_value_distribution()`: per ADR / producer PR #5, `min`/`max` are checked over the **full population** (order statistics can't be sampled), `null_rate` over a stratified sample, plus heavy-tail diagnostics (`tail_diagnostics()`). Strict per `config$verification$strict`.
6. **Write + manifest** — `write_phase0_output()` emits parquet + `_dictionary.csv` + `_quality.json` per output; `emit_manifest()` writes `_manifest.json` (ADR 0014 shape, pins NODC SHA + XSD provenance).

`run_phase0()` never publishes — `inst/scripts/run_phase0.R` does `aws s3 sync` after a clean build (gated by `config$output$s3_enabled`, true only in the `production` profile), so a failed gate never half-publishes.

### Two-layer concordance (Phase 0.5)

The path to NCCS owning its own concordance (and demoting NODC to a comparison artifact):

- **Layer 1 — mechanical XSD inventory** (`R/xsd_inventory.R`): `build_xsd_inventory()` does a full DFS over each IRS XSD enumerating every element (xpath, type, cardinality, leaf-ness, `xsd:documentation`). `publish_xsd_inventory()` writes the cross-product to `s3://nccsdata/processed/efile/concordance/layer1/`. Never hand-edited; regenerated per IRS release.
- **Layer 2 — curated semantic dictionary** (`inst/concordance/nccs_dictionary.csv`): NCCS `snake_case` names → `(tax_year, version, xpath)` claims + IRS-instruction citations. Loaded by `load_dictionary()`; claims parsed by `resolve_xpath()` / `parse_xpath_claim()`.
- **NODC comparison** (`R/compare_nodc.R`): `compare_dictionary_to_nodc()` is an informational, non-blocking diff of Layer 2 against the full NODC concordance — agreement / divergence / coverage. A review + prioritization signal, not a gate.

## Running

This is an R package; develop with `pkgload`, not by re-installing each time (locally).

```bash
# Full test suite (~190 tests) and a single file
Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'
Rscript -e 'pkgload::load_all("."); testthat::test_file("tests/testthat/test-xsd-inventory.R")'

# What CI runs (R CMD check via rcmdcheck + testthat)
Rscript -e 'rcmdcheck::rcmdcheck(args = "--no-manual")'

# Regenerate man/ + NAMESPACE after editing any roxygen comment
Rscript -e 'roxygen2::roxygenise(".")'

# Lint / style (Suggests)
Rscript -e 'lintr::lint_package()'
Rscript -e 'styler::style_pkg()'

# Full Phase 0 build — local default profile, then EC2 production (multicore, publishes)
Rscript inst/scripts/run_phase0.R
STAGE_DIR=~/stage Rscript inst/scripts/run_phase0.R production
```

Other entry scripts under `inst/scripts/`: `phase0_verify.R` (XSD verification only), `spot_check_vintage.R` (independent `xmlstarlet` re-extraction vs a published vintage), `profile_value_tails.R` (population heavy-tail report), `profile_parse_cost.R` / `parse_bench.R` / `timed_slice.R` (perf profiling).

S3 operations shell out to the **AWS CLI** (not an R SDK), profile **`thiya`** — credentials must be available to the shell (IAM role on EC2, or `aws sso login --profile thiya`). XSDs are cached at `~/.cache/nccs-data-efile/xsds/{tax_year}/{version}/`.

## Conventions & gotchas worth knowing

- **Version keys are dotted, not hyphenated.** Extraction resolves a filing's version via `parse_return_version()` → dotted (`2022v5.0` → `5.0`), and the dictionary's `xpath_claims` must match. The IRS *folder* convention (and `config$xsd$versions`) is hyphenated for 2022/2023 (`5-0`). A hyphen/dot mismatch silently nulled all of TY2022/2023 in the first v2026.05 publish; `verify_claim_coverage()` now hard-stops any unresolved `(year, version)`. Cross-layer joins normalize via `canon_version()`.
- **Gated schemas inherit via aliases.** 2024 v5.1/v5.2 and 2023 v6.0 have no public TEOS XSD; `config$xsd$version_aliases` redirects them to the nearest published version (5.0 / 5-1). The manifest records the inheritance.
- **Namespace-aware XPath (commit `c3673ae`).** `extract_filing` binds the IRS efile namespace and uses prefixed XPaths instead of `xml_ns_strip`. This was a pure perf fix (the strip cliffed to ~24 min on one 36 MB filing); it is behavior-preserving — do not reintroduce `xml_ns_strip`.
- **PRI section renumbered across years.** Form 990-PF "Summary of PRI" is **Part IX-B for TY2020** but **Part VIII-B for TY2021–2024**; the version-agnostic XPath resolves regardless. NODC's `PF_09_` name is 2020-anchored.
- **NODC is a vendored input, never an authority.** The concordance is pinned at a commit SHA, mirrored to S3, **ODC-By licensed** (attribution required — *not* MIT). `drift_check_nodc()` flags upstream changes but adoption is **always explicit** (never auto-bump). Correctness is established by NCCS's own checks against the IRS XSD + raw XML, not by trusting NODC.
- **Size cap.** `config$extract$max_file_mb` (50) skips pathological giant filings (recorded as `_extract_error`) so one filing can't stall a parallel batch.
- **EC2 dev trap.** The entry script does `library(nccs.data.efile)` = the *installed* package, not source. After any code change on EC2 you must `Rscript -e 'renv::install(".")'` before re-running, or it silently executes stale code. (`STAGE_DIR` / `CHECKPOINT_DIR` env vars relocate scratch off a too-small or NVMe-less volume.)

## Where the decisions live (the "why")

Don't restate these — link to them.

- **This repo:** `decisions/0001-producer-design.md` (producer design); `decisions/0002-phase-0-pri-gov-grants-slice.md` (Phase 0 build sequence + **Outcome**, the authoritative acceptance record for every vintage).
- **`nccs-contracts/decisions/`:** `0007` (original producer framing), `0017` (Phase 0 vertical slice + concordance posture; amends 0007), `0014` (manifest shape), `0001` (S3 as contract surface).
- **Contract surface:** `nccs-contracts/contracts/efile.yml` is authoritative for *what* and *where* this repo publishes.
- **Roadmap:** Phase 0.5 = NCCS-owned two-layer concordance (above) → NODC becomes a comparison artifact; Phase 1+ = headline 990, then schedules/990-EZ/backfill, then 990-PF.

## Contract-change guard (ADR 0022)

A PR that touches *what* or *where* this repo publishes — the `processed/efile/phase0` surface, or its manifest / dictionary / value-gate shape — must acknowledge the [`nccs-contracts`](https://github.com/UrbanInstitute/nccs-contracts) impact, or CI fails. The `.github/workflows/contracts-guard.yml` caller (a thin wrapper over the reusable guard in `nccs-contracts`) fires on PRs that change the publish/manifest/dictionary/config/gate paths (`run_phase0*`, `emit_*`, `dictionary.R`, `config.R`, `verify_value_distribution.R`, `tail_diagnostics.R`, `inst/config.yml`). To pass: add an `ADR NNNN` breadcrumb to a commit message or the PR body and queue the `nccs-contracts` reconcile, **or** add the `contracts-ack` label if there is genuinely no contract impact. The guard checks *acknowledgment, not correctness*. Keep the caller's `paths_regex` in sync with this repo's publish surface as Phase 1+ partitioning lands.
