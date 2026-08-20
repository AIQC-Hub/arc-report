# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]
### Added
- `scripts/build_summaries.R` builds the profile-level summary parquet the site reads from the
  observation-level parquet produced by `ctddump` + `seastamp`. Idempotent: a dataset is skipped
  when its outputs already exist and are newer than the source (`--force` to rebuild).
- `scripts/dump_frames.R` fingerprints every data frame the pages load, with per-column digests,
  and `--check` compares against the committed baseline in `tests/fingerprints/`.

### Changed
- Input data now comes from `ctddump` + `seastamp` instead of the R-built summaries published as
  release assets. Figures change accordingly and are not reconciled against the previous site:
  AR 295,156 profiles / 79,134,055 observations, GL 173,481 / 50,392,172,
  CORA 412,867 / 117,998,376.
- The parquet-to-SQLite migration was dropped. SQLite measured ~8x larger than parquet
  (656 MB to 5.2 GB on `nrt_ar_ar`), above GitHub's 2 GiB release-asset limit.
- `ar_cora_summary` now derives its descriptive statistics from the filtered data frame
  (`df_filtered_name`), matching every other summary page. It previously relied on a side
  effect of the removed "Profile level QC flags" section, which reassigned the source frame
  in place. Reported figures are unchanged.

### Removed
- Summary page sections "Profile level QC flags", "Location Filtering", "Duplicate Profiles
  Within Platforms" and "Duplicate Profiles Across Platforms", with their templates
  (`summary_time_location_qc`, `summary_location_filtering2`, `summary_duplicate_*`)
- Pressure pages (`ar_pres`, `ar_gl_pres`, `ar_cora_pres` and their QC counterparts)
- NRT vs CORA pages (`ar_nrt_ar_vs_cora`, `ar_nrt_gl_vs_cora`)
- Orphaned comparison machinery (`_func/comp.Rmd`, `_template/comp_*.Rmd`) and the
  unused `_template/var_distribution.Rmd`

## [0.2.2] - 2025-11-17
### Added
- NRT vs CORA pages

## [0.2.1] - 2025-11-15
### Fixed
- Link to the main repot site

## [0.2.0] - 2025-11-15
### Changed
- Repository name to arc-report

### Added
- Profile-level QC filtering

## [0.1.1] - 2025-11-15
### Added
- Default usage of filtering data frames in all pages
- AIQC logo to menu

## [0.1.0] - 2025-11-14
### Changed
- All common functions copied from bal site

### Added
- Import Arctic Ocean pages form insitu-nrt-report
