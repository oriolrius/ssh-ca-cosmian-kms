#!/usr/bin/env bash
# Build PDF(s) from the canonical Markdown source(s) under docs/.
# Same script is used locally and by CI (.github/workflows/build-pdf.yml).
#
# Requires: pandoc, xelatex (texlive-xetex + texlive-latex-extra/recommended),
#           fonts Liberation Sans + DejaVu Sans Mono, and — for docs containing
#           ```mermaid blocks — node/npx (mermaid-cli) + Python 3.
#
# Usage:
#   docs/pdf/build.sh                 build all docs -> docs/<name>.pdf
#   docs/pdf/build.sh <in.md> <out.pdf>   build a single document
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # docs/pdf
DOCS="$(cd "$HERE/.." && pwd)"                          # docs

build_one() {
  local src="$1" out="$2"
  local work pre
  work="$(mktemp -d)"
  pre="$work/in.md"

  if grep -q '^```mermaid' "$src"; then
    python3 "$DOCS/pdf/render_mermaid.py" "$src" "$pre" "$work/assets" \
      "$DOCS/diagrams/puppeteer-config.json"
  else
    cp "$src" "$pre"
  fi

  pandoc "$pre" \
    --from=markdown \
    --template="$DOCS/pdf/template.tex" \
    --lua-filter="$DOCS/pdf/table-widths.lua" \
    --lua-filter="$DOCS/pdf/center-figures.lua" \
    --include-in-header="$DOCS/pdf/preamble.tex" \
    --pdf-engine=xelatex \
    --toc --toc-depth=3 \
    --metadata=toc-title:Contents \
    --resource-path="$DOCS:$DOCS/pdf" \
    --output="$out"

  rm -rf "$work"
  echo "Built $out"
}

if [[ $# -eq 2 ]]; then
  build_one "$1" "$2"
elif [[ $# -eq 0 ]]; then
  for name in technical-reference poc-validation krl-distribution; do
    build_one "$DOCS/$name.md" "$DOCS/$name.pdf"
  done
else
  echo "usage: build.sh [<in.md> <out.pdf>]" >&2
  exit 2
fi
