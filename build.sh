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

# There is more than one R on this machine, and the packages are only installed
# for some of them. Without this check a mismatch surfaces as a knitr backtrace
# on the first page rather than as the missing dependency it is.
#
# The list comes from this repo's DESCRIPTION, so there is nothing to keep in
# step by hand. It has to be library() and not requireNamespace(): a Depends is
# only required to ATTACH a package, so loading reportlib's namespace succeeds
# with `maps` absent and the build then dies inside a plot. Measured, both ways.
rscript_bin="$(command -v Rscript || true)"
if [ -n "$rscript_bin" ]; then
  missing="$("$rscript_bin" --vanilla -e '
    d <- read.dcf("DESCRIPTION")
    f <- function(n) {
      if (!n %in% colnames(d)) return(character())
      v <- sub("\\s*\\(.*\\)$", "", trimws(strsplit(d[1, n], ",")[[1]]))
      v[nzchar(v)]
    }
    for (p in setdiff(c(f("Depends"), f("Imports")), "R")) {
      e <- tryCatch({ library(p, character.only = TRUE); NULL },
                    error = conditionMessage)
      # Print the reason, not just the name: the package that fails is
      # reportlib, but the one you have to install is the one it names.
      if (!is.null(e)) cat("  ", p, ": ", e, "\n", sep = "")
    }
  ' 2>/dev/null)"
  if [ -n "$missing" ]; then
    {
      echo "R packages missing for the R that Quarto will use:"
      echo "$missing"
      echo "  Rscript: $rscript_bin ($("$rscript_bin" --version 2>&1 | head -1))"
      echo "  library: $("$rscript_bin" -e 'cat(.libPaths()[1])' 2>/dev/null)"
      echo
      echo "Install them there:"
      echo "  install.packages(c(\"rmarkdown\", \"yaml\"))"
      echo "  remotes::install_github(\"AIQC-Hub/reportlib@v0.1.2\")"
      echo
      echo "install_github resolves reportlib's own dependencies; R CMD INSTALL"
      echo "does not -- from a checkout run tools/install-deps.R first."
    } >&2
    exit 1
  fi
fi

echo "Using $("$quarto_bin" --version) at $quarto_bin, R at ${rscript_bin:-unknown}"
exec "$quarto_bin" render content "$@"
