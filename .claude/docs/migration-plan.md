# Migration Plan: Distill + parquet → Quarto + SQLite

Status: **Phase 1 complete** (uncommitted). Pilot repo is `arc-report`; `bal-report` and
`med-report` follow.

## Decisions taken

| # | Decision | Choice |
|---|----------|--------|
| D1 | Duplicated `_func` / `_template` across region repos | Extract to a shared R package **`aiqcreport`** (new repo), templates in `inst/templates/` |
| D2 | How the SQLite DB reaches the build | Pre-built offline, uploaded **gzipped as a GitHub release asset**; CI downloads + decompresses |
| D3 | Pages to drop | **Pressure pages** (6) and **NRT vs CORA pages** (2) |

## Scope

Four independent changes, deliberately sequenced so each is verifiable on its own:

1. Remove 8 pages (§Phase 1)
2. parquet → SQLite, still on Distill (§Phase 2)
3. Distill → Quarto (§Phase 3)
4. Extract shared machinery into `aiqcreport` (§Phase 4)
5. Roll out to `bal-report` / `med-report` (§Phase 5)

**Ordering rationale.** Removal comes first so nothing dead is ported. The data layer moves
before the renderer because a data-layer change can be verified against byte-identical HTML —
the renderer is held constant. The package extraction comes *last* so the code is moved exactly
once, already Quarto- and SQLite-native, and the sibling repos adopt a finished package rather
than tracking a moving one.

Never run two phases at once: output comparison is the verification, and it only works if one
variable changes at a time.

---

## Phase 0 — Baseline (skipped)

*No SQLite files yet, so Phase 2 has not started; the fingerprint harness is still to be written
before Phase 2 begins.*

Capture a reference build to diff against.

```bash
Rscript -e 'rmarkdown::render_site(input = "content", encoding = "UTF-8")'
cp -r content/docs /tmp/baseline-docs
```

Also write `scripts/dump_frames.R`: for each dataset, load the parquet frames exactly as the
pages do, apply the standard filter chain, and dump a fingerprint (row count, column names,
`digest::digest()` of the sorted frame) to `tests/fingerprints/*.json`. This is the contract
Phase 2 must preserve, and it is far cheaper to compare than rendered HTML.

**Done when:** baseline HTML exists and `dump_frames.R` produces fingerprints for
`df_ar`, `df_ar_gl`, `df_ar_cora` and their `qc1`/`qc4` variants.

---

## Phase 1 — Remove pages ✅

*Done. Verified by rendering `index`, `ar_temp` (20/20 chunks) and `ar_summary` (28/28 chunks).*

**Second pass — summary page sections.** Removed "Profile level QC flags", "Location Filtering",
"Duplicate Profiles Within Platforms" and "Duplicate Profiles Across Platforms" from all three
summary pages, which now share an identical 5-section shape. Dropped with them:
`summary_time_location_qc.Rmd`, `summary_location_filtering2.Rmd` and the four
`summary_duplicate_*.Rmd` templates.

Retained deliberately, though unused in this repo:

- `summary_location_filtering.Rmd` (bal-report) and `summary_location_filtering3.Rmd` (med-report)
  — they serve the same removed section in the siblings and die at Phase 5.
- Six now-unused functions in `_func/` (`netcdf_time_location_qc_summary`,
  `create_time_location_qc_summary_tab`, `find_duplicates_{within,across}_platforms`,
  `summarise_df_dup_{within,across}`) — still called by bal-/med-report; delete at Phase 5.
- `exclude_locations_common` — unused here (arc's `exclude_locations` is identity) but used by
  `bal-report/common_bo_gl.Rmd` and `med-report/common_mo_gl.Rmd`. **Keep permanently.**

Pre-existing dead code found while auditing, unrelated to this migration and left in place:
`get_unique_profile_no`, `remove_duplicates_within_platforms`, `create_var_density` — dead in all
three repos. Worth deleting during Phase 4 rather than carrying into the package.

Delete, per D3:

```
content/ar_pres.Rmd  ar_gl_pres.Rmd  ar_cora_pres.Rmd
content/ar_pres_qc.Rmd  ar_gl_pres_qc.Rmd  ar_cora_pres_qc.Rmd
content/ar_nrt_ar_vs_cora.Rmd  ar_nrt_gl_vs_cora.Rmd
```

Each removal touches three places — the `.Rmd`, the `_site.yml` navbar entry, and the
`index.Rmd` link. Remove all three together or the site builds with dead links.

Cascading dead code, safe to delete in the same phase:

- `_func/comp.Rmd` — used only by the two comparison pages.
- `_template/comp_*.Rmd` (6 files: `comp_basic_info`, `comp_basic_info_item`, `comp_copy_df`,
  `comp_df_counts`, `comp_intersection`, `comp_qc_counts`) and their `t_comp_*` entries in
  `_func/common.Rmd`.
- `_template/var_distribution.Rmd` — already dead today (`t_v_distributions` is registered but
  referenced by no page in any of the three repos).

Do **not** delete `_template/summary_location_filtering.Rmd` or `summary_location_filtering3.Rmd`:
unused in `arc-report`, but `bal-report` uses the first and `med-report` the second. They must
survive into the package.

Downstream effect on data: no page loads `*_qc{1,4}_pres.parquet` any more (~45 MB of the
~248 MB parquet input for this repo). Pressure columns stay in the base summary table — the
duplicate-detection helpers still select `pres_mean`.

**Done when:** site builds clean, no navbar or index link 404s, 16 pages remain (15 + index).

---

## Phase 2 — parquet → SQLite

Still on Distill. Only the data-access layer changes.

### Schema

Three tables, one DB (`aiqc_arc.sqlite`), replacing 15 parquet files:

```sql
CREATE TABLE dataset (              -- drives the constants in common_ar*.Rmd
  dataset_id   TEXT PRIMARY KEY,    -- 'nrt_ar' | 'nrt_ar_gl' | 'cora_ar'
  region       TEXT,  region_code1 TEXT,  region_code2 TEXT,
  netcdf_id    TEXT,  netcdf_doi   TEXT
);

CREATE TABLE profile_summary (      -- was netcdf_*_2_summary.parquet
  dataset_id TEXT, platform_code TEXT, profile_no INTEGER,
  profile_timestamp INTEGER,        -- epoch seconds, not TEXT
  time_qc INTEGER, position_qc INTEGER,
  longitude REAL, latitude REAL,
  observation_no_count INTEGER, ...,
  -- per variable: {pres,temp,psal}_{count,na_count,non_na_count,mean,median,min,max}
  -- per variable: {pres,temp,psal}_qc_{0..9,A}   -- profile-level flag counts
  PRIMARY KEY (dataset_id, platform_code, profile_no)
);

CREATE TABLE var_qc_summary (       -- was the 18 *_qc{1,4}_{var}.parquet files
  dataset_id TEXT, platform_code TEXT, profile_no INTEGER,
  variable TEXT,                    -- 'temp' | 'psal'  (pres dropped in Phase 1)
  qc_subset TEXT,                   -- 'qc1' | 'qc4'
  count INTEGER, na_count INTEGER, non_na_count INTEGER,
  mean REAL, median REAL, min REAL, max REAL,
  PRIMARY KEY (dataset_id, platform_code, profile_no, variable, qc_subset)
);
CREATE INDEX ix_vqs ON var_qc_summary (dataset_id, variable, qc_subset);
```

Two deliberate normalisations, both verified against current usage:

- The QC-subset files repeat seven identity columns (`platform_code`, `profile_timestamp`,
  `time_qc`, `position_qc`, `longitude`, `latitude`, `profile_no`) on every row. Store them once
  in `profile_summary` and join. The filter chain needs them, so the join is required —
  materialise it into the `df_*_qc1` / `df_*_qc4` frames on load.
- The QC-subset files also carry `{var}_qc_0..A` flag counts that **no template reads**
  (the QC pages compute flag counts from the base frame). Dropped.

### Size

Measured on `nrt_ar`: 163 MB indexed SQLite vs 51 MB parquet, ~3.2x. Extrapolating to all three
Arctic datasets, minus the pressure QC files dropped in Phase 1: **~700-850 MB**, roughly
250-300 MB gzipped. That is the number D2's release-asset approach has to carry per build;
if it proves painful, revisit before rolling out to the sibling repos.

> One caveat worth recording: SQLite is a row store and this is analytic, column-heavy data —
> DuckDB would hold it at roughly parquet size and read the existing files directly. SQLite was
> chosen deliberately; noting the trade-off only so the size figures above are not a surprise.

### Code changes

- `_func/common.Rmd`: replace `rsc_dir` / `rsc_dir2` / `release_url` with a single DB path and a
  connection opened once per page (`DBI::dbConnect(RSQLite::SQLite(), db_path)`); close it in the
  existing cleanup chunk.
  **Make the DB path absolute at definition time** — `normalizePath()` it once in `_func/`. The
  two relative paths that exist today (`../../data` in `_func/`, `../data` in templates) are both
  correct, because knitr gives `child=` documents a different working directory than
  `knit_child(text=)` fragments (see CLAUDE.md). A single relative DB path would silently break in
  one of the two contexts; an absolute one cannot.
- The two data layouts also collapse here. Today `_func/common_ar*.Rmd` carries commented-out
  `rsc_dir` overrides because CI downloads release assets *flat* into `data/` while local checkouts
  keep them nested under `data/<source>/`. One DB file makes the distinction moot — delete the
  commented lines rather than porting them.
- `_func/common_ar*.Rmd`: drop the `parquet*` variables and `read_parquet()`; read the dataset row
  from `dataset` and the frame via one query filtered on `dataset_id`.
- `_template/load_qc_summary.Rmd`: one parameterised query against `var_qc_summary` joined to
  `profile_summary`, replacing two `read_parquet()` calls.
- Convert `profile_timestamp` back to `POSIXct` on load — `format(profile_timestamp, "%Y")`
  appears in several templates and silently produces garbage on an integer.
- Consider pushing `filter_profile_level_qc()` into the SQL `WHERE`; leave the rest in dplyr for
  now, since the frames are small enough once filtered.

`scripts/build_db.R` (or Python — the prototype used `pyarrow` + `sqlite3`) converts parquet →
SQLite and is run offline, not in CI.

**Verification:** re-run `dump_frames.R` and diff fingerprints against Phase 0. Then rebuild and
diff HTML against `/tmp/baseline-docs` — with the pressure and comparison pages removed, the
remaining pages should be *byte-identical*. Any diff is a real regression.

**Done when:** fingerprints match, HTML diff is empty, no `arrow` dependency remains in
`DESCRIPTION` or the workflow.

---

## Phase 3 — Distill → Quarto

| Distill | Quarto |
|---------|--------|
| `content/_site.yml` | `content/_quarto.yml` (`project: type: website`, `output-dir: docs`) |
| `output: distill::distill_article` | `format: html` (`toc: true`, `toc-depth: 2`) |
| `site: distill::distill_website` in `index.Rmd` | project config only; drop from the page |
| `navbar: right: [menu:]` | `website: navbar: right: [menu:]` — same shape, Quarto keys |
| `xaringanExtra::use_panelset()` + `::: {.panelset}` / `::: {.panel}` | `::: {.panel-tabset}` with `##`-level headings per tab |
| `description:` front matter | `description:` (kept) or `subtitle:` |
| `.Rmd` | `.qmd` (rename; knitr engine, same chunk syntax) |

Notes:

- The panelset conversion is the only structural edit and it hits 8 templates. Quarto's tabset
  takes tab labels from headings *inside* the div, so `### All` / `### Good (QC == 1)` /
  `### Bad (QC == 4)` become the tab labels directly and the nested `::: {.panel}` wrappers go
  away. Watch the heading level — it must sit one below the section heading or the TOC fills with
  tab names.
- `knitr::knit_expand()` + `knit_child()` work unchanged under Quarto. The whole `_func` /
  `_template` mechanism carries over as-is; only the fenced-div syntax inside templates changes.
- Underscore-prefixed dirs (`_func`, `_template`) are ignored by Quarto's project scan by default,
  which is the behaviour we want — they are children, not pages.
- Drop `xaringanExtra` from `DESCRIPTION` and the workflow; add `quarto`.
- `.Rproj` `BuildType: Website` still works, but Quarto's own preview (`quarto preview content`)
  is the better local loop.

**Verification:** HTML will *not* be byte-identical — different framework, different CSS. Compare
content instead: for each page, extract table row counts, figure counts, and the rendered numeric
summaries, and diff those against the Phase 2 build. Then read the pages.

**Done when:** `quarto render content` succeeds, every page's tabs work, TOC is correct, all
figures render, navbar and index links resolve.

---

## Phase 4 — Extract `aiqcreport`

New repo. Only after Phases 1-3 are green in `arc-report`.

```
aiqcreport/
  R/            summary_common.R, var.R, qc.R, common.R   # plain functions, roxygen'd
  R/db.R        connection helper + the dataset/profile/var queries
  inst/templates/   *.qmd   (all surviving templates, incl. the two location_filtering
                             variants bal-/med- need)
  R/templates.R     template_path("var_summary_stats.qmd") accessor
```

- `_func/{common,summary_common,var,qc}.Rmd` become package R files. The knitr-child mechanism
  disappears for these; pages call `library(aiqcreport)`.
- The `t_*` registry in `common.Rmd` becomes `template_path()` over `inst/templates/`, so pages
  stop hard-coding `./_template` and the paths keep working from any working directory.
- What stays in each site repo: `content/_func/common_<region>*.qmd` (region constants only),
  the page `.qmd` files, `_quarto.yml`, and the workflow.
- Install in CI via `remotes::install_github("AIQC-Hub/aiqcreport@v0.1.0")` — pin the tag so a
  package change cannot silently alter three published sites.

**Verification:** content diff against the Phase 3 build; this is a pure code move and should
produce identical output.

---

## Phase 5 — Sibling repos

`bal-report` (BO) and `med-report` (MO) are structurally identical — templates are byte-identical
today except one trailing newline, and `_func/common.Rmd` differs only in `release_url`. Each repo:
delete `_func/*.Rmd` (except its `common_<region>*`) and `_template/` entirely, depend on
`aiqcreport`, convert its pages to `.qmd`, apply the same page removals, point at its own SQLite
release asset.

**Watch the side effect when removing these sections from the siblings.**
`_template/summary_time_location_qc.Rmd` ends with `{{df}} <- df_qc_filtered`, silently rebinding
the page's source frame to its profile-QC-filtered subset. Any later section passed `df=df_name`
therefore reads filtered data, and deleting the section flips it back to unfiltered without any
error. Across all three repos only `ar_cora_summary.Rmd` depended on this (fixed by switching it
to `df_filtered_name`, which is identical for CORA since its `filer_locations`/`exclude_locations`
are identity); all six sibling summary pages already use `df_filtered_name` and are safe. Re-check
before deleting the section there.

`aiqc-report` is the hub landing site — same Distill→Quarto conversion, but it has no data pages,
so Phases 2 and 4 do not apply.

---

## CI changes (folded into Phases 2-4)

`.github/workflows/build-and-deploy.yml`:

- Replace the `gh release download ... --pattern '*'` parquet step with a single gzipped DB
  download + `gunzip`.
- Add `quarto-dev/quarto-actions/setup@v2`; swap the render step for `quarto render content`.
- Package list currently lives in **both** `DESCRIPTION` and the workflow — during Phase 4, move
  it to `DESCRIPTION` only and let `setup-r-dependencies` read it, so the two cannot drift.
- Net dependency change: `-arrow`, `-distill`, `-xaringanExtra`, `+DBI`, `+RSQLite`, `+aiqcreport`.

## Risks

| Risk | Mitigation |
|------|------------|
| ~800 MB DB slows every CI run | Measure the gzipped download in Phase 2 before committing to it for 3 repos; per-dataset DBs are the fallback |
| Panelset → tabset conversion silently loses a tab | Phase 3 content diff counts tabs per page |
| `profile_timestamp` type change breaks year/month grouping | Explicit `POSIXct` cast on load; fingerprint test covers it |
| Package extraction diverges from what the sibling repos need | Keep all three `location_filtering` variants; extract only after arc-report is green |
| Version drift between the package and three sites | Pin `aiqcreport` by tag in each workflow |

## Open questions

- Does `ctddump` (the upstream producer) write parquet today? If so, having it emit SQLite
  directly would remove `build_db.R` and the conversion step entirely — worth checking before
  Phase 2.
- Whether the sibling repos should share one DB per region or one DB overall. Deferred to Phase 5.
