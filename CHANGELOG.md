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
- A **Source on GitHub** link in the navbar, pointing at this repo.

### Changed
- The shared functions and templates moved to the new **`reportlib`** package. This repo now
  holds only its pages, `_func/common_site.Rmd`, three `_func/common_ar*.Rmd` region files and
  `_quarto.yml`; `_template/` and the five shared `_func/` files are gone. Templates are named at
  the call site — `template_path("var_summary_stats.Rmd")` — instead of through the `t_*` registry.
- The site is now built with **Quarto** instead of Distill. Pages are `.qmd`, `_site.yml` became
  `content/_quarto.yml`, and xaringanExtra panelsets became Quarto `::: {.panel-tabset}`.
  Verified against the pre-port build: every rendered value, figure, table and DataTable payload
  is identical on all 16 pages, and all 16 keep their tab structure.
- `_func/common.Rmd` resolves the data directory once to an absolute path (overridable with
  `ARC_DATA_DIR`). Quarto runs `child=` documents in the page's directory where rmarkdown gave
  them their own, so the previous `rsc_dir` / `rsc_dir2` split no longer worked.
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
- The QC tabs now open on **Good (QC == 1)**, followed by **Bad (QC == 4)** and then
  **All**, so a section leads with the QC-1 data rather than the unfiltered mixture.
  The order lives in `reportlib`; the pin moves to v0.1.3.

### Fixed
- `qc_basic_info`, `summary_basic_info` and `var_basic_info` linked to a literal `parquet_url`
  rather than `{{parquet_url}}`, producing a broken link on every page. Pre-existing.
- The navbar title linked to the AIQC portal instead of this site's home page, so nothing in the
  menu bar led back to the index. Quarto folds the logo and the title into a single brand link,
  which `logo-href` then claimed in full; Distill kept the two apart. The title is now an ordinary
  nav item pointing at `index.qmd`, and the logo keeps the portal link and gains `AIQC` alt text
  (it had none, and the image is white on transparent).

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
