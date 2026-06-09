# nccs-data-efile

**Urban Institute's producer for the IRS Form 990 e-file data tier of the NCCS data system.**

This repository turns messy IRS Form 990-series **e-file XML** into clean, versioned, analysis-ready tables published to S3. It is one of several NCCS data "producers" (alongside `nccs-data-bmf` and `nccs-data-core`), and it is the Urban-owned replacement for relying on a third party for e-file data.

> New here? This README is the plain-English overview. For development specifics (commands, conventions, gotchas) see [`CLAUDE.md`](CLAUDE.md); for the "why" behind design choices see [`decisions/`](decisions/) and the cross-repo ADRs in `nccs-contracts`.

## Why this exists

Nonprofits file their 990s electronically, and the IRS publishes them as XML — one verbose, structured file per filing, whose shape changes from year to year. Analysts can't use raw XML; they need columns like *"government grants = $X for this org, this year."*

NCCS historically got this data from a third party (the **Nonprofit Open Data Collective**, NODC). That worked, but the pipeline isn't owned by Urban, isn't versioned, ships no integrity guarantees, and its column names are frozen to the 2009 form layout. This producer brings e-file in-house — versioned, provenance-stamped, quality-checked — and keeps NODC as a **cross-check**, not the authority.

## Status

**Phase 0 is live** and deliberately narrow: two filing-grain fields.

| Field | Source | Form |
|---|---|---|
| `government_grants` | Form 990, Part VIII line 1e | 990 |
| `program_related_investments_total` | Form 990-PF, Summary of PRI (aggregate) | 990-PF |

Scope: forms 990 + 990-PF, tax years 2020–2024. Current vintage **`v2026.06`**.

## How it works

```
GivingTuesday data lake  →  fetch index  →  extract each filing  →  quality gates  →  publish to S3
   (raw 990 XML, free)       (which files)   (pull the values)       (QC, hard-stop)   (parquet + receipt)
```

- **Upstream** is the GivingTuesday data lake — a free, public mirror of every 990 XML, with index files listing what's available. (The IRS's own download page is a documented fallback.)
- **Extraction** opens each filing's XML and pulls specific values by **XPath** (a path into the XML tree, e.g. `/Return/ReturnData/IRS990/GovernmentGrantsAmt`). It runs in parallel across many CPUs.
- **Publication** writes results as **parquet** (compact columnar tables) to a versioned folder, `s3://nccsdata/processed/efile/phase0/{vintage}/`, plus a `latest/` mirror.

Every published vintage ships with three companions: a **data dictionary** (column definitions), a **quality report** (null rates, value ranges), and a **manifest** (a receipt: producer code version, checksums, row counts, exact upstream inputs). The manifest is how downstream consumers trust and trace the data.

## The two-layer concordance

The hard part isn't pulling values — it's *knowing where each value lives in the XML*, which drifts across form years and schema versions. That knowledge is split into two layers:

- **Layer 1 — mechanical inventory.** An auto-generated catalog of **every** element the IRS schemas define, per year/version (XPath, type, whether it holds a value). Exhaustive, never hand-edited, regenerated from the official IRS schemas. *The full dictionary of every word the form can say.*
- **Layer 2 — curated dictionary.** A small, hand-reviewed file mapping friendly NCCS names (`government_grants`) to exact XPaths, with citations to the IRS instructions. *The glossary of the handful of words we actually care about.*

Two layers because the two kinds of knowledge have different owners and change at different rates: Layer 1 is mechanical truth (regenerate on each IRS schema release); Layer 2 is human judgment (grows only when a consumer needs a new field). This split also lets NODC's concordance serve as an automated cross-check against Layer 2.

## Quality gates

A guiding principle here: **a missing value throws no error.** Forget a rule and you don't get a crash — you get a column quietly full of blanks that looks fine until the totals are wrong. (This happened: a hyphen-vs-dot version-key typo nulled two whole tax years in the first release.) So the build runs independent gates, each catching a different silent failure, and **hard-stops** on breach:

- **Schema verification** — every Layer 2 claim must resolve to a real, value-bearing element in the Layer 1 inventory, with a type consistent with the field's declared data type.
- **Claim coverage** — every filing's (year, version) in scope must have a matching rule, or that slice would extract as null invisibly.
- **Value distribution** — published values must fall in sane ranges with expected null rates (min/max checked over the full population, not a sample).
- **Spot-check** — an independent re-extraction of sampled filings must agree with the published value.

## Where it fits in NCCS

NCCS producers are glued together by **contracts**: S3 is the contract surface, and each producer publishes to agreed paths with manifests. The contract spec for this repo lives in `nccs-contracts/contracts/efile.yml`; design decisions live as ADRs in `nccs-contracts/decisions/` (0007, 0017) and this repo's [`decisions/`](decisions/) (0001, 0002). Downstream, `sector-in-brief-data` pins a vintage of this output to build dashboard panels — it does the filtering and aggregation; this repo just ships faithful per-filing values. A CI **contract-change guard** (ADR 0022) makes any PR that changes *what or where* this repo publishes acknowledge the cross-repo impact.

## Roadmap

Growth is **demand-driven**, not "extract everything first":

- **Phase 0** *(done)* — the two fields a dashboard needed; prove the whole pipeline on a thin slice.
- **Phase 0.5** *(in progress)* — own the concordance: build Layer 1, curate Layer 2, demote NODC to a cross-check.
- **Phase 1+** — widen the curated field set (headline 990 → schedules / 990-EZ → 990-PF), one increment at a time, as consumers ask.

## Quickstart

This is an R package. Develop with `pkgload`; see [`CLAUDE.md`](CLAUDE.md) for the full command set and conventions.

```bash
# Run the test suite
Rscript -e 'pkgload::load_all("."); testthat::test_dir("tests/testthat")'

# Run a Phase 0 build locally (default profile); the production profile publishes to S3
Rscript inst/scripts/run_phase0.R
```

S3 access uses the AWS CLI (credentials via IAM role on EC2 or `aws sso login`). License: MIT — note the vendored NODC concordance is ODC-By (attribution required).
