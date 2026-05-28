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

Staging changed in v2: instead of ~1.96M per-filing HTTP downloads, we
bulk-download the GT lake's `EfileData/XmlZips/` bundles (one ZIP at a
time, ~31 GB total compressed across ~97 files), unzip locally, and parse
from disk. The bottleneck is therefore **XML parse CPU + local disk
I/O**, not per-file network latency. Pick the vCPU count from the timed
slice (§5b), not a guess.

| Setting | Value | Notes |
|---|---|---|
| Region | `us-east-1` | Same region as `gt990datalake-rawdata`; intra-region S3 transfer is free + fast |
| Type   | `c5d.9xlarge` (or larger `c5d.*`) | The `d` variants have **instance-store NVMe** — ideal for the ephemeral `staging.stage_dir` (fast, free, dies with the instance, which is fine). On a plain `c5.*` you must point `stage_dir` at a gp3 EBS volume with raised IOPS, or unzip-to-disk will be I/O-bound. |
| OS     | Linux | Bootstrap targets Ubuntu 22.04 LTS specifically; other Debian-family images should work with minimal adjustment |

If using a `c5d.*`, mount the NVMe and set `staging.stage_dir` to it
(e.g. `/mnt/stage`) before the run:

```bash
sudo mkfs -t xfs /dev/nvme1n1 && sudo mkdir -p /mnt/stage \
  && sudo mount /dev/nvme1n1 /mnt/stage && sudo chown ubuntu:ubuntu /mnt/stage
```

On-demand pricing in `us-east-1` (verify before launch): c5d.9xlarge
≈ $1.73/hr. **Do not guess the run time — the timed slice (§5b) measures
it.** EBS + S3 requests add cents.

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

### 5b. Timed-slice gate (DO NOT SKIP)

Measure real throughput on **this** instance before committing to a
multi-hour run. Processes a couple of ZIPs and projects the full-run
time and cost.

```bash
HOURLY_USD=1.73 SLICE_ZIPS=2 Rscript inst/scripts/timed_slice.R production
```

Read the `throughput` and both projection lines. Sanity-check:

- If the projected full run is wildly longer than expected, stop and
  reconsider instance size / `parallelism.workers` before burning hours.
- A high `extract error rate` (> a few %) means many XMLs failed to
  parse — investigate before the full run.

This is also the first real read on the ZIP-coverage assumption (the
fallback is disabled in the slice; full coverage is measured by §6).

## 6. Execute the scale run

Start the off-instance log streamer first, so the log survives even if
the box becomes unreachable under load or is terminated blind:

```bash
nohup bash inst/ops/log-sync.sh run-phase0-v2026.06.log > log-sync.out 2>&1 &
echo $! > log-sync.pid

nohup Rscript inst/scripts/run_phase0.R production \
    > run-phase0-v2026.06.log 2>&1 &
echo $! > run.pid
```

The log is mirrored every 60s to
`s3://nccsdata/processed/efile/diagnostics/{instance-id}/`. Monitor
locally with `tail -f run-phase0-v2026.06.log`, or from your laptop:

```bash
aws s3 cp s3://nccsdata/processed/efile/diagnostics/<instance-id>/run-phase0-v2026.06.log - --profile thiya | tail -40
```

Phases you'll see in the log:

1. XSD verification (~30s)
2. GT index fetch — yearly CSVs, ~1 min
3. **ZIP-bulk extraction** — the long pole. One heartbeat line per ZIP:
   `[zip k/N {name} - {matched} in-scope rows, {elapsed}s, ETA {n}s]`.
   Completed ZIPs are checkpointed to `out/{vintage}/_chunks/`.
4. Coverage fallback (if any in-scope ids were absent from all ZIPs):
   `! N in-scope filings absent from ZIPs; fetching individually via s5cmd`
5. Distribution check (~10s; warns, does not fail, while
   `verification.strict: false`)
6. Writing parquets + dictionary + quality, manifest, `aws s3 sync` to
   the vintage prefix and `.../latest/`.

Final log line on success: `published: s3://nccsdata/processed/efile/phase0/v{vintage}/`

**Resume after a kill/crash/SSO-expiry mid-run:** just re-launch the same
`run_phase0.R` command. Completed-ZIP chunks in `_chunks/` are detected
and skipped; only the remaining ZIPs are processed. If only the final
`aws s3 sync` failed (e.g. SSO expired), refresh
`aws sso login --profile thiya` and re-run — extraction is already
checkpointed, so it fast-forwards to the publish step.

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
- **Disk fills during extract.** Staging unzips one ZIP at a time and
  deletes it before the next, so peak use is ~one ZIP unzipped (~2 GB).
  If `staging.stage_dir` points at a small root volume, set it to the
  NVMe mount (`/mnt/stage`) or a larger EBS volume.
- **ZIP coverage gap.** In-scope `object_id`s absent from every ZIP are
  fetched individually by the s5cmd fallback (`_fallback.parquet`). A
  large gap (logged count) means the `zip_release_year_floor` is too high
  — lower it in `inst/config.yml` so more release-year ZIPs are pulled.
- **s5cmd not found.** The fallback needs `s5cmd` on PATH (installed by
  `bootstrap.sh`). Re-run the bootstrap if missing.
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
