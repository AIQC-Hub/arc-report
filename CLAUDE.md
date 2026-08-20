# arc-report

R Markdown / **Distill** website publishing CTD (temperature, salinity, pressure) data-summary
reports for the **Arctic Ocean** in situ observations. Built to GitHub Pages at
<https://aiqc-hub.github.io/arc-report/>.

Three datasets, each rendered as its own set of pages:

| Code   | Source                                              | Common file            |
|--------|-----------------------------------------------------|------------------------|
| `AR`   | CMEMS NRT Arctic (`cmems_obs-ins_arc_phybgcwav_mynrt_na_irr`) | `_func/common_ar.Rmd`      |
| `GL`   | Same product, GL subset                             | `_func/common_ar_gl.Rmd`   |
| `CORA` | CMEMS delayed-mode CORA (`cmems_obs-ins_glo_phy-temp-sal_my_cora_irr`) | `_func/common_ar_cora.Rmd` |

## Layout

```
content/            # Distill site root (WebsitePath in .Rproj)
  _site.yml         # navbar, output_dir: docs
  index.Rmd         # landing page
  ar[_gl|_cora]_{summary,pres,temp,psal,pres_qc,temp_qc,psal_qc}.Rmd
  ar_nrt_{ar,gl}_vs_cora.Rmd
  _func/            # sourced as knitr children: shared setup + R functions
  _template/        # knit_expand templates ({{param}} placeholders)
  docs/             # BUILD OUTPUT — generated, git-ignored, do not hand-edit
data -> /scratch/data/aiqc/merged   # symlink; parquet inputs (git-ignored)
```

## How a page is built

Every page follows the same three-layer pattern — read one page (e.g. `content/ar_temp.Rmd`)
and the pattern generalises to all of them.

1. **Page `.Rmd`** — YAML front matter, then a chunk setting `r_funcs` (which `_func/` files to
   load) and page variables (`var`, `var_name`, `var_label`, `qc_var`, …).
2. **`_func/` children** — pulled in via `child=file.path(r_func_path, r_funcs)`. Order matters:
   `libraries.Rmd` → `common.Rmd` (paths, template registry `t_*`, shared helpers) →
   one `common_ar*.Rmd` (dataset constants, loads the parquet into `df_*`) → topic functions
   (`summary_common.Rmd`, `var.Rmd`, `qc.Rmd`, `comp.Rmd`).
3. **`_template/` fragments** — expanded and knitted per section:
   ```r
   src <- knitr::knit_expand(t_v_summary_stats, df = df_filtered_name, var = var)
   res <- knitr::knit_child(text = src, quiet = TRUE)
   cat(res, sep = '\n')          # chunk needs results = 'asis'
   ```
   Templates use `{{placeholder}}`; every template path is registered as a `t_*` variable in
   `_func/common.Rmd`. Data frames are passed **by name (string)**, not by value.

**Working directory rule (subtle, bites often).** knitr evaluates a `child=` document with the
working directory set to *that child's own directory*, while `knit_child(text = ...)` runs in the
page's directory. So relative paths mean different things depending on where the code lives:

| Code lives in | Effective wd | Path to `data/` |
|---------------|--------------|-----------------|
| a page `.Rmd` | `content/` | `../data` |
| `_func/*.Rmd` (loaded via `child=`) | `content/_func/` | `../../data` |
| `_template/*.Rmd` (via `knit_expand` + `knit_child(text=)`) | `content/` | `../data` |

This is why `_func/common.Rmd` defines **both** `rsc_dir <- "../../data"` (consumed in `_func/`)
and `rsc_dir2 <- "../data"` (consumed in templates). They point at the same directory; neither is
a bug. Do not "fix" one to match the other.

Other conventions: pages end with `rm(list = ls())`; tabbed sections use xaringanExtra
panelsets (`::: {.panelset}` / `::: {.panel}`); chunk labels must be unique per page.

## Data model

Inputs are pre-aggregated **profile-level** parquet summaries (one row per
platform × profile), not raw observations:

- `netcdf_<src>_2_summary.parquet` — all variables. Key columns: `platform_code`, `profile_no`,
  `profile_timestamp`, `time_qc`, `position_qc`, `longitude`, `latitude`,
  `observation_no_*`, and per-variable `{pres,temp,psal}_{count,na_count,non_na_count,mean,median,min,max}`
  plus flag counts `{var}_qc_{0..9,A}`.
- `netcdf_<src>_2_summary_qc{1,4}_{pres,temp,psal}.parquet` — same rows restricted to
  good (QC 1) / bad (QC 4) observations; loaded lazily by `_template/load_qc_summary.Rmd`.

Standard filtering chain applied on every page (`_template/location_filtering.Rmd`):
`filter_profile_level_qc()` (time_qc == 1, position_qc ∈ {1, -128}) → `filer_locations()` →
`exclude_locations()`. The last two are defined per dataset in `_func/common_ar*.Rmd`
(note: `filer_` is an existing typo — keep it consistent unless renaming everywhere).

## Build & deploy

```bash
Rscript -e 'rmarkdown::render_site(input = "content", encoding = "UTF-8")'
Rscript -e 'rmarkdown::render_site(input = "content", output_format = "distill::distill_article", encoding = "UTF-8")'  # all
Rscript -e 'rmarkdown::render("content/ar_temp.Rmd")'   # single page while iterating (slow otherwise)
```

CI (`.github/workflows/build-and-deploy.yml`) runs on push to `main`: downloads parquet files
from GitHub release `v0.1.0` into `./data`, renders the site, publishes `content/docs` to Pages.
R dependencies are listed in **both** `DESCRIPTION` and the workflow — update both together.

## Repo conventions

- **git-flow**: work on `develop`; `feature/*` → `develop`; `release/*` → `main`. Never commit
  straight to `main`.
- Update `CHANGELOG.md` (Keep a Changelog) and the `Version:` in `DESCRIPTION` for each release.
- Never commit `content/docs/`, `data/`, or `.Rproj.user/`.

## In-flight migration

Distill → Quarto, in four phases: remove 8 pages (done) → Distill-to-Quarto → extract the
shared `aiqcreport` package → roll out to `bal-report` / `med-report`.

**Parquet stays.** A parquet-to-SQLite move was planned and then reversed: SQLite came out ~8x
larger (656 MB → 5.2 GB on `nrt_ar_ar`), past GitHub's 2 GiB release-asset cap. Do not
reintroduce it; if SQL access is wanted, DuckDB queries the parquet files in place.

**See [.claude/docs/migration-plan.md](.claude/docs/migration-plan.md)** for the Distill→Quarto
mapping, phase ordering and verification steps. Read it before touching `_func/`, `_template/`,
`_site.yml`, or the workflow.

Standing constraints while it is in progress:

- One phase at a time — output comparison is the verification, so only one variable may change.
- Keep region-specific values confined to `_func/common_*.Rmd` and out of templates; the sibling
  repos' machinery is byte-identical to this one and must stay portable.
- `_template/summary_location_filtering.Rmd` and `summary_location_filtering3.Rmd` look dead here
  but are used by `bal-report` and `med-report` respectively — do not delete them.

## Companion docs

Keep this file short. Put longer material in `.claude/docs/*.md` (e.g. a migration plan, a
template-authoring guide, a data-dictionary) and link it from here rather than inlining it.
