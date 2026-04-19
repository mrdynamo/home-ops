#!/usr/bin/env bash

set -Eeuo pipefail

backup_root="${BACKUP_ROOT:-/data/backups}"
backup_marker="${BACKUP_MARKER:-SIDECAR}"
db_host="${POSTGRES_HOST:-}"
db_port="${POSTGRES_PORT:-5432}"
db_name="${POSTGRES_DB:-dispatcharr}"
db_user="${POSTGRES_USER:-postgres}"

if [[ -z "$db_host" ]]; then
	echo "POSTGRES_HOST is required" >&2
	exit 1
fi

mkdir -p "$backup_root"

timestamp="$(TZ="${TZ:-UTC}" date +"%Y.%m.%d.%H.%M.%S")"
backup_name="dispatcharr-backup-${timestamp}-${backup_marker}.zip"
backup_file="${backup_root}/${backup_name}"

workdir="$(mktemp -d /tmp/dispatcharr-backup-sidecar-XXXXXX)"
cleanup() {
	rm -rf "$workdir"
}
trap cleanup EXIT

dump_file="${workdir}/database.dump"
metadata_file="${workdir}/metadata.json"
archive_file="${workdir}/${backup_name}"

export PGSSLMODE="${POSTGRES_SSL_MODE:-${PGSSLMODE:-}}"
export PGSSLROOTCERT="${POSTGRES_SSL_CA_CERT:-${PGSSLROOTCERT:-}}"
export PGSSLCERT="${POSTGRES_SSL_CERT:-${PGSSLCERT:-}}"
export PGSSLKEY="${POSTGRES_SSL_KEY:-${PGSSLKEY:-}}"

if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
	export PGPASSWORD="${POSTGRES_PASSWORD}"
else
	unset PGPASSWORD 2>/dev/null || true
fi

pg_dump \
	-h "$db_host" \
	-p "$db_port" \
	-U "$db_user" \
	-d "$db_name" \
	-Fc \
	-v \
	-f "$dump_file"

created_at="$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")"
cat > "$metadata_file" <<EOF
{
  "format": "dispatcharr-backup",
  "version": 2,
  "database_type": "postgresql",
  "database_file": "database.dump",
  "created_at": "${created_at}"
}
EOF

(
	cd "$workdir"
	zip -q -9 "$archive_file" database.dump metadata.json
)

mv "$archive_file" "$backup_file"
echo "Created backup: $backup_file"
