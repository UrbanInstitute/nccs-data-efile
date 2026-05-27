# EC2 scale-run runbook

How to provision an EC2 instance, build a Phase 0 vintage end-to-end,
and publish it to `s3://nccsdata/processed/efile/phase0/v{YYYY.MM}/`.

This is the replicable companion to [`bootstrap.sh`](bootstrap.sh).
The script handles the deterministic, idempotent setup; the steps
below are the parts that require a human (launch, AWS SSO login,
kicking off the run, verification).

Authentication uses **AWS SSO** with profile name `thiya`, configured
fresh on each instance — no static keys, no instance IAM role.

---

## 1. Prerequisites at Urban

Settle this before launching:

- **AWS account.** `s3://nccsdata` must be reachable by your SSO
  profile `thiya`. Confirm locally: `aws s3 ls s3://nccsdata --profile thiya`
  works from your laptop.

Urban's defaults handle the rest (launch permissions, VPC / subnet,
browser-based instance access).

## 2. Instance specs

| Setting | Value | Notes |
|---|---|---|
| Region | `us-east-1` | Same region as `gt990datalake-rawdata`; intra-region S3 transfer is free + fast |
| Type   | `c5.9xlarge` | 36 vCPU, 72 GB RAM, 10 Gbps network. Bandwidth-sufficient and ~half the cost of c5.18xlarge |
| OS     | Linux | Bootstrap targets Ubuntu 22.04 LTS specifically (apt + CRAN repo + AWS CLI v2 installer); other Debian-family images should work with minimal adjustment |

On-demand pricing in `us-east-1` (May 2026 levels, verify before
launch): c5.9xlarge ≈ $1.53/hr. Run takes 1-2 hours. EBS + S3
requests add cents. **Total cost per vintage: roughly $3-5.**

## 3. Run the bootstrap

Open the instance terminal in the browser, then:

```bash
curl -fsSL https://raw.githubusercontent.com/UrbanInstitute/nccs-data-efile/main/inst/ops/bootstrap.sh \
    | bash 2>&1 | tee bootstrap.log
```

What it does (idempotent — safe to re-run):

1. Installs system deps: `git`, `unzip`, `jq`, `xmlstarlet`,
   `libxml2-dev`, `libcurl4-openssl-dev`, `libssl-dev`, font/image
   libraries, build tools.
2. Installs current R from the CRAN apt repo (Ubuntu 22.04's stock R
   is too old for current `arrow` / `xml2`).
3. Installs AWS CLI v2 (Ubuntu's apt `awscli` is v1, which has
   broken SSO).
4. Clones `UrbanInstitute/nccs-data-efile` to `~/nccs-data-efile`
   if absent; pulls latest if already present.
5. `renv::restore()` against the lockfile.
6. `renv::install(".")` builds and installs the package into the
   renv library.
7. Smoke-checks that the package loads.

Wall-clock: ~5-10 minutes, dominated by `renv::restore()` compiling
`arrow`, `xml2`, `furrr`, etc. from source.

When the bootstrap completes, change into the repo so every
subsequent command runs from inside it:

```bash
cd ~/nccs-data-efile
```

All later sections assume this is your working directory.

## 4. Configure AWS SSO (once per instance)

```bash
aws configure sso
# SSO start URL: <your Urban SSO portal URL>
# SSO region: us-east-1
# Account / role: pick the one with write on s3://nccsdata
# CLI default region: us-east-1
# CLI default output: json
# Profile name: thiya
```

The flow opens a device-code prompt; complete the auth in your
laptop browser.

Refresh credentials any time the SSO session expires (typically
8-12 hours):

```bash
aws sso login --profile thiya
```

Verify:

```bash
aws sts get-caller-identity --profile thiya
aws s3 ls s3://nccsdata/processed/efile/ --profile thiya
```

Both must succeed before continuing.

## 5. Pre-run verification

```bash
# (a) Vendor NODC concordance to s3 - confirms write permission.
Rscript -e 'suppressPackageStartupMessages(library(nccs.data.efile)); vendor_nodc()'

# (b) Fetch all configured XSDs (skips aliased 2024 5.1/5.2 entries).
Rscript inst/scripts/phase0_verify.R production

# (c) Confirm 80/80 checks pass.
jq '.passed, .checks_run' out/phase0_verification_report.json
# Expect: true, 80 (5 claims x 16 (year, version) cells)
```

Failure modes here are blockers — do not proceed past this section
without all three succeeding:

| Failure | Cause | Fix |
|---|---|---|
| (a) AccessDenied | SSO role lacks write on `nccsdata` | Check the permission set assigned to your role in IAM Identity Center |
| (b) HTTP error on TEOS URL | IRS rate-limited or down | Wait 5 min, retry |
| (c) `passed: false` | Alias config not loaded correctly | Check `inst/config.yml` has the `version_aliases` block; re-run |

## 6. Execute the scale run

```bash
nohup Rscript inst/scripts/run_phase0.R production \
    > run-phase0-v2026.05.log 2>&1 &
echo $! > run.pid
```

Monitor in another shell (or in the same one with `Ctrl-C` to stop
tailing; the job keeps running):

```bash
tail -f run-phase0-v2026.05.log
```

Phases you'll see in the log:

1. XSD verification (~30s)
2. GT index fetch — 5 yearly CSVs, ~1 min
3. Extraction in parallel (`extracting in parallel (36 workers)`) —
   the long pole. Expect ~1-1.5 hours for ~700k filings on
   c5.9xlarge in-region.
4. Distribution check (~10s; warns but does not fail because
   `verification.strict: false` for v2026.05)
5. Writing parquets + dictionary + quality (~30s)
6. Manifest emission (~5s)
7. `aws s3 sync` to vintage prefix (~1 min)
8. `aws s3 sync --delete` to `.../latest/` (~30s)

Final log line on success:
`published: s3://nccsdata/processed/efile/phase0/v2026.05/`

If the SSO session expires mid-run, the final `aws s3 sync` step
fails. Refresh with `aws sso login --profile thiya` and re-run only
the publish step (the parquets are already on disk in `out/`).

## 7. Verify the vintage landed

```bash
aws s3 ls s3://nccsdata/processed/efile/phase0/v2026.05/ --profile thiya
# Expect 7 objects: 2 parquets, 2 dictionaries, 2 quality jsons, 1 manifest.

aws s3 cp s3://nccsdata/processed/efile/phase0/v2026.05/_manifest.json - \
    --profile thiya | jq '
        .xsd_verification.passed,
        .xsd_verification.aliases,
        .value_distribution,
        (.files | map({name, row_count}))
    '
```

Sanity-check row counts against the GT index totals: `n_filings(990)
+ n_filings(990PF)` across 2020-2024 should equal `sum(.files[].row_count)`.

## 8. Held-out spot-check

Per ADR 0002 acceptance criterion 5: sample 10 random filings per
form, fetch the source XML again, extract the value via an
independent toolchain (`xmlstarlet`), compare to the parquet.

```bash
Rscript inst/scripts/spot_check_vintage.R \
    s3://nccsdata/processed/efile/phase0/v2026.05/ 10 production
```

Expect `agreement: 20/20`. Anything less than 20/20 is a blocker —
investigate before declaring the vintage shipped. The script writes
a structured report to `out/_spot_check_report_v2026.05.json`.

## 9. Tear down

Once the vintage is verified in S3 *and* the spot-check passes:

```bash
# From your laptop, not the instance:
aws ec2 terminate-instances --instance-ids <instance-id> \
    --region us-east-1 --profile thiya
```

S3 outputs are durable. SSO config will be regenerated next launch.

## 10. Likely failure modes

- **`renv::restore()` fails on `arrow`.** The Arrow R package
  sometimes needs pre-built libarrow. Workaround:
  `Rscript -e 'arrow::install_arrow()'` before re-running
  `renv::restore()`, or set `ARROW_USE_PKG_CONFIG=false` in the env.
- **HTTP 503 from GT bucket during extract.** S3 throttling at high
  concurrency. The current code does not retry per-row. If error
  rate is non-trivial in `_extract_error`, lower
  `production.parallelism.workers` from 72 to 36 or 18 in
  `inst/config.yml` and re-run.
- **Distribution check breaches in soft mode.** Expected on the
  first vintage; this is the calibration data. Read the warning,
  then pin tighter thresholds for v2026.06.
- **`aws s3 sync` ECONNRESET / SSO token expired.** Network blip or
  expired session — refresh SSO and re-run the same `sync` command;
  it is idempotent on objects already uploaded.

## 11. Reuse for subsequent vintages

For v2026.06+, only the vintage label changes through sections 6, 7,
8, and 9. The bootstrap script and SSO config flow are unchanged.
Once thresholds are pinned from v2026.05's manifest, flip
`verification.strict` to `true` in `inst/config.yml`.
