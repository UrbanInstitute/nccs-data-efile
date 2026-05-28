#!/usr/bin/env bash
# Stream a run log to S3 so it survives a blind instance termination or
# the box becoming unreachable under load (RStudio/SSH unresponsive).
#
# The EC2 scale-run uses AWS SSO user creds (no instance IAM role), which
# rules out the CloudWatch Logs agent; this is the robust substitute.
# It uploads the log every INTERVAL seconds to
#   s3://nccsdata/processed/efile/diagnostics/{instance-id}/{logname}
# Idempotent overwrite; cheap (one PUT per interval).
#
# Usage (run in the background alongside the run, see runbook §6):
#   nohup bash inst/ops/log-sync.sh run-phase0-v2026.06.log > log-sync.out 2>&1 &
#   echo $! > log-sync.pid
#
# Args:
#   $1  path to the log file to stream (required)
#   $2  AWS profile (default: thiya)
#   $3  interval seconds (default: 60)

set -euo pipefail

LOG_FILE="${1:?usage: log-sync.sh <log-file> [profile] [interval]}"
PROFILE="${2:-thiya}"
INTERVAL="${3:-60}"
DEST_PREFIX="s3://nccsdata/processed/efile/diagnostics"

# Best-effort instance id (IMDSv2, then v1, then hostname).
token=$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
iid=$(curl -fsS ${token:+-H "X-aws-ec2-metadata-token: $token"} \
    "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || true)
iid="${iid:-$(hostname)}"

dest="${DEST_PREFIX}/${iid}/$(basename "$LOG_FILE")"
echo "[log-sync] streaming ${LOG_FILE} -> ${dest} every ${INTERVAL}s"

while true; do
    if [ -f "$LOG_FILE" ]; then
        aws s3 cp "$LOG_FILE" "$dest" --profile "$PROFILE" >/dev/null 2>&1 \
            || echo "[log-sync] upload failed (will retry): $(date -u +%FT%TZ)"
    fi
    sleep "$INTERVAL"
done
