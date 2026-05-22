#' Detect upstream drift in the NODC concordance file
#'
#' Compares the pinned NODC SHA against the current HEAD of the
#' upstream repo's default branch. On drift, downloads both versions,
#' summarizes the row-level diff, and (optionally) opens a GitHub
#' issue against this repo via the `gh` CLI.
#'
#' See ADR 0001 section 8. Intended to be cron-scheduled monthly per
#' nccs-contracts ADR 0004 once the workflow lands.
#'
#' @param pinned_sha SHA currently vendored. Defaults to
#'   `config$vendored$nodc_concordance_sha`.
#' @param config Loaded config list.
#' @param open_issue If `TRUE` and drift is detected, shell out to
#'   `gh issue create`. Requires `gh` authenticated in the current
#'   environment.
#' @param repo `owner/name` for the issue target. Defaults to the
#'   current git remote.
#'
#' @return Invisibly, a list with `drift` (logical), `pinned_sha`,
#'   `head_sha`, and (if drift) a `summary` list with `rows_added`,
#'   `rows_removed`, `rows_changed`, and `sample` (a small data.frame
#'   of changed rows).
#' @export
drift_check_nodc <- function(pinned_sha = NULL,
                             config = load_config(),
                             open_issue = FALSE,
                             repo = NULL) {
  pinned_sha <- pinned_sha %||% config$vendored$nodc_concordance_sha
  if (is.null(pinned_sha) || !nzchar(pinned_sha)) {
    stop("NODC concordance SHA is not pinned (config$vendored$nodc_concordance_sha)")
  }

  head_sha <- nodc_head_sha()
  if (identical(head_sha, pinned_sha)) {
    cli::cli_alert_success("NODC concordance up to date (pinned == HEAD == {substr(head_sha, 1, 12)})")
    return(invisible(list(drift = FALSE, pinned_sha = pinned_sha, head_sha = head_sha)))
  }

  cli::cli_alert_warning(
    "NODC drift: pinned {substr(pinned_sha, 1, 12)} != HEAD {substr(head_sha, 1, 12)}"
  )

  pinned_df <- read_nodc_at(pinned_sha)
  head_df   <- read_nodc_at(head_sha)
  summary   <- summarize_nodc_diff(pinned_df, head_df)

  if (open_issue) {
    open_drift_issue(pinned_sha, head_sha, summary, repo = repo)
  }

  invisible(list(
    drift = TRUE,
    pinned_sha = pinned_sha,
    head_sha = head_sha,
    summary = summary
  ))
}

#' HEAD commit SHA of the NODC concordance repo's default branch.
#' Uses `gh api` to avoid pulling httr.
#' @noRd
nodc_head_sha <- function(repo = "Nonprofit-Open-Data-Collective/irs-efile-master-concordance-file") {
  out <- system2(
    "gh",
    c("api", sprintf("repos/%s/commits/HEAD", repo), "--jq", ".sha"),
    stdout = TRUE, stderr = FALSE
  )
  sha <- trimws(paste(out, collapse = ""))
  if (!nzchar(sha)) stop("failed to resolve NODC HEAD SHA via gh api")
  sha
}

#' Read the NODC concordance.csv at a given SHA into a data.frame.
#' @noRd
read_nodc_at <- function(sha) {
  url <- nodc_raw_url(sha)
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)
  utils::download.file(url, tmp, mode = "wb", quiet = TRUE)
  utils::read.csv(tmp, stringsAsFactors = FALSE, check.names = FALSE)
}

#' Summarize row-level diff between two NODC concordance frames.
#'
#' Identity is `variable_name` if present, else the first column. The
#' summary is intentionally coarse - enough to triage drift, not to
#' replace a full review.
#' @noRd
summarize_nodc_diff <- function(old_df, new_df, max_sample = 20) {
  key <- if ("variable_name" %in% names(old_df)) "variable_name" else names(old_df)[[1]]
  old_keys <- old_df[[key]]
  new_keys <- new_df[[key]]

  added   <- setdiff(new_keys, old_keys)
  removed <- setdiff(old_keys, new_keys)
  shared  <- intersect(old_keys, new_keys)

  old_shared <- old_df[match(shared, old_keys), , drop = FALSE]
  new_shared <- new_df[match(shared, new_keys), , drop = FALSE]
  common_cols <- intersect(names(old_shared), names(new_shared))
  changed_mask <- vapply(
    seq_len(nrow(old_shared)),
    function(i) {
      !identical(
        as.character(unlist(old_shared[i, common_cols])),
        as.character(unlist(new_shared[i, common_cols]))
      )
    },
    logical(1)
  )
  changed_keys <- shared[changed_mask]
  sample <- utils::head(new_df[match(changed_keys, new_keys), , drop = FALSE], max_sample)

  list(
    key = key,
    rows_added = length(added),
    rows_removed = length(removed),
    rows_changed = length(changed_keys),
    added_keys = utils::head(added, max_sample),
    removed_keys = utils::head(removed, max_sample),
    sample = sample
  )
}

#' Open a GitHub issue describing the drift via `gh issue create`.
#' @noRd
open_drift_issue <- function(pinned_sha, head_sha, summary, repo = NULL) {
  title <- sprintf(
    "NODC concordance drift detected (pinned %s -> HEAD %s)",
    substr(pinned_sha, 1, 12), substr(head_sha, 1, 12)
  )
  body <- paste(
    sprintf("Pinned SHA: `%s`", pinned_sha),
    sprintf("HEAD SHA:   `%s`", head_sha),
    "",
    sprintf("- rows added:   %d", summary$rows_added),
    sprintf("- rows removed: %d", summary$rows_removed),
    sprintf("- rows changed: %d", summary$rows_changed),
    "",
    "Triage: review the diff, decide whether to bump",
    "`config$vendored$nodc_concordance_sha` and re-run `vendor_nodc()`.",
    sep = "\n"
  )

  args <- c("issue", "create", "--title", title, "--body", body)
  if (!is.null(repo)) args <- c(args, "--repo", repo)
  status <- system2("gh", args, stdout = FALSE, stderr = FALSE)
  if (!identical(status, 0L)) {
    cli::cli_alert_danger("gh issue create failed (exit {status})")
  } else {
    cli::cli_alert_success("Opened drift issue: {title}")
  }
  invisible(status)
}
