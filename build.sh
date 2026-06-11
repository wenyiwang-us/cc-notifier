#!/usr/bin/env bash
# Regenerate the self-contained install.sh from src/. Run after editing src/.
#   ./build.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$ROOT/src/install.template.sh"
OUT="$ROOT/install.sh"
MARKER="# __GENERATED_WRITERS__"

emit_writer(){  # $1 = function name, $2 = src subdir
  local fn="$1" sub="$2" f n d
  printf '%s(){\n  mkdir -p "$DIR"\n' "$fn"
  for f in "$ROOT/src/$sub"/*; do
    n="$(basename "$f")"
    d="CCN_EOF_${n//[.-]/_}"
    printf '  cat > "$DIR/%s" <<'\''%s'\''\n' "$n" "$d"
    cat "$f"
    printf '%s\n' "$d"
  done
  printf '  chmod +x "$DIR"/*.sh "$DIR"/*.py 2>/dev/null || true\n}\n'
}

{
  sed "/$MARKER/,\$d" "$TEMPLATE"
  emit_writer write_sender sender
  emit_writer write_receiver receiver
  sed "1,/$MARKER/d" "$TEMPLATE"
} > "$OUT"
chmod +x "$OUT"
echo "built $OUT  ($(grep -c '^  cat > "\$DIR/' "$OUT") files embedded)"
