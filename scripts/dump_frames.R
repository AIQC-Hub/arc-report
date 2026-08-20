#!/usr/bin/env Rscript
#
# Phase 0 baseline harness (see .claude/docs/migration-plan.md).
#
# Fingerprints every data frame the site reads, so later phases can prove they did
# not change what the pages see. The data layer is frozen (parquet stays), so these
# fingerprints must remain identical through the Quarto port and the package
# extraction. Any drift means a page started reading different data -- the failure
# mode that is hardest to spot by eye in rendered HTML.
#
# It deliberately loads the *real* `_func/*.Rmd` sources via knitr::purl() instead of
# reimplementing the filter chain. A reimplementation would drift silently and end up
# validating itself rather than the site.
#
# Usage:
#   Rscript scripts/dump_frames.R                 # writes tests/fingerprints/
#   Rscript scripts/dump_frames.R --check         # compares against what is there
#   ARC_DATA_DIR=/path/to/parquet Rscript scripts/dump_frames.R
#
suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(digest)
  library(jsonlite)
})

args     <- commandArgs(trailingOnly = TRUE)
check    <- "--check" %in% args
repo     <- normalizePath(file.path(dirname(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), ".."))
func_dir <- file.path(repo, "content", "_func")
data_dir <- normalizePath(Sys.getenv("ARC_DATA_DIR", unset = file.path(repo, "data")), mustWork = TRUE)
out_dir  <- file.path(repo, "tests", "fingerprints")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Datasets, keyed by the `_func/common_*.Rmd` that defines them. `vars` lists the
# variables whose QC subsets are still loaded by a page; `pres` is absent because
# Phase 1 removed the pressure pages.
datasets <- list(
  ar      = list(common = "common_ar.Rmd",      vars = c("temp", "psal")),
  ar_gl   = list(common = "common_ar_gl.Rmd",   vars = c("temp", "psal")),
  ar_cora = list(common = "common_ar_cora.Rmd", vars = c("temp", "psal"))
)

# --- helpers ---------------------------------------------------------------

# Source an .Rmd's code chunks into `env`, exactly as knitr would run them.
source_rmd <- function(rmd, env) {
  r <- tempfile(fileext = ".R")
  on.exit(unlink(r), add = TRUE)
  knitr::purl(file.path(func_dir, rmd), output = r, documentation = 0L, quiet = TRUE)
  sys.source(r, envir = env, keep.source = FALSE)
  invisible(env)
}

# Per-column digests, so a diff names the column that moved rather than just
# reporting that something did. The frame digest is derived from them, which also
# sidesteps data.frame attribute noise (tibble vs data.frame, row names).
fingerprint <- function(df) {
  df  <- as.data.frame(df)
  key <- intersect(c("platform_code", "profile_no"), names(df))
  if (length(key) > 0) df <- df[do.call(order, unname(as.list(df[key]))), , drop = FALSE]
  rownames(df) <- NULL

  col_digest <- vapply(names(df), function(n) digest(df[[n]], algo = "xxhash64"), character(1))
  cols <- lapply(names(df), function(n) {
    list(name = n, type = class(df[[n]])[1], digest = unname(col_digest[[n]]))
  })

  # Figures that appear on the rendered pages, so a diff is human-readable before
  # anyone reaches for the hashes.
  stats <- list(rows = nrow(df))
  if ("platform_code" %in% names(df)) stats$platforms <- n_distinct(df$platform_code)
  if (all(c("platform_code", "profile_no") %in% names(df))) {
    stats$profiles <- nrow(distinct(df, platform_code, profile_no))
  }
  obs <- grep("^observation_no_count$", names(df), value = TRUE)
  if (length(obs) == 1) stats$observations <- sum(df[[obs]], na.rm = TRUE)

  list(
    digest  = digest(paste(names(df), col_digest, collapse = "|"), algo = "xxhash64"),
    stats   = stats,
    ncol    = ncol(df),
    columns = cols
  )
}

# --- build the frames ------------------------------------------------------

collect <- function(id, spec) {
  env <- new.env(parent = globalenv())
  # common.Rmd probes upwards for the data directory relative to its working
  # directory; this script runs from the repo root, so name it outright.
  Sys.setenv(ARC_DATA_DIR = data_dir)
  source_rmd("common.Rmd", env)
  source_rmd(spec$common, env)   # defines the constants and loads the base frame

  out <- list()
  df  <- get(env$df_name, envir = env)
  out[[env$df_name]] <- fingerprint(df)

  # The standard chain, as _template/location_filtering.Rmd applies it.
  filtered <- df |>
    env$filter_profile_level_qc() |>
    env$filer_locations() |>
    env$exclude_locations()
  out[[env$df_filtered_name]] <- fingerprint(filtered)

  for (var in spec$vars) {
    for (qc in c("qc1", "qc4")) {
      # Same gsub() as _template/load_qc_summary.Rmd, kept verbatim so the harness
      # reproduces production's filename construction rather than a tidied version.
      stem <- get(paste0("parquet_", qc), envir = env)
      f    <- file.path(data_dir, gsub(".parquet", paste0("_", var, ".parquet"), stem))
      qdf  <- read_parquet(f)

      base <- paste0(env$df_name, "_", qc, "_", var)
      out[[base]] <- fingerprint(qdf)
      out[[paste0(base, "_filtered")]] <- fingerprint(
        qdf |> env$filter_profile_level_qc() |> env$filer_locations() |> env$exclude_locations()
      )
    }
  }
  out
}

# --- run -------------------------------------------------------------------

status <- 0L
for (id in names(datasets)) {
  message("== ", id)
  fp   <- collect(id, datasets[[id]])
  path <- file.path(out_dir, paste0(id, ".json"))
  json <- toJSON(fp, auto_unbox = TRUE, pretty = TRUE, digits = NA)

  for (nm in names(fp)) {
    s <- fp[[nm]]$stats
    message(sprintf("   %-32s %10s rows  %s", nm, format(s$rows, big.mark = ","), fp[[nm]]$digest))
  }

  if (check) {
    if (!file.exists(path)) {
      message("   MISSING baseline: ", path); status <- 1L
    } else if (identical(readLines(path, warn = FALSE), strsplit(json, "\n")[[1]])) {
      message("   OK -- matches baseline")
    } else {
      message("   DRIFT vs baseline: ", path); status <- 1L
    }
  } else {
    writeLines(json, path)
  }
}

# Environment recorded separately: it is useful context but would otherwise make
# every frame file diff whenever a package is upgraded.
if (!check) {
  writeLines(toJSON(list(
    generated  = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    git_commit = tryCatch(system2("git", c("-C", repo, "rev-parse", "HEAD"), stdout = TRUE), error = function(e) NA),
    R          = paste(R.version$major, R.version$minor, sep = "."),
    arrow      = as.character(packageVersion("arrow")),
    dplyr      = as.character(packageVersion("dplyr")),
    data_dir   = data_dir
  ), auto_unbox = TRUE, pretty = TRUE), file.path(out_dir, "_env.json"))
}

quit(status = status)
