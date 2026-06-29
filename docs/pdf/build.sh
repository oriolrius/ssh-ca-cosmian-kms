#!/usr/bin/env bash
# Build the technical reference PDF from the canonical Markdown source.
# The same script is used locally and by CI (.github/workflows/build-pdf.yml).
#
# Requires: pandoc, xelatex (texlive-xetex + texlive-latex-extra/recommended),
#           fonts Liberation Sans and DejaVu Sans Mono.
#
# Usage: docs/pdf/build.sh [output.pdf]   (default: docs/technical-reference.pdf)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # docs/pdf
DOCS="$(cd "$HERE/.." && pwd)"                          # docs
OUT="${1:-$DOCS/technical-reference.pdf}"

pandoc "$DOCS/technical-reference.md" \
  --from=markdown \
  --template="$DOCS/pdf/template.tex" \
  --lua-filter="$DOCS/pdf/table-widths.lua" \
  --lua-filter="$DOCS/pdf/center-figures.lua" \
  --include-in-header="$DOCS/pdf/preamble.tex" \
  --pdf-engine=xelatex \
  --toc --toc-depth=3 \
  --metadata=toc-title:Contents \
  --resource-path="$DOCS:$DOCS/pdf" \
  --output="$OUT"

echo "Built $OUT"
