#!/usr/bin/env bash
#
# What RStudio's Build pane runs (BuildType: Custom in the .Rproj).
#
# RStudio detects a Quarto project by finding _quarto.yml next to the .Rproj.
# This project's lives in content/, so RStudio cannot see it, and its built-in
# "Build Website" would call rmarkdown::render_site() -- which fails with
# "No site generator found" now that _site.yml is gone.
#
# Moving _quarto.yml to the repo root is not the fix: Quarto lays output out
# relative to the project root, so pages would render to content/docs/content/
# instead of content/docs/.
#
set -euo pipefail
cd "$(dirname "$0")"

# Inside RStudio, PATH already carries its bundled Quarto; prefer that so the
# build matches what the IDE would do on its own.
quarto_bin="$(command -v quarto || true)"
if [ -z "$quarto_bin" ]; then
  for candidate in /usr/lib/rstudio/resources/app/bin/quarto/bin/quarto \
                   "$HOME/.local/quarto/bin/quarto"; do
    if [ -x "$candidate" ]; then quarto_bin="$candidate"; break; fi
  done
fi
if [ -z "$quarto_bin" ]; then
  echo "quarto not found on PATH or in the usual locations" >&2
  exit 1
fi

# There is more than one R on this machine, and reportlib is only installed for
# some of them. Without this check a mismatch surfaces as a knitr backtrace on
# the first page rather than as the missing dependency it is.
rscript_bin="$(command -v Rscript || true)"
if [ -n "$rscript_bin" ]; then
  if ! "$rscript_bin" -e 'quit(status = !requireNamespace("reportlib", quietly = TRUE))' >/dev/null 2>&1; then
    {
      echo "reportlib is not installed for the R that Quarto will use."
      echo "  Rscript: $rscript_bin ($("$rscript_bin" --version 2>&1 | head -1))"
      echo "  library: $("$rscript_bin" -e 'cat(.libPaths()[1])' 2>/dev/null)"
      echo
      echo "Install it there:"
      echo "  remotes::install_github(\"AIQC-Hub/reportlib@v0.1.1\")"
    } >&2
    exit 1
  fi
fi

echo "Using $("$quarto_bin" --version) at $quarto_bin, R at ${rscript_bin:-unknown}"
exec "$quarto_bin" render content "$@"
