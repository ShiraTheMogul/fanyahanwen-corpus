#!/usr/bin/env bash
set -euo pipefail

# Import a normalized Chengyu snapshot into the Rails database used by this
# checkout. This script does not scrape or normalize Wiktionary data.
#
# Usage:
#   ./script/import_chengyu_snapshot.sh /path/to/wiktionary_chengyu_staging_full/normalized
#
# Optional:
#   RAILS_ENV=production ./script/import_chengyu_snapshot.sh /path/to/normalized

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/normalized" >&2
  exit 2
fi

NORMALIZED_DIR="$(cd "$1" && pwd)"
RAILS_ENV="${RAILS_ENV:-development}"
export RAILS_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

for required in families.csv forms.csv attestations.csv readings.csv senses.csv etymologies.csv provenances.csv form_relations.csv semantic_relations.csv; do
  if [[ ! -f "$NORMALIZED_DIR/$required" ]]; then
    echo "Missing $NORMALIZED_DIR/$required" >&2
    exit 1
  fi
done

DB_PATH="$(bin/rails runner 'puts ActiveRecord::Base.connection_db_config.database')"
if [[ "$DB_PATH" != /* ]]; then
  DB_PATH="$APP_DIR/$DB_PATH"
fi

if [[ -f "$DB_PATH" ]]; then
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${CHENGYU_BACKUP_DIR:-$APP_DIR/../.deploy-backups}"
  mkdir -p "$backup_dir"
  backup="$backup_dir/$(basename "$DB_PATH").before-chengyu-$stamp"

  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB_PATH" ".backup '$backup'"
  else
    # This fallback is acceptable for a stopped/local database. Production
    # should have sqlite3 available so the online backup API is used instead.
    cp -p "$DB_PATH" "$backup"
    echo "[chengyu deploy] WARNING: sqlite3 CLI unavailable; used a filesystem copy for backup" >&2
  fi
  echo "[chengyu deploy] backup=$backup"
fi

CHENGYU_DIR="$NORMALIZED_DIR" bin/rails chengyu:preflight
bin/rails db:migrate
CHENGYU_DIR="$NORMALIZED_DIR" bin/rails chengyu:import
bin/rails chengyu:rebuild_corpus_occurrences
bin/rails chengyu:verify

echo "[chengyu deploy] import complete; restart/reload the web service using the normal deployment procedure if this checkout is live"
