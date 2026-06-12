# EC2 relational-tier run runbook (ADR 0004 step 3)

How to build and publish the **raw relational (scalar) tier** — the per-form
header tables `f990_header`, `f990pf_header`, and the shared `returnheader` —
to `s3://nccsdata/processed/efile/relational/{table}/v{YYYY.MM}/`.

This tier is **best-effort / UNCONTRACTED** (ADR 0004 §4 / nccs-contracts 0028):
XSD-faithful column names, no stability guarantee. It reuses the same EC2 setup,
GT-lake ZIP staging, and parallel parse engine as the Phase 0 run — so most of
this runbook is "see [`ec2-scale-run.md`](ec2-scale-run.md)". Only the build
command and verification differ.

> Scale note: `f990_header` and `f990pf_header` are ~540 value columns each and
> `returnheader` ~70; one parse per filing feeds all of them, so the parse cost
> is the same order as Phase 0 — but the output is far wider. Storage is the new
> variable to watch (ADR 0004 open item 3): scalars compress well under zstd,
> but measure it on the slice.

---

## 1–4. Provision, bootstrap, SSO

Identical to [`ec2-scale-run.md`](ec2-scale-run.md) §1–4: a `c5d.*` (NVMe for
`stage_dir`) in `us-east-1`, run `bootstrap.sh`, `aws configure sso` /
`aws sso login --profile thiya`. Confirm `aws s3 ls s3://nccsdata/processed/efile/ --profile thiya`.

The relational build needs the **Layer 1 inventory**, which it rebuilds from the
local XSD cache — so first fetch the XSDs (same step the Phase 0 runbook uses):

```bash
cd ~/nccs-data-efile
Rscript inst/scripts/phase0_verify.R production   # fetches XSDs (+ 80/80 schema check)
```

## 5. Slice gate — DO NOT SKIP

Measure throughput and output width on **this** instance before the full run.
`MAX_ZIPS=2` processes two ZIP bundles, then stops after the (partial) build so
you can read the per-ZIP ETA heartbeat and the written table shapes.

```bash
STAGE_DIR=/mnt/stage MAX_ZIPS=2 Rscript inst/scripts/run_relational.R production \
    2>&1 | tee slice-relational.log
```

Sanity-check before committing hours:
- The per-ZIP heartbeat (`[zip k/N ... ETA Ns]`) projects the full run; if it's
  wildly long, reconsider `parallelism.workers` / instance size.
- Inspect a written table: `du -sh out/relational/*/` and the column counts in
  each `out/relational/*/<table>/_manifest.json` — confirm storage per ZIP is
  sane before scaling to all ~97.
- With `MAX_ZIPS` set, `s3_enabled` still publishes; if you do NOT want the slice
  on S3, run the slice with the `default` profile (no publish) and read locally.

## 6. Execute the full run

Start the off-instance log streamer (see Phase 0 runbook §6), then:

```bash
STAGE_DIR=/mnt/stage nohup Rscript inst/scripts/run_relational.R production \
    > run-relational-v2026.06.log 2>&1 &
echo $! > run.pid
```

Phases in the log:
1. Layer 1 inventory build (~1–2 min from the XSD cache).
2. GT index fetch (~1 min).
3. **ZIP-bulk extraction** — the long pole. One heartbeat per ZIP. Each ZIP is
   checkpointed as one parquet **per table** under the checkpoint dir
   (`_checkpoints/<vintage>/<zip>__<table>.parquet`).
4. Coverage fallback via `s5cmd` for any in-scope ids absent from all ZIPs.
5. Write each table: partitioned by `tax_year`, `_dictionary.csv`, `_TIER.txt`
   (best-effort marker), `_manifest.json`; then `aws s3 sync` each table dir to
   `relational/{table}/{vintage}/` and `.../latest/`.

Final lines on success: `published: s3://nccsdata/processed/efile/relational/<table>/v{vintage}/` (one per table).

**Resume after a kill / crash / SSO expiry:** re-launch the same command.
Per-(ZIP, table) checkpoints are detected and skipped; only remaining ZIPs run.
If only the final `aws s3 sync` failed, refresh `aws sso login --profile thiya`
and re-run — extraction is already checkpointed.

`STAGE_DIR`/`CHECKPOINT_DIR` relocate scratch off a small or NVMe-less volume
(e.g. a containerized RStudio box with a single large EBS disk: `STAGE_DIR=~/stage`).

## 7. Verify the tier landed

```bash
for t in returnheader f990_header f990pf_header; do
  echo "== $t =="
  aws s3 ls s3://nccsdata/processed/efile/relational/$t/v2026.06/ --profile thiya
  aws s3 cp s3://nccsdata/processed/efile/relational/$t/v2026.06/_manifest.json - \
      --profile thiya | jq '{row_count, column_count, value_column_count, best_effort, rows_per_tax_year}'
done
```

Sanity-check `row_count` against the GT index totals: `returnheader` row count
should ≈ `n_filings(990) + n_filings(990PF)`; each body table ≈ its form's count.

## 8. Acceptance (ADR 0004 step 4)

1. **Cross-check vs the contracted path** — the migration criterion in miniature:
   `f990_header.GovernmentGrantsAmt` must equal `phase0/government_grants`
   filing-for-filing, and the PRI equivalent, joined on `filing_receipt_id`.
   (Validated 25/25 on a dev sample in the step-2 PR; confirm at scale.)
2. **Held-out spot-check** vs source XML on a sample of columns/filings
   (independent `xmlstarlet` re-extraction).
3. Confirm the grandfathered `phase0/` outputs are byte-for-byte **unaffected**
   (this run never touches them).

## 9. Tear down

Same as Phase 0 runbook §9 — terminate the instance once verified; S3 is durable.
