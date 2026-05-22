# 0001 — `nccs-data-efile` Producer Design

- **Status:** Accepted (planning; not yet executed)
- **Date:** 2026-05-22
- **Deciders:** sole maintainer
- **Inherits from (nccs-contracts):** [[0007-efile-urban-owned-producer]], [[0014-standardize-manifest-shape]], [[0013-versioned-producer-outputs]], [[0017-efile-phase-0-vertical-slice]]

## Context

This is the first ADR in `nccs-data-efile`. Its purpose is to pin the
producer-internal design choices that `nccs-contracts/decisions/0017`
explicitly left to this repo (per its Follow-up §1) so that build work
in Phases B–D (per the four-phase ramp documented in the parent
session) can proceed against a settled foundation.

Everything here is downstream of decisions already made in
`nccs-contracts`. This ADR does not re-justify them; it inherits and
operationalizes them. When this ADR conflicts with a contracts-side
ADR, the contracts-side ADR wins.

The producer's contract surface (output shape, S3 paths,
consumers) is defined in `nccs-contracts/contracts/efile.yml`. This
ADR is about how the producer is built, not what it publishes.

## Decision

### 1. Language and package layout

- **R**, matching `nccs-data-bmf` and `nccs-data-core`. Standard R
  package skeleton: `DESCRIPTION`, `NAMESPACE`, `R/`, `inst/`,
  `tests/testthat/`, `man/` (roxygen-generated).
- Code lives in `R/`. Configuration in `inst/config.yml`. Reference
  data (vendored NODC concordance pointer, layer-2 dictionary CSV,
  XSD cache pointer, IRS instruction citations) in `inst/`.
- `renv` for dependency pinning, matching `nccs-data-bmf`.
- Roxygen2 for inline documentation; package-level documentation in
  `R/nccs-data-efile-package.R`.

### 2. Core dependencies

- **`xml2`** — XML parsing and XPath evaluation against IRS e-file
  XML.
- **`arrow`** — parquet writes. zstd compression per
  `contracts/efile.yml`.
- **`aws.s3`** for programmatic S3 reads/writes where convenient;
  **shell-out to `aws s3 cp`/`aws s3 sync`** for bulk operations
  (matches the `sector-in-brief-data` pattern documented in
  `contracts/sector-in-brief.yml`).
- **`furrr` + `future`** for parallelization. Plan strategy is
  configuration-driven, not code-level (see §6).
- **`jsonlite`** — manifest and quality.json emission, GT data lake
  index reads.
- **`yaml`** — config and layer-2 dictionary load.
- **`digest`** — sha256 for per-file integrity per
  [[0014-standardize-manifest-shape]].
- **`cli`** — structured logging.

### 3. S3 layout

All paths under `s3://nccsdata/`, written using `--profile thiya`
(see `nccs-contracts` AWS profile convention).

**Build inputs (read by this producer; mirrored from upstream):**

- `processed/efile/concordance/{nodc_sha}_{YYYY-MM-DD}.csv`
  — NODC concordance vendored at pinned SHA per
  [[0017]] §2. The producer never reads from GitHub directly at
  build time.
- `processed/efile/schemas/{tax_year}/{version}/` — IRS XSD ZIPs
  unpacked, cached for the XSD verifier (§5). Same vendoring
  discipline as the concordance: pinned, mirrored, audited.

**Build outputs (written by this producer; consumer-facing):**

- Phase 0: `processed/efile/phase0/{vintage}/`
  - `government_grants.parquet`
  - `program_related_investments.parquet`
  - `{name}_dictionary.csv` per output
  - `{name}_quality.json` per output
  - `_manifest.json` (one per vintage covering all outputs in the
    vintage)
  - mirrored to `processed/efile/phase0/latest/` via server-side
    copy
- Phase 1+: `processed/efile/{filing_year}/{form_type}/` per the
  `latest_template` in `contracts/efile.yml`. Out of scope for this
  ADR.

**Vintage naming.** `v{YYYY.MM}` (e.g. `v2026.06`), matching
`sector-in-brief-data`'s convention. The vintage identifies the
month the producer ran, not the data coverage window.

### 4. Execution model — local development + EC2 production

Two execution modes, same code, different config:

**Local mode (development, vertical-slice testing):**
- Runs on a laptop with `furrr::plan(multisession, workers = 4)`.
- Index scope is sliced: one form, one tax year, one month, or a
  hand-curated list of N filings.
- Outputs to a local `out/` directory by default; S3 write enabled
  by config flag.
- Used for: testing extraction logic, validating XSD verifier
  results, sanity-checking a vintage shape before EC2 run.

**Production mode (full vintage build):**
- Runs on an EC2 c5.18xlarge (72 vCPU, 144 GB RAM, 25 Gbps network)
  in `us-east-1` (same region as both the GT data lake bucket and
  `s3://nccsdata`, so S3 traffic stays intra-region).
- `furrr::plan(multisession, workers = 72)`.
- Full index scope (all forms × all tax years in the producer's
  current Phase coverage).
- Outputs directly to `s3://nccsdata/processed/efile/{phase}/{vintage}/`.
- IAM role on the instance grants write to the bucket; no
  long-lived credentials.

**Operationally:** the EC2 instance is provisioned on demand for
each production build (not persistent). Run cost at $3/hr × ~hours
of work is dollars per vintage. Build script provisions, runs,
publishes, and terminates. Spot pricing is acceptable if available.

**Parameterization.** `inst/config.yml` carries:
- `parallelism.workers` (int)
- `parallelism.plan` (`multisession` | `multicore`)
- `scope.forms` (list)
- `scope.tax_years` (list)
- `scope.index_filter` (optional regex or explicit key list, for
  local slices)
- `output.s3_enabled` (bool)
- `output.s3_prefix` (string)

Local and EC2 modes differ only in config; no `if (is_ec2)` branches
in code.

### 5. XSD verifier (Phase 0 narrow scope; Phase 0.5 expansion seed)

Per [[0017]] §2.1, every Phase 0 build verifies that the XPath
claims being applied actually resolve to elements of the expected
type in the IRS XSD for that (tax_year, version). Implementation
plan:

- `R/fetch_xsds.R` — downloads IRS XSD ZIPs for each tax year,
  unpacks, uploads to `s3://nccsdata/processed/efile/schemas/...`.
  Idempotent: if the target prefix already has the expected
  contents (verified by ETag or sha256), skip.
- `R/verify_xpath.R` — given `(xpath, tax_year, version,
  expected_type)`, walks the cached XSD and returns a structured
  verification result: `found` (bool), `actual_type` (string),
  `matches_expected` (bool), `path_to_element` (string).
- `R/run_phase0_verification.R` — drives the verifier across all
  (tax_year × version × XPath) combinations for the five Phase 0
  XPath claims (3 for `government_grants`, 2 for
  `program_related_investments_total`). Emits a structured report
  written into the vintage's `_manifest.json` under
  `xsd_verification`. Fails the build on any mismatch.

The verifier code is deliberately structured so that "verify five
named XPaths" and "emit full per-version inventory for layer 1" are
the same function called over different inputs. Phase 0.5 doesn't
rewrite the verifier; it widens its scope.

### 6. Trust verification — value distribution sanity

Per [[0017]] §2.2, every Phase 0 build also samples extracted
values and asserts distribution properties:

- Sample size: 1000 filings per (tax_year, form_type) — large enough
  to detect distribution shifts, small enough to be cheap.
- Assertions:
  - `government_grants`: numeric, range [0, 1e10], non-null rate
    20–50% (rough; pin after first vintage)
  - `program_related_investments_total`: numeric, range [0, 1e10],
    non-null rate 5–15% (PRI is sparse; most foundations don't have
    any)
- Outliers logged to `*_quality.json`; threshold breaches fail the
  build.
- Thresholds live in `inst/config.yml`'s `verification` block;
  initial values are placeholders to be pinned after the first
  vintage's actual distribution is observed.

### 7. Layer-2 dictionary (the NCCS-owned semantic file)

Per [[0017]] §3, this is the curated artifact NCCS owns. Phase 0
seed:

- File: `inst/concordance/nccs_dictionary.csv`
- Columns:
  - `nccs_name` (string, snake_case)
  - `description` (string, human-written, ≤ 200 chars)
  - `unit` (string, e.g. `USD`, `count`, `flag`)
  - `data_type` (string, `double` | `int` | `string` | `bool`)
  - `forms_applicable` (semicolon-separated list, e.g. `990;990PF`)
  - `nodc_variable_name` (string; the row's source in NODC; empty
    once Phase 1+ runs natively off layer 1)
  - `irs_instruction_citation` (string; e.g. `IRS Form 990
    Instructions (2024), page 27, line 1e`)
  - `xpath_claims` (string; semicolon-separated
    `tax_year:version:xpath` tuples)
  - `notes` (string)
- Phase 0 row count: 2.
- Each row is a deliberate, reviewable assertion. PRs against this
  file are the human-review gate for naming and semantic decisions.

### 8. NODC vendoring + drift detection

Per [[0017]] §2:

- `R/vendor_nodc.R` — pulls
  `https://raw.githubusercontent.com/Nonprofit-Open-Data-Collective/irs-efile-master-concordance-file/{sha}/concordance.csv`
  at the configured SHA, uploads to
  `s3://nccsdata/processed/efile/concordance/{sha}_{YYYY-MM-DD}.csv`.
  Idempotent.
- `R/drift_check_nodc.R` — compares NODC master HEAD against the
  pinned SHA. On diff, summarizes affected rows and writes a
  GitHub issue against this repo via `gh` CLI. Cron-scheduled
  monthly per [[0004-cadence-aware-drift-detection]] (config in
  `.github/workflows/` once the workflow lands).
- The pinned SHA lives in `inst/config.yml` under
  `vendored.nodc_concordance_sha`. Changing it is an explicit
  commit on this repo, reviewed before merge.

### 9. GT data lake reads + IRS direct fallback

Primary upstream — GT data lake, anonymous reads:

- `R/fetch_gt_indices.R` — `aws s3 sync --no-sign-request
  s3://gt990datalake-rawdata/Indices/990xmls/ <local cache>/`.
  Filters per `scope.forms` and `scope.tax_years`. Emits an
  in-memory data.frame of (S3 key, EIN, form_type, tax_year,
  filing_receipt_id).
- `R/extract_filing.R` — given an index row, anonymous S3 read of
  the XML; applies the relevant layer-2 dictionary rows; emits a
  single-row data.frame. Designed to run inside `furrr::future_map`.

Fallback upstream — IRS direct:

- `R/fetch_irs_direct.R` — downloads per-(tax_year, month) ZIPs
  from `https://www.irs.gov/.../form-990-series-downloads`,
  unpacks to a temp directory, walks the contained XMLs. Same
  per-XML extraction surface (`extract_filing.R`) so the rest of
  the pipeline is unaware which upstream was used.
- Activation: config flag `upstream.primary` set to `irs_direct`
  instead of the default `gt_data_lake`. Tested in CI on a small
  scope; otherwise dormant.

### 10. Manifest and dictionary emission

Per [[0014-standardize-manifest-shape]] (still in planning at
contracts-side; this producer ships with the in-flight shape and
reconciles when 0014 stabilizes):

- `_manifest.json` per vintage:
  ```
  {
    "schema_version": 1,
    "producer": "nccs-data-efile",
    "producer_git_sha": "...",
    "vintage": "v2026.06",
    "build_timestamp_utc": "2026-06-15T14:23:11Z",
    "phase": "phase0",
    "scope": {
      "forms": ["990", "990PF"],
      "tax_years": [2020, 2021, 2022, 2023, 2024]
    },
    "inputs": {
      "nodc_concordance_sha": "...",
      "nodc_concordance_s3_path": "...",
      "gt_lake_snapshot_timestamp_utc": "...",
      "irs_xsd_cache_prefix": "s3://nccsdata/processed/efile/schemas/"
    },
    "files": [
      {
        "name": "government_grants.parquet",
        "sha256": "...",
        "row_count": ...,
        "bytes": ...
      },
      ...
    ],
    "xsd_verification": {
      "passed": true,
      "checks_run": 20,
      "mismatches": []
    },
    "value_distribution": {
      "government_grants": {
        "null_rate": 0.62,
        "min": 0,
        "max": 8400000,
        "p50": 12000,
        "p99": 1200000,
        "outliers_logged": 3
      },
      ...
    }
  }
  ```
- `*_dictionary.csv` per output file: one row per column, with
  `column_name`, `data_type`, `description`, `unit`, `source_xpath`,
  `source_nodc_variable_name`, `nodc_concordance_sha`,
  `irs_instruction_citation`.
- `*_quality.json` per output file: aggregate stats (row count,
  null rate per column, distribution summary, per-year counts).

### 11. CI and pre-commit hygiene

- `R CMD check` runs on every PR.
- `testthat` suite runs on every PR. Tests include XSD verifier
  unit tests against known-good and known-bad XPath claims.
- `styler` + `lintr` configured for consistent R style.
- No CI-driven publish to S3. Publishing is always a manual
  invocation from the EC2 production run (see §4).
- `.github/copilot-instructions.md` to be added after the
  maintainer's pending admin access lands on this repo (per the
  pattern established for `nccs-data-bmf` / `nccs-data-core` in
  May 2026).

## Open items (to be pinned during execution)

These are explicit TODOs that will be filled in during Phases B–D,
either by amending this ADR in place or by opening a follow-on ADR
when the divergence is material:

1. **Exact value-distribution thresholds** (§6). Placeholder ranges
   above are educated guesses; pin against the first vintage's
   actual distribution.
2. **Exact XSD ZIP download URLs and unpack convention** (§5).
   The IRS publishes XSD bundles on per-tax-year pages; the exact
   URL structure varies and needs to be hard-coded once verified.
3. **NODC concordance pinned SHA for the first Phase 0 build**
   (§8). To be pinned at Phase B start.
4. **EC2 provisioning script** (§4). Likely a small Terraform or
   shell script that boots the c5.18xlarge with the right IAM role,
   pulls this repo's main branch, runs `inst/scripts/run_phase0.R`,
   and terminates. Out of scope for this ADR; will live in
   `inst/scripts/` or `terraform/`.
5. **IRS instruction citations** for both Phase 0 fields. To be
   captured by the maintainer reading the IRS Form 990 (2024) and
   Form 990-PF (2024) instruction PDFs; populated into
   `nccs_dictionary.csv` before Phase B work begins.
6. **Quality.json schema details**. The shape in §10 is sketched;
   stabilize once the first vintage runs.
7. **Test fixtures**. `tests/testthat/fixtures/` will need a small
   set of real 990 and 990-PF XMLs for unit tests of
   `extract_filing.R`. Curate from 5–10 hand-picked filings.

## Consequences

**Positive:**

- The producer's internal design is settled enough that Phase B/C/D
  work doesn't need to re-litigate architectural decisions
  mid-build.
- Local + EC2 split is one config, not two code paths. Reduces the
  risk of dev-vs-prod drift.
- Vendoring discipline (NODC concordance + IRS XSDs both mirrored
  to S3 at SHA) makes every build reproducible from the manifest
  alone.
- The XSD verifier scope is deliberately drawn so Phase 0 narrow
  scope and Phase 0.5 layer-1 expansion are the same code at
  different parameters.

**Negative:**

- Real engineering work to ship even Phase 0 — multi-day, not
  multi-hour. Estimates per phase in the parent session's ramp:
  Phase B ½ day, Phase C 1–2 days, Phase D 2–3 days.
- EC2 c5.18xlarge production runs are dollars-per-vintage, not
  cents. Acceptable for monthly cadence; would be re-examined if
  cadence ever shifts to daily.
- The layer-2 dictionary file is a real curation burden, even at
  its small Phase 0 size of 2 rows. Phase 1+ growth (~200 rows)
  is real PR-review work.

## Follow-up

1. **Open ADR 0002** when EC2 provisioning approach is settled
   (Terraform vs. shell script vs. AWS Batch).
2. **Open ADR 0003** if/when the value-distribution thresholds in
   §6 turn out to be wrong by a meaningful margin and the
   verification policy needs to shift.
3. **Reconcile back to `nccs-contracts`** when Phase 0 first
   vintage ships: flip ADR 0017 Status to partially executed,
   populate Outcome, fill in the remaining TODOs in
   `contracts/efile.yml`.
4. **Layer 1 expansion plan** — open a producer ADR or amend this
   one when Phase 0.5 begins, documenting the full XSD walker
   design and the cross-version variable identity heuristic.
