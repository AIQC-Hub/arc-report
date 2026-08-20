#!/usr/bin/env Rscript
#
# Build this site's profile-level summary parquet from the seastamp
# observation-level files. The work lives in reportlib::build_summaries();
# this only names the datasets.
#
# Paths come from config.yml at the repo root.
#
# Usage:
#   Rscript scripts/build_summaries.R
#   Rscript scripts/build_summaries.R --force
#   Rscript scripts/build_summaries.R nrt_ar_ar        # one dataset only
#   SEASTAMP_DIR=... SUMMARY_DIR=... Rscript scripts/build_summaries.R
#
suppressPackageStartupMessages(library(reportlib))

args <- commandArgs(trailingOnly = TRUE)
repo <- normalizePath(file.path(dirname(sub("^--file=", "",
          grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), ".."))
cfg  <- yaml::read_yaml(file.path(repo, "config.yml"))$data

# `out` keeps the historical file naming, so _func/common_ar*.Rmd needs no change.
build_summaries(
  datasets = list(
    list(src = "nrt_ar_ar", out = "netcdf_nrt_ar_2_summary"),
    list(src = "nrt_ar_gl", out = "netcdf_nrt_ar_gl_2_summary"),
    list(src = "cora_ar",   out = "netcdf_cora_ar_2_summary")
  ),
  src_dir    = Sys.getenv("SEASTAMP_DIR", unset = cfg$seastamp_dir),
  out_dir    = Sys.getenv("SUMMARY_DIR",  unset = cfg$summary_dir),
  chunk_rows = as.numeric(Sys.getenv("CHUNK_ROWS", unset = "15000000")),
  force      = "--force" %in% args,
  only       = setdiff(args, "--force")
)
message("done")
