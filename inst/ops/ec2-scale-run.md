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

Settle these before launching:

- **AWS account.** `s3://nccsdata` must be reachable by your SSO
  profile `thiya`. Confirm locally: `aws s3 ls s3://nccsdata --profile thiya`
  works from your laptop.
- **EC2 launch permission.** Your SSO role needs `ec2:RunInstances` and
  `ec2:TerminateInstances` in `us-east-1`.
- **Key pair.** Have an SSH key pair registered in `us-east-1`, or
  create one in the launch flow.
- **VPC / subnet.** The default VPC's default subnet in `us-east-1`
  is fine.

## 2. Instance specs

| Setting | Value | Notes |
|---|---|---|
| Region | `us-east-1` | Same region as `gt990datalake-rawdata`; intra-region S3 transfer is free + fast |
| Type | `c5.9xlarge` | 36 vCPU, 72 GB RAM, 10 Gbps network. Bandwidth-sufficient and ~half the cost of c5.18xlarge |
| AMI | Ubuntu 22.04 LTS (`Canonical, Ubuntu, 22.04 LTS, amd64`) | R packages are cleanest on Debian-family |
| EBS root | 100 GB gp3 | Holds GT index cache, XSD cache, parquet outputs before sync |
| Public IP | yes | Needed for apt, CRAN, GitHub, AWS, IRS TEOS |
| Security group | inbound 22 from your IP only; outbound: default (all) | |
| IAM instance profile | **none** | We use SSO from the instance, not a role |

On-demand pricing in `us-east-1` (May 2026 levels, verify before
launch): c5.9xlarge ≈ $1.53/hr. Run takes 1-2 hours. EBS + S3
requests add cents. **Total cost per vintage: roughly $3-5.**

## 3. Launch + SSH in

```bash
ssh -i ~/.ssh/<your-key>.pem ubuntu@<instance-public-dns>
```

Verify the box is what you expect:

```bash
lsb_release -d                            # Ubuntu 22.04
uname -m                                  # x86_64
df -h /                                   # plenty of space on / 
```

## 4. Run the bootstrap

```bash
curl -fsSL https://raw.githubusercontent.com/UrbanInstitute/nccs-data-efile/main/inst/ops/bootstrap.sh \
    | bash 2>&1 | tee bootstrap.log
```

Or, if you'd rather clone-first then run:

```bash
git clone https://github.com/UrbanInstitute/nccs-data-efile.git
bash nccs-data-efile/inst/ops/bootstrap.sh 2>&1 | tee bootstrap.log
```

What it does (idempotent):

1. Installs system deps: `git`, `unzip`, `jq`, `xmlstarlet`,
   `libxml2-dev`, `libcurl4-openssl-dev`, `libssl-dev`, font/image
   libraries, build tools.
2. Installs current R from the CRAN apt repo (Ubuntu 22.04's stock R
   is too old for current `arrow` / `xml2`).
3. Installs AWS CLI v2 (Ubuntu's apt `awscli` is v1, which has
   broken SSO).
4. Clones `UrbanInstitute/nccs-data-efile` to `~/nccs-data-efile`.
5. `renv::restore()` against the lockfile.
6. Smoke-checks that the package loads.

Wall-clock: ~5-10 minutes, dominated by the `renv::restore()` step
which compiles `arrow`, `xml2`, `furrr`, etc. from source.

## 5. Configure AWS SSO (once per instance)

```bash
aws configure sso
# SSO start URL: <your Urban SSO portal URL>
# SSO region: us-east-1
# Account / role: pick the one with write on s3://nccsdata
# CLI default region: us-east-1
# CLI default output: json
# Profile name: thiya
```

The flow opens a device-code prompt. Since the instance has no
browser, copy the URL + code it prints and complete the auth in
your laptop browser.

After config is written to `~/.aws/config`, refresh credentials any
time the SSO session expires (typically 8-12 hours):

```bash
aws sso login --profile thiya
```

Verify:

```bash
aws sts get-caller-identity --profile thiya
aws s3 ls s3://nccsdata/processed/efile/ --profile thiya
```

Both must succeed before continuing.

## 6. Pre-run verification

```bash
cd ~/nccs-data-efile

# (a) Vendor NODC concordance to s3 - confirms write permission.
Rscript -e 'suppressPackageStartupMessages(library(nccs.data.efile)); vendor_nodc_concordance()'

# (b) Fetch all configured XSDs (skips aliased 2024 5.1/5.2 entries).
Rscript inst/scripts/phase0_verify.R production

# (c) Confirm 32/32 cells pass.
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

## 7. Execute the scale run

```bash
nohup Rscript inst/scripts/run_phase0.R production \
    > run-phase0-v2026.05.log 2>&1 &
echo $! > run.pid
```

Monitor in another shell:

```bash
tail -f ~/nccs-data-efile/run-phase0-v2026.05.log
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

## 8. Verify the vintage landed

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

Sanity-check row counts against the GT index totals you scanned during
preflight: `n_filings(990) + n_filings(990PF)` across 2020-2024 should
equal `sum(.files[].row_count)`.

## 9. Held-out spot-check

Per ADR 0002 acceptance criterion 5: sample 10 random filings per
form from the published vintage, fetch the source XML again, extract
the value via an independent path (`xmlstarlet`), compare to the
parquet. See the separate spot-check script — task #8.

## 10. Tear down

Once the vintage is verified in S3 *and* the spot-check passes:

```bash
# From your laptop, not the instance:
aws ec2 terminate-instances --instance-ids <instance-id> \
    --region us-east-1 --profile thiya
```

EBS goes with the instance (root volume `DeleteOnTermination=true`
by default). S3 outputs are durable. SSO config will be regenerated
next launch.

## 11. Likely failure modes

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

## 12. Reuse for subsequent vintages

For v2026.06+, only steps 3, 5, 7, 8, 10 change (vintage label
substitutes through). The bootstrap script and SSO config flow are
unchanged. Once thresholds are pinned from v2026.05's manifest, flip
`verification.strict` to `true` in `inst/config.yml`.
