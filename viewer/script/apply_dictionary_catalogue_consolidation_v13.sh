#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
DELETE_LIST="$ROOT/DELETE_FILES.txt"
ROUTES_FILE="$ROOT/config/routes.rb"

if [[ ! -f "$DELETE_LIST" ]]; then
  echo "[v13] ERROR: $DELETE_LIST was not found." >&2
  echo "[v13] Unzip the patch over the viewer root before running this script." >&2
  exit 1
fi

if [[ ! -f "$ROUTES_FILE" ]]; then
  echo "[v13] ERROR: $ROUTES_FILE was not found." >&2
  exit 1
fi

echo "=============================================================================="
echo "DICTIONARY CATALOGUE CONSOLIDATION V13 — FILE RETIREMENT"
echo "=============================================================================="
echo "Viewer root: $(cd "$ROOT" && pwd)"
echo "Routes:      NOT MODIFIED"
echo "Database:    NOT MODIFIED"
echo

removed=0
already_absent=0
while IFS= read -r relative_path; do
  [[ -z "$relative_path" ]] && continue
  target="$ROOT/$relative_path"
  if [[ -e "$target" ]]; then
    rm -f "$target"
    echo "[remove] $relative_path"
    removed=$((removed + 1))
  else
    echo "[absent] $relative_path"
    already_absent=$((already_absent + 1))
  fi
done < "$DELETE_LIST"

find "$ROOT/app/views" "$ROOT/app/services" -type d -empty -delete 2>/dev/null || true

echo
echo "Files removed:  $removed"
echo "Already absent: $already_absent"
echo "Routes changed: 0"
echo "Database writes: 0"
echo
echo "Next: remove the lines listed in ROUTES_TO_REMOVE.txt manually."
echo "Then run the preflight verifier before bin/rails db:migrate."
