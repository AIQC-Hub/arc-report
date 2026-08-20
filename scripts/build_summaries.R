#!/usr/bin/env Rscript
#
# Build the profile-level summary parquet files the site reads, from the
# observation-level parquet produced by `ctddump` + `seastamp`.
#
# The site has always read pre-aggregated summaries (one row per platform x
# profile). The seastamp files are observation-level, so this script is the
# missing layer between them. It replaces the ad-hoc R that produced the old
# summaries.
#
# Idempotent by design: a dataset is skipped when every output already exists and
# is newer than its source. Pass --force to rebuild anyway.
#
# Usage:
#   Rscript scripts/build_summaries.R
#   Rscript scripts/build_summaries.R --force
#   Rscript scripts/build_summaries.R nrt_ar_ar        # one dataset only
#   SEASTAMP_DIR=... SUMMARY_DIR=... Rscript scripts/build_summaries.R
#
suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(data.table)
})

args      <- commandArgs(trailingOnly = TRUE)
force     <- "--force" %in% args
src_dir   <- Sys.getenv("SEASTAMP_DIR", unset = "/scratch/data/aiqc/seastamp/stamped/depth")
out_dir   <- Sys.getenv("SUMMARY_DIR",  unset = "/scratch/data/aiqc/merged")
# Platforms are batched so that roughly this many observation rows are held in
# memory at once. The largest dataset is ~118M rows; collecting it whole would
# need well over 10 GB.
chunk_rows <- as.numeric(Sys.getenv("CHUNK_ROWS", unset = "15000000"))

# Datasets this repo publishes. `out` keeps the historical file naming, so
# _func/common_ar*.Rmd needs no change.
datasets <- list(
  list(src = "nrt_ar_ar", out = "netcdf_nrt_ar_2_summary"),
  list(src = "nrt_ar_gl", out = "netcdf_nrt_ar_gl_2_summary"),
  list(src = "cora_ar",   out = "netcdf_cora_ar_2_summary")
)

vars       <- c("temp", "psal", "pres")   # summarised in the base table
qc_vars    <- c("temp", "psal")           # QC subsets (pressure pages were removed)
qc_subsets <- c(qc1 = 1L, qc4 = 4L)

# IOC QC flags, in the order _func/qc.Rmd's get_flag_def() expects.
FLAGS <- c("0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A")

# seastamp writes an empty string where no QC flag was recorded. In this data a
# blank flag corresponds exactly to a missing value (verified on nrt_ar_ar:
# 14,361 blank flags, 14,361 NA temperatures, and they are the same rows), so it
# is counted as flag 9, "Missing value". Change this one constant if the intended
# reading is 0, "No QC was performed".
BLANK_FLAG <- "9"

# --- aggregation helpers ---------------------------------------------------

# min/max over an all-NA group return -Inf/Inf with a warning; NA is what the
# templates expect and what the old summaries carried.
smin    <- function(x) if (all(is.na(x))) NA_real_ else as.numeric(min(x, na.rm = TRUE))
smax    <- function(x) if (all(is.na(x))) NA_real_ else as.numeric(max(x, na.rm = TRUE))
smean   <- function(x) if (all(is.na(x))) NA_real_ else as.numeric(mean(x, na.rm = TRUE))
smedian <- function(x) if (all(is.na(x))) NA_real_ else as.numeric(median(x, na.rm = TRUE))
# First non-missing value, for the per-profile identity columns.
firstna <- function(x) { i <- which(!is.na(x)); if (length(i)) x[[i[[1L]]]] else x[[1L]] }

# Per-variable statistics, as a fragment of a data.table `j` expression.
stat_code <- function(v, col = v) sprintf(
  "%1$s_count = .N,
   %1$s_na_count = sum(is.na(%2$s)),
   %1$s_non_na_count = sum(!is.na(%2$s)),
   %1$s_mean = smean(%2$s),
   %1$s_median = smedian(%2$s),
   %1$s_min = smin(%2$s),
   %1$s_max = smax(%2$s)", v, col)

# Flag counts, one column per IOC code.
flag_code <- function(v) paste(
  sprintf("%1$s_qc_%2$s = sum(%1$s_flag == %3$dL)", v, FLAGS, seq_along(FLAGS) - 1L),
  collapse = ",\n   ")

identity_code <- "profile_timestamp = profile_timestamp[1L],
   time_qc = time_qc[1L],
   position_qc = position_qc[1L],
   longitude = firstna(longitude),
   latitude = firstna(latitude)"

agg <- function(dt, j) {
  dt[, eval(parse(text = paste0("list(", j, ")"))), by = .(platform_code, profile_no)]
}

# --- per-chunk work --------------------------------------------------------

read_chunk <- function(src, platforms) {
  cols <- c("platform_code", "profile_no", "profile_timestamp", "observation_no",
            "time_qc", "position_qc", "longitude", "latitude",
            "profile_longitude", "profile_latitude",
            vars, paste0(vars, "_qc"))
  dt <- open_dataset(src) |>
    filter(platform_code %in% platforms) |>
    select(all_of(cols)) |>
    collect() |>
    as.data.table()

  # The site's filter chain compares these numerically
  # (`time_qc == 1 & position_qc %in% c(1, -128)`), so they must not stay strings.
  dt[, time_qc := as.integer(time_qc)]
  dt[, position_qc := as.integer(position_qc)]

  # Position comes from the observations, as it always has. seastamp also carries
  # profile_longitude / profile_latitude, but they are unpopulated -- all null
  # across nrt_ar_ar -- so they serve only as a fallback. Preferring them silently
  # produced NaN coordinates, which the location filter then dropped entirely.
  dt[, longitude := fifelse(is.na(longitude), profile_longitude, longitude)]
  dt[, latitude  := fifelse(is.na(latitude),  profile_latitude,  latitude)]
  dt[, c("profile_longitude", "profile_latitude") := NULL]

  # Flags -> 0-based index into FLAGS, so counting is integer comparison.
  for (v in vars) {
    qc <- paste0(v, "_qc")
    dt[, (paste0(v, "_flag")) := {
      x <- get(qc)
      x[is.na(x) | x == ""] <- BLANK_FLAG
      match(x, FLAGS) - 1L
    }]
    dt[, (qc) := NULL]
  }
  dt
}

summarise_chunk <- function(dt) {
  base_j <- paste(c(identity_code, stat_code("observation_no"),
                    unlist(lapply(vars, function(v) paste(stat_code(v), flag_code(v), sep = ",\n   ")))),
                  collapse = ",\n   ")
  out <- list(base = agg(dt, base_j))

  for (v in qc_vars) {
    for (nm in names(qc_subsets)) {
      sub <- dt[get(paste0(v, "_flag")) == qc_subsets[[nm]]]
      key <- paste0(nm, "_", v)
      out[[key]] <- if (nrow(sub) == 0L) NULL else agg(
        sub, paste(identity_code, "observation_no_count = .N", stat_code(v), sep = ",\n   ")
      )
    }
  }
  out
}

# --- driver ----------------------------------------------------------------

outputs_for <- function(d) {
  c(file.path(out_dir, paste0(d$out, ".parquet")),
    as.vector(outer(names(qc_subsets), qc_vars,
                    function(q, v) file.path(out_dir, sprintf("%s_%s_%s.parquet", d$out, q, v)))))
}

build <- function(d) {
  src   <- file.path(src_dir, paste0(d$src, ".parquet"))
  outs  <- outputs_for(d)
  if (!file.exists(src)) stop("missing source: ", src)

  if (!force && all(file.exists(outs)) &&
      min(file.mtime(outs)) > file.mtime(src)) {
    message("== ", d$src, ": up to date, skipping")
    return(invisible(NULL))
  }

  message("== ", d$src)
  ds     <- open_dataset(src)
  counts <- ds |> count(platform_code) |> collect() |> arrange(desc(n))

  # Greedy bin-packing of platforms into chunks: a profile never spans platforms,
  # so any partition by platform is a valid partition of the groups.
  chunks <- list(); cur <- character(); cur_n <- 0
  for (i in seq_len(nrow(counts))) {
    if (cur_n > 0 && cur_n + counts$n[i] > chunk_rows) {
      chunks[[length(chunks) + 1L]] <- cur; cur <- character(); cur_n <- 0
    }
    cur <- c(cur, counts$platform_code[i]); cur_n <- cur_n + counts$n[i]
  }
  if (length(cur)) chunks[[length(chunks) + 1L]] <- cur

  message(sprintf("   %s rows, %d platforms, %d chunk(s)",
                  format(sum(counts$n), big.mark = ","), nrow(counts), length(chunks)))

  acc <- list()
  for (i in seq_along(chunks)) {
    t0 <- Sys.time()
    res <- summarise_chunk(read_chunk(src, chunks[[i]]))
    for (k in names(res)) acc[[k]] <- c(acc[[k]], list(res[[k]]))
    message(sprintf("   chunk %d/%d  %d platforms  %.0fs",
                    i, length(chunks), length(chunks[[i]]),
                    as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  }

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  for (k in names(acc)) {
    df <- rbindlist(acc[[k]])
    setorder(df, platform_code, profile_no)
    # Identity columns first, matching the layout the templates were written against.
    setcolorder(df, c("platform_code", "profile_no", "profile_timestamp",
                      "time_qc", "position_qc", "longitude", "latitude"))
    path <- if (k == "base") file.path(out_dir, paste0(d$out, ".parquet"))
            else file.path(out_dir, sprintf("%s_%s.parquet", d$out, k))
    write_parquet(df, path)
    message(sprintf("   -> %-52s %10s rows  %d cols",
                    basename(path), format(nrow(df), big.mark = ","), ncol(df)))
  }
}

only <- setdiff(args, "--force")
if (length(only) > 0) {
  datasets <- Filter(function(d) d$src %in% only, datasets)
  if (length(datasets) == 0) stop("no dataset matches: ", paste(only, collapse = ", "))
}

for (d in datasets) build(d)
message("done")
