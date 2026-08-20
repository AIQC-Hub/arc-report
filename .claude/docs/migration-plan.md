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

## Scope

Four phases, deliberately sequenced so each is verifiable on its own:

1. Remove 8 pages (§Phase 1) ✅
2. Distill → Quarto (§Phase 2)
3. Extract shared machinery into `aiqcreport` (§Phase 3)
4. Roll out to `bal-report` / `med-report` (§Phase 4)

**Ordering rationale.** Removal comes first so nothing dead is ported. The package extraction
comes *last* so the code is moved exactly once, already Quarto-native, and the sibling repos
adopt a finished package rather than tracking a moving one.

With the data layer frozen, Phase 2 is now the first phase whose output cannot be compared
byte-for-byte — plan the content-diff harness accordingly (§Phase 0).

Never run two phases at once: output comparison is the verification, and it only works if one
variable changes at a time.

---

## Phase 0 — Baseline (not yet done)

*Still outstanding, and now the immediate next task: Phase 2 is the first phase that changes
rendered output, so the baseline must be captured before it starts.*

Capture a reference build to diff against.

```bash
Rscript -e 'rmarkdown::render_site(input = "content", encoding = "UTF-8")'
cp -r content/docs /tmp/baseline-docs
```

Also write `scripts/dump_frames.R`: for each dataset, load the parquet frames exactly as the
pages do, apply the standard filter chain, and dump a fingerprint (row count, column names,
`digest::digest()` of the sorted frame) to `tests/fingerprints/*.json`. The data layer is frozen,
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

## Phase 2 — Distill → Quarto

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
summaries, and diff those against the Phase 1 build. Then read the pages.

**Done when:** `quarto render content` succeeds, every page's tabs work, TOC is correct, all
figures render, navbar and index links resolve.

---

## Phase 3 — Extract `aiqcreport`

New repo. Only after Phases 1-2 are green in `arc-report`.

```
aiqcreport/
  R/            summary_common.R, var.R, qc.R, common.R   # plain functions, roxygen'd
  R/data.R      parquet loaders + the standard filter chain
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

**Verification:** content diff against the Phase 2 build; this is a pure code move and should
produce identical output.

---

## Phase 4 — Sibling repos

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
so Phase 3 does not apply.

---

## CI changes (folded into Phases 2-3)

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
