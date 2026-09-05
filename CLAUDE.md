# arc-report

**Quarto** website publishing CTD (temperature, salinity, pressure) data-summary reports for the
**Arctic Ocean** in situ observations. Built to GitHub Pages at
<https://aiqc-hub.github.io/arc-report/>. Pages are `.qmd` on the knitr engine.

**The shared machinery lives in the [`reportlib`](https://github.com/AIQC-Hub/reportlib)
package**, not here — every function and every `{{placeholder}}` template is packaged and shared
with `bal-report` / `med-report`. This repo keeps only what is genuinely local: its pages, its
region constants in `_func/common_*.Rmd`, and `_quarto.yml`. Fix shared behaviour in the package,
not by re-adding a `_func/` file.

Three datasets, each rendered as its own set of pages:

| Code   | Source                                              | Common file            |
|--------|-----------------------------------------------------|------------------------|
| `AR`   | CMEMS NRT Arctic (`cmems_obs-ins_arc_phybgcwav_mynrt_na_irr`) | `_func/common_ar.Rmd`      |
| `GL`   | Same product, GL subset                             | `_func/common_ar_gl.Rmd`   |
| `CORA` | CMEMS delayed-mode CORA (`cmems_obs-ins_glo_phy-temp-sal_my_cora_irr`) | `_func/common_ar_cora.Rmd` |

## Layout

```
content/            # Quarto project root
  _quarto.yml       # project type, navbar, output-dir: docs, shared html format
  index.qmd         # landing page
  ar[_gl|_cora]_{summary,temp,psal,temp_qc,psal_qc}.qmd     # 15 pages + index
  _func/            # knitr children, all local:
    common_site.Rmd   #   repo constants: release_url, rsc_dir
    common_ar.Rmd     #   per-dataset constants; loads the parquet into df_*
    common_ar_gl.Rmd
    common_ar_cora.Rmd
  docs/             # BUILD OUTPUT — generated, git-ignored, do not hand-edit
data -> /scratch/data/aiqc/merged   # symlink; parquet inputs (git-ignored)
scripts/            # build_summaries.R (data), dump_frames.R (fingerprints)
tests/fingerprints/ # committed baseline; tests/baseline-docs/ is git-ignored
```

`_func` is underscore-prefixed, so Quarto's project scan ignores it — which is what we want, those
are children rather than pages.

## How a page is built

Every page follows the same three-layer pattern — read one page (e.g. `content/ar_temp.qmd`)
and the pattern generalises to all of them.

1. **Page `.qmd`** — YAML front matter (title and description only; `format` is shared in
   `_quarto.yml`), then a chunk calling `library(reportlib)` and setting `r_funcs` and the page
   variables (`var`, `var_name`, `var_label`, `qc_var`, …).
2. **`_func/` children** — pulled in via `child=file.path(r_func_path, r_funcs)`. Order matters:
   `common_site.Rmd` (repo constants) → one `common_ar*.Rmd` (dataset constants, loads the parquet
   into `df_*`). Everything else comes from the package.
3. **Packaged templates** — expanded and knitted per section, named directly rather than through a
   registry:
   ```r
   src <- knitr::knit_expand(template_path("var_summary_stats.Rmd"),
                             df = df_filtered_name, var = var)
   res <- knitr::knit_child(text = src, quiet = TRUE)
   cat(res, sep = '\n')          # chunk needs results = 'asis'
   ```
   Templates use `{{placeholder}}`, resolved by `knit_expand` **in the page's environment** — which
   is why `common_site.Rmd` must define `rsc_dir2` and the region file `parquet_qc1` etc. Data
   frames are passed **by name (string)**, not by value.

**Working directory (measured, not assumed).** Under Quarto all three contexts share the same
working directory, `content/`:

| Code lives in | Effective wd under Quarto | (was, under rmarkdown) |
|---------------|---------------------------|------------------------|
| a page `.qmd` | `content/` | `content/` |
| `_func/*.Rmd` (loaded via `child=`) | `content/` | `content/_func/` |
| a packaged template (via `knit_expand` + `knit_child(text=)`) | `content/` | `content/` |

The middle row changed with the port: rmarkdown gave a `child=` document its own directory,
Quarto does not. The package's `aiqc_data_dir()` therefore resolves the data directory **once to an
absolute path**, probing `../data` then `../../data` for a directory containing parquet files
(`ARC_DATA_DIR` overrides). `_func/common_site.Rmd` assigns it to both `rsc_dir` and `rsc_dir2`;
both names are kept because the templates refer to `rsc_dir2`. Do not replace either with a bare
relative path — that is what broke on the Quarto port.

Other conventions: pages end with `rm(list = ls())`; tabbed sections use Quarto tabsets
(`::: {.panel-tabset}` with one heading per tab); chunk labels must be unique per page.

## Data model

Two layers. The site reads only the second.

**Source (observation-level).** `ctddump` + `seastamp` write one parquet per region to
`/scratch/data/aiqc/seastamp/stamped/depth/{nrt_ar_ar,nrt_ar_gl,cora_ar}.parquet` — one row per
observation (247M rows across the three Arctic datasets), 25 columns: `platform_code`,
`profile_no`, `observation_no`, `profile_timestamp`, `longitude`, `latitude`, `{pres,temp,psal,deph}`
and their `_qc` flags, plus `is_dup`, `dist_to_coast`, `bathymetry`. **No page reads these.**

Three traps in this layer, all handled by `scripts/build_summaries.R`:
`time_qc`/`position_qc`/`{var}_qc` are **strings** (`"1"`, `"4"`, `""`), where the filter chain
compares numerically; a **blank** flag means a missing value (blank ⟺ NA, verified 1:1) and is
counted as flag 9; and `profile_longitude`/`profile_latitude` are **entirely null** — position
comes from the observation-level `longitude`/`latitude`.

**Site input (profile-level).** `scripts/build_summaries.R` aggregates the above into pre-aggregated
summaries (one row per platform × profile). Idempotent: it skips a dataset whose outputs already
exist and are newer than the source; `--force` overrides.

- `netcdf_<src>_2_summary.parquet` — all variables. Key columns: `platform_code`, `profile_no`,
  `profile_timestamp`, `time_qc`, `position_qc`, `longitude`, `latitude`,
  `observation_no_*`, and per-variable `{pres,temp,psal}_{count,na_count,non_na_count,mean,median,min,max}`
  plus flag counts `{var}_qc_{0..9,A}`.
- `netcdf_<src>_2_summary_qc{1,4}_{temp,psal}.parquet` — 15 columns: the identity columns,
  `observation_no_count` and that variable's seven statistics, computed over only its QC 1 / QC 4
  observations. Loaded lazily by `_template/load_qc_summary.Rmd`. (No `pres` subsets — the
  pressure pages are gone.)

Standard filtering chain applied on every page (`_template/location_filtering.Rmd`):
`filter_profile_level_qc()` (time_qc == 1, position_qc ∈ {1, -128}) → `filer_locations()` →
`exclude_locations()`. The last two are defined per dataset in `_func/common_ar*.Rmd`
(note: `filer_` is an existing typo — keep it consistent unless renaming everywhere).

## Build & deploy

```bash
./build.sh                                         # what RStudio's Build pane runs
Rscript scripts/build_summaries.R                  # obs-level -> profile summaries (skips if current)
Rscript scripts/dump_frames.R                      # fingerprint every frame the pages read
Rscript scripts/dump_frames.R --check              # ... and compare against the committed baseline
quarto render content                              # whole site -> content/docs
quarto render content/ar_temp.qmd                  # single page while iterating (slow otherwise)
quarto preview content                             # live preview
```

**RStudio's Build pane.** `.Rproj` uses `BuildType: Custom` pointing at `build.sh`, not
`BuildType: Website`. RStudio only recognises a Quarto project when `_quarto.yml` sits beside the
`.Rproj`; ours is in `content/`, so RStudio would fall back to `rmarkdown::render_site()` and fail
with *"No site generator found"*. Moving `_quarto.yml` to the repo root is not the fix either —
Quarto lays output out relative to the project root, so pages would land in `content/docs/content/`.

### Dependencies

This repo declares three: `reportlib`, `rmarkdown`, `yaml` (`DESCRIPTION`). Everything else —
arrow, tidyverse, data.table, DT, kableExtra, `maps`, `hexbin` and the rest, 19 direct and ~156
transitively — belongs to `reportlib` and is declared there. There is no second list here to keep
in step.

```r
install.packages(c("rmarkdown", "yaml"))
remotes::install_github("AIQC-Hub/reportlib@v0.1.4")   # resolves reportlib's own deps
```

`R CMD INSTALL` from a checkout does **not** resolve dependencies — it stops at the first missing
one (`dependency 'maps' is not available for package 'reportlib'`) and rolls the install back. Run
`Rscript tools/install-deps.R` in the reportlib checkout first.

`build.sh` preflights the list, reading it from `DESCRIPTION` and attaching each package. It has
to attach rather than load: a `Depends` is only needed to attach, so `requireNamespace("reportlib")`
succeeds with `maps` absent and the build then dies inside a plot. Attaching reports the real
cause — *package 'maps' required by 'reportlib' could not be found*.

The check exists because this machine has two R installations — `/usr/local/bin/Rscript` (4.4.1)
and `/usr/bin/Rscript` (4.6.0) — with separate libraries. Installing "for R" is not a thing; every
install targets one library, so the preflight prints which `Rscript` and which library it checked.

CI (`.github/workflows/build-and-deploy.yml`) runs on push to `main`: downloads parquet from
GitHub release `v0.1.0` into `./data`, sets up Quarto, renders, publishes `content/docs` to Pages.
`setup-r-dependencies` reads `DESCRIPTION`, so the workflow's `packages:` block only pins the
reportlib tag and does not restate the list.

⚠️ **The release assets are stale.** They still hold the retired R-built summaries; the site now
expects what `scripts/build_summaries.R` produces (15 files, 150 MB). CI will build green but
publish the old numbers until a new release is cut from the new summaries.

## Repo conventions

- **git-flow**: work on `develop`; `feature/*` → `develop`; `release/*` → `main`. Never commit
  straight to `main`.
- Update `CHANGELOG.md` (Keep a Changelog) and the `Version:` in `DESCRIPTION` for each release.
- Never commit `content/docs/`, `data/`, or `.Rproj.user/`.

## In-flight migration

Five phases: remove 8 pages ✅ → switch to seastamp inputs ✅ → Distill-to-Quarto ✅ → extract the
shared `reportlib` package ✅ → roll out to `bal-report` / `med-report` ✅.

**Parquet stays.** A parquet-to-SQLite move was planned and then reversed: SQLite came out ~8x
larger (656 MB → 5.2 GB on `nrt_ar_ar`), past GitHub's 2 GiB release-asset cap. Do not
reintroduce it; if SQL access is wanted, DuckDB queries the parquet files in place.

**See [.claude/docs/migration-plan.md](.claude/docs/migration-plan.md)** for the Distill→Quarto
mapping, phase ordering and verification steps. Read it before touching `_func/`, `_template/`,
`_site.yml`, or the workflow.

Standing constraints while it is in progress:

- One phase at a time — output comparison is the verification, so only one variable may change.
- Keep region-specific values confined to `_func/common_*.Rmd` and out of the package; the sibling
  repos share the package and it must stay portable.
- In the package, `summary_location_filtering.Rmd` / `summary_location_filtering3.Rmd` and the
  duplicate-detection functions look dead — they serve `bal-report` and `med-report`. Do not delete
  them before those sites are converted.

## Companion docs

Keep this file short. Put longer material in `.claude/docs/*.md` (e.g. a migration plan, a
template-authoring guide, a data-dictionary) and link it from here rather than inlining it.
