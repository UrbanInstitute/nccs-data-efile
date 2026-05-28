#!/usr/bin/env bash
# Bootstrap an EC2 instance to run the Phase 0 scale build.
#
# Idempotent: safe to re-run on the same instance.
#
# Prerequisites assumed by this script:
#   - Ubuntu 22.04 LTS, fresh launch.
#   - Outbound HTTPS available (apt, CRAN, GitHub, AWS, IRS TEOS).
#   - Running as the `ubuntu` user (default for the AMI).
#
# What this does NOT do:
#   - Configure AWS credentials. We use AWS SSO per session
#     (`aws sso login --profile thiya`); see inst/ops/ec2-scale-run.md.
#   - Launch the run. After bootstrap completes, follow the runbook.
#
# Usage:
#   curl -fsSL <raw-url-of-this-script> | bash
#   - or -
#   git clone https://github.com/UrbanInstitute/nccs-data-efile.git
#   bash nccs-data-efile/inst/ops/bootstrap.sh

set -euo pipefail

REPO_URL="https://github.com/UrbanInstitute/nccs-data-efile.git"
REPO_DIR="${HOME}/nccs-data-efile"

log() { printf "[bootstrap %s] %s\n" "$(date -u +%FT%TZ)" "$*"; }

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
log "apt update + base packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    ca-certificates curl gnupg lsb-release \
    git unzip jq xmlstarlet \
    libxml2-dev libcurl4-openssl-dev libssl-dev \
    libfontconfig1-dev libharfbuzz-dev libfribidi-dev \
    libfreetype6-dev libpng-dev libtiff5-dev libjpeg-dev \
    build-essential

# ---------------------------------------------------------------------------
# CRAN apt repo (Ubuntu 22.04 ships R 4.1, too old for current arrow/xml2).
# ---------------------------------------------------------------------------
if ! command -v R >/dev/null 2>&1 || ! R --version | head -1 | grep -qE 'R version 4\.[3-9]'; then
    log "installing current R from CRAN apt repo"
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
        | sudo gpg --dearmor -o /etc/apt/keyrings/cran.gpg
    echo "deb [signed-by=/etc/apt/keyrings/cran.gpg] https://cloud.r-project.org/bin/linux/ubuntu $(lsb_release -cs)-cran40/" \
        | sudo tee /etc/apt/sources.list.d/cran.list >/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends r-base-dev
fi

# ---------------------------------------------------------------------------
# AWS CLI v2 (Ubuntu's apt awscli is v1, which has broken SSO).
# ---------------------------------------------------------------------------
if ! command -v aws >/dev/null 2>&1 || ! aws --version | grep -q 'aws-cli/2'; then
    log "installing AWS CLI v2"
    tmpdir=$(mktemp -d)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o "${tmpdir}/awscliv2.zip"
    unzip -q "${tmpdir}/awscliv2.zip" -d "${tmpdir}"
    sudo "${tmpdir}/aws/install" --update
    rm -rf "${tmpdir}"
fi

# ---------------------------------------------------------------------------
# s5cmd (coverage-gap fallback: fetches individual XMLs not present in any
# ZIP bundle, far faster than aws s3 cp for many small objects).
# ---------------------------------------------------------------------------
if ! command -v s5cmd >/dev/null 2>&1; then
    log "installing s5cmd"
    tmpdir=$(mktemp -d)
    curl -fsSL "https://github.com/peak/s5cmd/releases/latest/download/s5cmd_Linux-64bit.tar.gz" \
        -o "${tmpdir}/s5cmd.tar.gz"
    tar -xzf "${tmpdir}/s5cmd.tar.gz" -C "${tmpdir}" s5cmd
    sudo install -m 0755 "${tmpdir}/s5cmd" /usr/local/bin/s5cmd
    rm -rf "${tmpdir}"
fi
log "s5cmd: $(s5cmd version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
# Repo
# ---------------------------------------------------------------------------
if [ ! -d "${REPO_DIR}/.git" ]; then
    log "cloning ${REPO_URL} -> ${REPO_DIR}"
    git clone --depth 50 "${REPO_URL}" "${REPO_DIR}"
else
    log "repo present; pulling latest"
    git -C "${REPO_DIR}" pull --ff-only
fi

# ---------------------------------------------------------------------------
# renv restore (the long pole - compiles arrow, xml2, furrr, etc.)
# ---------------------------------------------------------------------------
log "installing renv + restoring lockfile (this takes ~5-10 minutes)"
cd "${REPO_DIR}"
Rscript -e 'if (!requireNamespace("renv", quietly = TRUE)) install.packages("renv", repos = "https://cloud.r-project.org")'
Rscript -e 'renv::restore(prompt = FALSE)'

# ---------------------------------------------------------------------------
# Install the package itself into the renv library so that the entrypoint
# scripts (`library(nccs.data.efile)`) work without pkgload. Use
# renv::install(".") rather than R CMD INSTALL so the install lands in
# the renv-managed library alongside its restored dependencies.
# ---------------------------------------------------------------------------
log "installing nccs.data.efile into the renv library"
Rscript -e 'renv::install(".")'

# ---------------------------------------------------------------------------
# Smoke check
# ---------------------------------------------------------------------------
log "smoke check: package loads"
Rscript -e 'suppressPackageStartupMessages(library(nccs.data.efile)); cat("nccs.data.efile loads OK\n")'

log "bootstrap complete."
log "next steps (see inst/ops/ec2-scale-run.md):"
log "  1. aws configure sso  # one-time per instance, profile name: thiya"
log "  2. aws sso login --profile thiya"
log "  3. Rscript inst/scripts/phase0_verify.R production"
log "  4. Rscript inst/scripts/timed_slice.R production   # go/no-go gate"
log "  5. nohup bash inst/ops/log-sync.sh run-phase0.log & # stream log to S3"
log "  6. nohup Rscript inst/scripts/run_phase0.R production > run-phase0.log 2>&1 &"
