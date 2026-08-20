# Migration Plan: Distill → Quarto

Status: **Phase 1 complete** (branch `feature/RemovePages`). Pilot repo is `arc-report`;
`bal-report` and `med-report` follow.

**Parquet stays.** The move to SQLite was planned, prototyped and then reversed — see
[§Reversed: parquet → SQLite](#reversed-parquet--sqlite). The data layer does not change;
only the renderer and the code layout do.

## Decisions taken

| # | Decision | Choice |
|---|----------|--------|
| D1 | Duplicated `_func` / `_template` across region repos | Extract to a shared R package **`aiqcreport`** (new repo), templates in `inst/templates/` |
| D2 | Storage format | **Parquet, unchanged.** SQLite reversed on measured size (D4) |
| D3 | Pages to drop | **Pressure pages** (6) and **NRT vs CORA pages** (2) |
| D4 | parquet → SQLite | **Reversed 2026-08-20.** ~8x size blow-up; 5.2 GB exceeds GitHub's 2 GiB release-asset cap |
| D5 | Input data | **`ctddump` + `seastamp`** observation-level parquet, aggregated locally by `scripts/build_summaries.R`. The old R-built summaries are retired |
| D6 | Continuity with the published site | **Not required.** New tooling, new numbers; no reconciliation against the old figures |

## Scope

Four phases, deliberately sequenced so each is verifiable on its own:

1. Remove 8 pages (§Phase 1) ✅
2. Switch to the seastamp inputs (§Phase 2)
3. Distill → Quarto (§Phase 3)
4. Extract shared machinery into `aiqcreport` (§Phase 4)
5. Roll out to `bal-report` / `med-report` (§Phase 5)

**Ordering rationale.** Removal comes first so nothing dead is ported. The data layer moves
before the renderer, so that change can be verified with the renderer held constant. The package
extraction comes *last* so the code is moved exactly once, already Quarto-native, and the sibling
repos adopt a finished package rather than tracking a moving one.

**Phase 2 has no before/after.** The old summaries were built by ad-hoc R from data that no longer
exists locally, and the new tooling produces genuinely different numbers — that was accepted, not
a regression to chase. So the Phase 0 baseline is captured *after* Phase 2 lands, and it is
Phase 3 onward that must not move it.

Never run two phases at once: output comparison is the verification, and it only works if one
variable changes at a time.

---

## Phase 0 — Baseline

*The harness (`scripts/dump_frames.R`) exists. The baseline itself is captured once Phase 2
lands, because the seastamp switch deliberately changes the numbers and there is nothing to
carry over from the old data.*

Capture a reference build to diff against.

```bash
Rscript -e 'rmarkdown::render_site(input = "content", encoding = "UTF-8")'
cp -r content/docs /tmp/baseline-docs
```

`scripts/dump_frames.R` does this: for each dataset it loads the frames exactly as the pages do —
by `knitr::purl()`-ing and sourcing the real `_func/*.Rmd`, so it cannot drift from what the site
does — applies the standard filter chain, and writes per-column digests plus the headline figures
to `tests/fingerprints/*.json`. Per-column digests mean a diff names the column that moved.
`--check` compares instead of writing. The data layer is frozen,
so these fingerprints must stay identical through every remaining phase — any drift means a page
started reading different data, which is the failure mode hardest to spot by eye.

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

## Reversed: parquet → SQLite

**Decision D4, 2026-08-20: not doing this.** Recorded here because the reasoning constrains
future proposals, not as work to schedule.

### Why

Measured on the raw `ctddump` layer: `nrt_ar_ar.parquet` is 656 MB, the equivalent SQLite is
**5.2 GB — ~8x**. An earlier prototype on the smaller profile-level summaries this site actually
reads showed 163 MB vs 51 MB, **~3.2x**. Different layers, same verdict; the raw layer is worse
because it is where the repetition lives.

The blow-up is structural, not a tuning problem. Parquet is a column store: it dictionary-encodes
`platform_code`, run-length-encodes the sorted keys, and compresses each column independently
against its own kind of data. SQLite is a row store and keeps every value verbatim in every row,
then adds B-tree and index overhead on top. Column-heavy analytic data is precisely the shape
that gap is widest on. `VACUUM`, page-size tuning and dropping indexes would trim the margin,
not close an 8x gap.

That kills D2's delivery mechanism outright: **GitHub caps a single release asset at 2 GiB**, so
5.2 GB cannot be uploaded as one asset regardless of appetite. Splitting or Git LFS would trade a
solved problem for a worse one — CI already downloads parquet from a release and it works.

### If SQL access is ever wanted

The motivation behind SQLite was query convenience, and that is still available without moving
the bytes: **DuckDB reads parquet files directly** — `SELECT * FROM 'data/netcdf_nrt_ar_2_summary.parquet'`
— with no conversion step, no second copy, and no new artefact in the release. Reach for that
before reconsidering a database file.

### Salvaged from the dropped phase

Two items were worth doing on their own and do not depend on the storage format:

- **The two data layouts.** CI downloads release assets *flat* into `data/`; local checkouts nest
  them under `data/<source>/`. Today `_func/common_ar*.Rmd` carries commented-out `rsc_dir`
  overrides that have to be hand-toggled to render locally — an easy thing to commit by accident
  and break CI with. Pick one layout, or resolve it at runtime. Independent of any phase.
- **Stale release assets.** After Phase 1 no page loads `*_qc{1,4}_pres.parquet` (~45 MB). They can
  come out of the release upload and the CI download.

Everything else in the dropped phase — the three-table schema, the `profile_timestamp` epoch
cast, the absolute-`normalizePath` DB path, `scripts/build_db.R` — is moot and deleted.

---

## Phase 2 — Switch to the seastamp inputs

The old summaries were produced by ad-hoc R from CMEMS downloads and shipped as release
assets. They are retired. `ctddump` + `seastamp` now write observation-level parquet, and
`scripts/build_summaries.R` aggregates that into the profile-level summaries the pages read.

### The two layers

| | seastamp source | site input |
|---|---|---|
| path | `/scratch/data/aiqc/seastamp/stamped/depth/<src>.parquet` | `<data>/netcdf_<out>_2_summary*.parquet` |
| grain | one row per observation | one row per platform × profile |
| size | 247M rows over the three Arctic datasets | ~1.5M rows |
| columns | 25 | 68 base / 15 per QC subset |

Name mapping, chosen so `_func/common_ar*.Rmd` needs no edit:
`nrt_ar_ar` → `netcdf_nrt_ar_2_summary`, `nrt_ar_gl` → `netcdf_nrt_ar_gl_2_summary`,
`cora_ar` → `netcdf_cora_ar_2_summary`.

### What the builder has to reconcile

Four differences between the layers, each of which fails silently if missed:

- **QC flags are strings** (`"1"`, `"4"`, `""`) where the filter chain compares numerically.
  `filter_profile_level_qc()` does `time_qc == 1 & position_qc %in% c(1, -128)`; against `"1"`
  that matches nothing and every page renders empty. Cast on the way in.
- **A blank flag means a missing value.** Verified 1:1 on `nrt_ar_ar` — 14,361 blank `temp_qc`,
  14,361 NA temperatures, the same rows. Counted as flag **9** ("Missing value") via the
  `BLANK_FLAG` constant; flip it to `0` ("No QC was performed") if that reading is preferred.
- **`profile_longitude` / `profile_latitude` are entirely null.** Position must come from the
  observation-level `longitude` / `latitude`. Preferring the profile columns yields `NaN`
  coordinates, which `filer_locations()` then drops — an empty map and no error.
- **The `-128` `position_qc` sentinel is gone**, and `time_qc` / `position_qc` are uniformly `1`.
  The profile-level QC filter is currently a no-op; keep it anyway, since that is a property of
  today's data and not a guarantee.

`is_dup` is `FALSE` throughout — deduplication now happens upstream, which is consistent with the
duplicate-profile sections removed in Phase 1.

**The whole filter chain is now a no-op.** Every `df_*_filtered` frame fingerprints identically to
its unfiltered source: `time_qc`/`position_qc` are uniformly 1, the coordinates already sit inside
each region's box, and `exclude_locations()` was always identity here. Under the old data it
removed a great deal — GL fell from 742,809 profiles to 207,372. seastamp evidently applies that
filtering upstream. Keep the chain: it is cheap, it is what the sibling repos still rely on, and
its being redundant is a property of today's data rather than a guarantee.

### Memory

Aggregating 118M rows (CORA) in one pass needs well over 10 GB. The builder bins platforms into
chunks of ~15M rows (`CHUNK_ROWS`) and aggregates each with `data.table`; a profile never spans
platforms, so any partition by platform is a valid partition of the groups. Exact medians are the
reason this is not pushed into arrow, whose grouped `median()` is approximate.

### Verification

Internal consistency, since there is no before/after to diff:

- per-variable flag counts sum to `{var}_count`
- `{var}_na_count + {var}_non_na_count == {var}_count`
- `min <= mean <= max`
- the QC subsets reconcile against the base flag counts: `sum(qc1$temp_count) == sum(base$temp_qc_1)`
- coordinates land inside the region box

**Done when:** all three datasets build, the checks above pass, the site renders, and
`dump_frames.R` has written the Phase 0 baseline over the new data.

---

## Phase 3 — Distill → Quarto ✅

*Done. 16 pages render under Quarto 1.10.18; every value, figure, table and DT payload matches the
Phase 2 baseline, and all 16 pages keep their tab structure (4 tabsets / 12 panels on the variable
pages, 1 / 2 elsewhere).*

**The one real gotcha: the working directory changed.** rmarkdown evaluated a `child=` document in
*that child's own directory*; Quarto evaluates every context in the page's directory. Measured, not
assumed — a probe page reported `content/` for the page, the `_func/` child and a
`knit_child(text=)` fragment alike. So `rsc_dir <- "../../data"` broke immediately on the first
render. `_func/common.Rmd` now resolves the data directory once to an absolute path, probing
`../data` then `../../data` for a directory that actually contains parquet files — a bare
`dir.exists()` would match an unrelated `data/` further up the tree. `rsc_dir2` is now an alias.

Fixed in passing: `qc_basic_info`, `summary_basic_info` and `var_basic_info` all linked to a
literal `parquet_url` instead of `{{parquet_url}}` — a broken link on every page, present in the
Distill build too.


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

**Verification:** HTML is *not* byte-identical — different framework, different CSS. The content
diff compares, per page, every `<code>label</code>: value` pair, figure count, table count and DT
payload count, plus tabset/panel counts and tab labels. Result: identical on all 16 pages. The only
heading differences are Distill's "Contents" TOC title and the tab labels, which Quarto renders as
tab buttons rather than `<h3>` — both confirmed by the tabset check.

**Done:** `quarto render content` succeeds, tabs work, TOC is correct (toc-depth 2, `##` only),
navbar has its 3 menus, and every internal link resolves.

---

## Phase 4 — Extract `aiqcreport` ✅

*Done. The package lives at `/scratch/workspace/aiqcreport` (not yet pushed). arc-report keeps
only its pages, `_func/common_site.Rmd`, three `_func/common_ar*.Rmd` region files and
`_quarto.yml`; 23 shared files moved out.*

What moved, and what deliberately did not:

- **Dropped as dead in all three repos:** `get_unique_profile_no`,
  `remove_duplicates_within_platforms`, `create_var_density`. Verified by call-site count across
  arc/bal/med before deleting.
- **Kept although unused here:** the duplicate-detection functions,
  `netcdf_time_location_qc_summary`, `create_time_location_qc_summary_tab`,
  `exclude_locations_common`, and the two `summary_location_filtering*` templates — all still
  called by bal-report and med-report. They retire at Phase 5.
- **`t_*` registry → `template_path("var_summary_stats.Rmd")`.** Named at the call site rather
  than through a registry of 18 variables, so each page says which template it uses.
- **`rsc_dir` → `aiqc_data_dir()`.** `_func/common_site.Rmd` assigns it to `rsc_dir`/`rsc_dir2`,
  which the templates still reference by name through `knit_expand`.
- **`libraries.Rmd` → `Depends:`.** Template code is evaluated in the *page's* environment, so the
  plotting and table packages must be attached, not merely imported. `Depends` is the honest way
  to say that; `Imports` would leave `ggplot()` unresolved in a template.

Templates keep their `.Rmd` extension rather than becoming `.qmd` — they are knitr fragments read
by `knit_expand`, never rendered by Quarto, and keeping the names identical makes this phase a
provable no-op.

⚠️ **The package is local only.** `DESCRIPTION` and the workflow already point at
`github::AIQC-Hub/aiqcreport@v0.1.0`; CI cannot install it until that repo is pushed and tagged.


New repo. Only after Phases 1-3 are green in `arc-report`.

```
aiqcreport/
  R/            summary_common.R, var.R, qc.R, common.R   # plain functions, roxygen'd
  R/data.R      parquet loaders + the standard filter chain
  inst/templates/   *.qmd   (all surviving templates, incl. the two location_filtering
                             variants bal-/med- need)
  R/templates.R     template_path("var_summary_stats.qmd") accessor
```

- `_func/{common,summary_common,var,qc}.Rmd` become package R files, split by topic
  (`filters.R`, `tables.R`, `summary.R`, `var.R`, `qc.R`, `duplicates.R`, `paths.R`). The
  knitr-child mechanism disappears for these; pages call `library(aiqcreport)`.
- The `t_*` registry in `common.Rmd` becomes `template_path()` over `inst/templates/`, so pages
  stop hard-coding `./_template` and the paths keep working from any working directory.
- What stays in each site repo: `content/_func/common_<region>*.qmd` (region constants only),
  the page `.qmd` files, `_quarto.yml`, and the workflow.
- Install in CI via `remotes::install_github("AIQC-Hub/aiqcreport@v0.1.0")` — pin the tag so a
  package change cannot silently alter three published sites.

**Verification:** content diff against the Phase 3 build; this is a pure code move and should
produce identical output.

---

## Phase 5 — Sibling repos ✅

*Done. bal-report and med-report are on Quarto, on the seastamp data and on the package, each on
a `feature/QuartoMigration` branch. Nothing is pushed or published — the sites are for manual
inspection first.*

| | pages | datasets |
|---|---|---|
| arc-report | 16 | AR, GL, CORA |
| bal-report | 11 | BO, CORA |
| med-report | 16 | MO, GL, CORA |

**bal-report loses GL entirely.** Copernicus does not publish the GL product for the Baltic, and
there is no `nrt_bo_gl` in the new data, so `bo_gl_*` and `_func/common_bo_gl.Rmd` are gone.

The side effect that bit arc-report did not recur: all six sibling summary pages already passed
`df_filtered_name` to the descriptive-statistics section, so removing "Profile level QC flags"
changed nothing downstream. Checked before the edit, not after.

**What the roll-out paid back.** With all three sites converted, the package could shed everything
that only existed to serve the un-migrated siblings: the four duplicate-detection functions,
`netcdf_time_location_qc_summary`, `create_time_location_qc_summary_tab`, and both
`summary_location_filtering*` templates — 38 exports down to 34, 18 templates down to 16.
`exclude_locations_common` stays; med-report's GL region file calls it twice.

`build_summaries()` and `fingerprint_frames()` also moved into the package rather than being
copied into two more repos, each site keeping a wrapper that only names its datasets.


`bal-report` (BO) and `med-report` (MO) are structurally identical — templates are byte-identical
today except one trailing newline, and `_func/common.Rmd` differs only in `release_url`. Each repo:
delete `_func/*.Rmd` (except its `common_<region>*`) and `_template/` entirely, depend on
`aiqcreport`, convert its pages to `.qmd`, apply the same page removals, and keep pointing at its own
parquet release asset.

**Watch the side effect when removing these sections from the siblings.**
`_template/summary_time_location_qc.Rmd` ends with `{{df}} <- df_qc_filtered`, silently rebinding
the page's source frame to its profile-QC-filtered subset. Any later section passed `df=df_name`
therefore reads filtered data, and deleting the section flips it back to unfiltered without any
error. Across all three repos only `ar_cora_summary.Rmd` depended on this (fixed by switching it
to `df_filtered_name`, which is identical for CORA since its `filer_locations`/`exclude_locations`
are identity); all six sibling summary pages already use `df_filtered_name` and are safe. Re-check
before deleting the section there.

`aiqc-report` is the hub landing site — same Distill→Quarto conversion, but it has no data pages,
so Phase 4 does not apply.

---

## CI changes (folded into Phases 2-4)

`.github/workflows/build-and-deploy.yml`:

- The `gh release download v0.1.0 --dir ./data --pattern '*'` step is **unchanged** — parquet
  stays. Narrow the pattern only if the unused `*_qc{1,4}_pres.parquet` assets are pruned.
- Add `quarto-dev/quarto-actions/setup@v2`; swap the render step for `quarto render content`.
- Package list currently lives in **both** `DESCRIPTION` and the workflow — during Phase 4, move
  it to `DESCRIPTION` only and let `setup-r-dependencies` read it, so the two cannot drift.
- Net dependency change: `-distill`, `-xaringanExtra`, `+quarto`, `+aiqcreport`. `arrow` stays.

## Risks

| Risk | Mitigation |
|------|------------|
| Panelset → tabset conversion silently loses a tab | Phase 3 content diff counts tabs per page |
| A page silently changes which data it reads during the Quarto port | Phase 0 fingerprints are re-checked after every phase |
| Package extraction diverges from what the sibling repos need | Keep all three `location_filtering` variants; extract only after arc-report is green |
| Version drift between the package and three sites | Pin `aiqcreport` by tag in each workflow |

## Open questions

- Which data layout wins — flat (as CI downloads) or nested `data/<source>/` (as local checkouts
  have)? Needed to retire the commented-out `rsc_dir` overrides.
- Can the unused `*_qc{1,4}_pres.parquet` assets be pruned from release `v0.1.0`, or does another
  consumer read them?
