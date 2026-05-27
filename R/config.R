#' Load producer configuration
#'
#' Reads `inst/config.yml` (or an explicit path) and merges the
#' requested profile over the `default` block. Profiles are shallow
#' top-level overrides; nested keys are merged one level deep.
#'
#' @param profile Profile name to overlay on `default`. `NULL` returns
#'   the unmodified default block. ADR 0001 section 4 ships `production` as
#'   the EC2 overlay.
#' @param path Explicit config path. Defaults to the installed
#'   `inst/config.yml`.
#'
#' @return A named list.
#' @export
load_config <- function(profile = NULL, path = NULL) {
  if (is.null(path)) {
    path <- system.file("config.yml", package = "nccs.data.efile")
    if (!nzchar(path)) {
      stop("config.yml not found in installed package")
    }
  }
  raw <- yaml::read_yaml(path)
  cfg <- raw$default %||% list()
  if (!is.null(profile)) {
    overlay <- raw[[profile]]
    if (is.null(overlay)) {
      stop(sprintf("config profile '%s' not found", profile))
    }
    for (k in names(overlay)) {
      if (is.list(cfg[[k]]) && is.list(overlay[[k]])) {
        cfg[[k]] <- utils::modifyList(cfg[[k]], overlay[[k]])
      } else {
        cfg[[k]] <- overlay[[k]]
      }
    }
  }
  cfg
}

#' Null-coalescing operator
#'
#' Returns `a` if non-`NULL`, otherwise `b`. Exported so that the
#' `inst/scripts/` entrypoints can use it after `library(nccs.data.efile)`
#' even on R versions that predate the base `%||%` (introduced in R 4.4).
#'
#' @param a,b Any values; `a` is returned unless it is `NULL`.
#' @return `a` if not `NULL`, otherwise `b`.
#' @name grapes-or-or-grapes
#' @export
`%||%` <- function(a, b) if (is.null(a)) b else a
