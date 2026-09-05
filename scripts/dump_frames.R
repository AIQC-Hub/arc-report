#!/usr/bin/env Rscript
#
# Fingerprint every data frame this site's pages load, so later changes can be
# shown not to have altered what the pages read. The work lives in
# reportlib::fingerprint_frames(); this only names the datasets.
#
# Usage:
#   Rscript scripts/dump_frames.R                 # writes tests/fingerprints/
#   Rscript scripts/dump_frames.R --check         # compares against what is there
#   ARC_DATA_DIR=/path/to/parquet Rscript scripts/dump_frames.R
#
suppressPackageStartupMessages(library(reportlib))

args <- commandArgs(trailingOnly = TRUE)
repo <- normalizePath(file.path(dirname(sub("^--file=", "",
          grep("^--file=", commandArgs(FALSE), value = TRUE)[1])), ".."))
cfg  <- yaml::read_yaml(file.path(repo, "config.yml"))$data

# `vars` lists the variables whose QC subsets a page loads.
ok <- fingerprint_frames(
  datasets = list(
    ar      = list(common = "common_ar.Rmd",      vars = c("temp", "psal", "pres")),
    ar_gl   = list(common = "common_ar_gl.Rmd",   vars = c("temp", "psal", "pres")),
    ar_cora = list(common = "common_ar_cora.Rmd", vars = c("temp", "psal", "pres"))
  ),
  func_dir = file.path(repo, "content", "_func"),
  data_dir = Sys.getenv("ARC_DATA_DIR", unset = cfg$summary_dir),
  out_dir  = file.path(repo, "tests", "fingerprints"),
  check    = "--check" %in% args
)
quit(status = if (isTRUE(ok)) 0L else 1L)
