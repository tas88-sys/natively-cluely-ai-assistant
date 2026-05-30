#!/usr/bin/env bash
# Render all Natively .mmd diagrams to SVG (macOS / Linux).
# Uses mermaid-cli via npx (no global install needed; downloads on first run).
# Usage:  bash docs/diagrams/render.sh           # -> SVG
#         FORMAT=png THEME=dark bash docs/diagrams/render.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/rendered"
FORMAT="${FORMAT:-svg}"
THEME="${THEME:-default}"
mkdir -p "$OUT"

for in in "$DIR"/*.mmd; do
  name="$(basename "$in" .mmd)"
  echo "Rendering $(basename "$in") -> rendered/$name.$FORMAT"
  npx --yes @mermaid-js/mermaid-cli -i "$in" -o "$OUT/$name.$FORMAT" -t "$THEME" -b transparent
done
echo "Done. Output in $OUT"
