#!/usr/bin/env bash
#
# tsdb-update-events.sh — POST motorsport events to TheSportsDB for Teamarr.
#
# Reads a CSV file (see docs/tsdb-event-csv-format.md) and submits one event per
# row to TSDB's eventschedule_edit.php endpoint. Safe to commit — no secrets
# stored in this file.
#
# Auth: requires 1Password CLI. Set TSDB_APIKEY_OP_REF to the op:// reference
# for the API key, e.g. op://Vault/Item/api_key.
#
# Examples:
#   export TSDB_APIKEY_OP_REF="op://Vault/Item/api_key"
#   ./scripts/tsdb-update-events.sh --csv events.csv --dry-run
#   ./scripts/tsdb-update-events.sh --csv events.csv --rate 5

set -euo pipefail

# --- Required: 1Password reference to API key ---
: "${TSDB_APIKEY_OP_REF:?Set TSDB_APIKEY_OP_REF to an op:// reference (e.g. op://Vault/Item/api_key)}"

# --- Defaults (WEC) ---
: "${TSDB_DEFAULT_IDLEAGUE:=4413}"
: "${TSDB_DEFAULT_STRLEAGUE:=WEC}"
: "${TSDB_DEFAULT_STRSPORT:=Motorsport}"
: "${TSDB_DEFAULT_STRSEASON:=2026}"
: "${TSDB_DEFAULT_TZ:=Europe/Madrid}"
: "${TSDB_RATE_SECONDS:=3}"

API_BASE="https://www.thesportsdb.com/api/v1/json"

# --- Isolated Python venv (mirrors scripts/generate-paperless-asns.sh and
# scripts/apply-krr.sh: temp dir, venv inside, activate, cleanup on exit).
# No third-party Python deps are needed (csv, datetime, zoneinfo are all stdlib),
# but the venv keeps the script self-contained and matches repo convention. ---
TMPDIR=$(mktemp -d)
tsv=$(mktemp)
py_err=$(mktemp)
# Separate temp dir for 1Password CLI's daemon/socket files. We point op at
# it via TMPDIR= (NOT --config=, which would also redirect op's config/auth
# lookup and break signin) so op doesn't pollute $TMPDIR (which would race
# our cleanup against the running op daemon). Cleaned up independently below.
OP_TMP=$(mktemp -d -t op-cfg-XXXXXX)
cleanup() {
  rm -f "$tsv" "$py_err"
  rm -rf "$TMPDIR"
  rm -rf "$OP_TMP"
}
trap cleanup EXIT INT TERM

PYTHON_BIN=$(command -v python3 || command -v python) || {
  echo "ERROR: python3 or python not found in PATH" >&2; exit 1; }

"$PYTHON_BIN" -m venv "$TMPDIR/venv"
# shellcheck source=/dev/null
. "$TMPDIR/venv/bin/activate"

# Upgrade pip tooling for reproducibility (matches repo convention).
pip install --upgrade pip setuptools wheel >/dev/null

# No third-party packages required. If a future feature adds one, install it here:
# pip install <pkg>

usage() {
  cat <<'EOF'
Usage: tsdb-update-events.sh --csv FILE [options]

Required:
  --csv FILE                Path to CSV file with events (must have header row)

Modes (mutually exclusive):
  --lookup                  Resolve existing event IDs from TSDB and write a new
                            CSV with the idEvent column populated. No POSTs.
                            Default output: <csv>.with-ids.csv (override with --out).
                            Rows already having idEvent are kept as-is.
  --dry-run                 (default) Print the fields that would be set per row.
                            Useful for copying values into the TSDB webui form.

Default (no flag): --dry-run. TSDB has no public write API, so the only practical
  way to update events is via the webui — run the script to preview the values,
  then paste them into the edit form. Explicitly pass --dry-run if you want to
  be explicit.

Options:
  --out FILE                Output CSV path (only with --lookup; default: <csv>.with-ids.csv)
  --rate SECONDS            Seconds between API calls (default: 3)
  -h, --help                Show this help

Authentication:
  Requires 1Password CLI. Set TSDB_APIKEY_OP_REF to the op:// reference for
  the TheSportsDB API key, e.g.:
      export TSDB_APIKEY_OP_REF="op://Vault/Item/api_key"

Environment overrides (all optional):
  TSDB_DEFAULT_IDLEAGUE     Default TSDB league ID (default: 4413 = WEC)
  TSDB_DEFAULT_STRLEAGUE    Default league display name (default: WEC)
  TSDB_DEFAULT_STRSPORT     Default sport (default: Motorsport)
  TSDB_DEFAULT_STRSEASON    Default season string (default: 2026)
  TSDB_DEFAULT_TZ           Default IANA timezone (default: Europe/Madrid)
  TSDB_RATE_SECONDS         Default seconds between calls (default: 3)

CSV format: see docs/tsdb-event-csv-format.md
EOF
}

# --- Parse args ---
csv_file=""
out_csv=""
rate="$TSDB_RATE_SECONDS"
dry_run=0
lookup_mode=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)        csv_file="${2:-}"; shift 2 ;;
    --out)        out_csv="${2:-}"; shift 2 ;;
    --rate)       rate="${2:-}"; shift 2 ;;
    --dry-run)    dry_run=1; shift ;;
    --lookup)     lookup_mode=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Mutually exclusive modes
if [[ $lookup_mode -eq 1 && $dry_run -eq 1 ]]; then
  echo "ERROR: --lookup and --dry-run are mutually exclusive" >&2
  exit 2
fi

[[ -z "$csv_file" ]] && { echo "ERROR: --csv is required" >&2; usage >&2; exit 2; }
[[ ! -r "$csv_file" ]] && { echo "ERROR: cannot read: $csv_file" >&2; exit 2; }
[[ ! "$rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] && { echo "ERROR: --rate must be a non-negative number" >&2; exit 2; }

# Lookup mode: default output path
if [[ $lookup_mode -eq 1 && -z "$out_csv" ]]; then
  out_csv="${csv_file%.csv}.with-ids.csv"
fi

# --- Verify required tools (Python is provided by the venv above) ---
for tool in curl op; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: required tool '$tool' not found in PATH" >&2; exit 3; }
done

# --- 1Password auth check ---
# All op invocations run with TMPDIR=$OP_TMP so the op daemon's PID/socket
# files land in a sibling temp dir (not inside $TMPDIR). Without this, op's
# daemon creates $TMPDIR/com.agilebits.op.501/op-daemon.pid and holds it
# open, so the trap's `rm -rf "$TMPDIR"` reports "Directory not empty".
#
# IMPORTANT: do NOT also pass --config=$OP_TMP — that points op at the
# empty fresh $OP_TMP for its config/auth lookup and makes `op whoami`
# return "not signed in" even when you are signed in to the real 1Password.
# The auth token lives in op's default config location (~/.config/op on
# Linux, ~/Library/Application Support/1Password/cli on macOS), not $TMPDIR.
if ! TMPDIR="$OP_TMP" op whoami >/dev/null 2>&1; then
  echo "ERROR: 1Password CLI not signed in (run 'op signin')" >&2
  exit 3
fi

# --- Fetch API key ---
echo "→ Fetching API key from 1Password: $TSDB_APIKEY_OP_REF"
if ! api_key=$(TMPDIR="$OP_TMP" op read "$TSDB_APIKEY_OP_REF" 2>/dev/null); then
  echo "ERROR: failed to read $TSDB_APIKEY_OP_REF from 1Password" >&2
  echo "       Verify the reference exists and your account has access" >&2
  exit 3
fi
[[ -z "$api_key" ]] && { echo "ERROR: 1Password returned empty API key" >&2; exit 3; }
echo "  ✓ API key loaded"

# --- Validate CSV header ---
echo "→ Validating CSV header..."
required_cols=(strEvent dateEvent strTimeLocal strVenue)
header=$(head -n 1 "$csv_file")
for col in "${required_cols[@]}"; do
  if ! echo ",$header," | grep -qE "(^|,)$col(,|\$)"; then
    echo "ERROR: CSV missing required column: $col" >&2
    echo "       Header: $header" >&2
    exit 4
  fi
done
echo "  ✓ header OK: $header"

# --- Parse CSV via Python venv (handles quoted fields, computes UTC/epoch) ---
# Separator is \x1f (Unit Separator), NOT \t — bash's `read` collapses
# consecutive whitespace including tabs even when IFS is set to a single
# tab. The CSV produces runs of empty fields (idLeague/strLeague/strSport/
# strSeason/idEvent are absent from the CSV and use shell-side defaults),
# which would get merged. \x1f is non-whitespace, so each separator is
# preserved regardless of run length.
SEP=$'\x1f'
echo "→ Parsing CSV (computing UTC + epoch per row via Python venv)..."
if ! python - "$csv_file" "$SEP" > "$tsv" 2>"$py_err" <<'PYEOF'
import csv, sys
from datetime import datetime
from zoneinfo import ZoneInfo

REQUIRED = ('strEvent', 'dateEvent', 'strTimeLocal', 'strVenue')
OUTPUT = REQUIRED + ('strCountry', 'strFilename', 'idLeague', 'strLeague',
                     'strSport', 'strSeason', 'intRound', 'idEvent', 'timezone',
                     '_utc', '_epoch')

sep = sys.argv[2]

with open(sys.argv[1], newline='') as f:
    reader = csv.DictReader(f)
    if not all(c in reader.fieldnames for c in REQUIRED):
        missing = [c for c in REQUIRED if c not in reader.fieldnames]
        sys.exit(f"MISSING_COLUMNS: {','.join(missing)}")

    for row in reader:
        if not any(row.values()):
            continue  # skip blank rows
        try:
            tz = ZoneInfo(row.get('timezone') or 'Europe/Madrid')
            local = datetime.fromisoformat(f"{row['dateEvent']}T{row['strTimeLocal']}")
            aware = local.replace(tzinfo=tz)
            utc = aware.astimezone(ZoneInfo('UTC'))
            row['_utc'] = utc.strftime('%H:%M:%S')
            row['_epoch'] = str(int(aware.timestamp()))
        except Exception as e:
            sys.exit(f"BAD_TIME:{row.get('strEvent','?')}:{e}")
        print(sep.join(row.get(c, '') for c in OUTPUT))
PYEOF
then
  echo "ERROR: CSV parsing failed:" >&2
  cat "$py_err" >&2
  exit 4
fi
rm -f "$py_err"

total=$(wc -l < "$tsv" | tr -d ' ')
if [[ "$total" -eq 0 ]]; then
  echo "ERROR: CSV has no data rows" >&2
  exit 4
fi
echo "  ✓ $total event(s) parsed"

# --- Lookup mode: query TSDB for each row's existing idEvent, write a new CSV ---
if [[ $lookup_mode -eq 1 ]]; then
  echo "→ LOOKUP mode: querying TSDB for existing event IDs"
  echo "  Output CSV: $out_csv"
  echo

  # TSDB_APIKEY passes the API key to Python via env var (avoids putting it in argv).
  # Python writes the new CSV to stdout; bash redirects to $out_csv.
  if ! TSDB_APIKEY="$api_key" \
       python - "$csv_file" "$out_csv" "$rate" "$API_BASE" \
         > "$out_csv" 2>"$py_err" <<'PYEOF'
import csv, sys, os, time, json
import urllib.parse, urllib.request, urllib.error

input_csv  = sys.argv[1]
output_csv = sys.argv[2]
rate       = float(sys.argv[3])
api_base   = sys.argv[4]
api_key    = os.environ['TSDB_APIKEY']

# Apply the same defaults as the POST loop so search criteria match
DEFAULTS = {
    'idLeague':  '4413',
    'strLeague': 'WEC',
    'strSport':  'Motorsport',
    'strSeason': '2026',
}

def search_events(str_event, str_season, int_round, str_filename):
    """Query TSDB searchevents.php and return (matches, error_str)."""
    params = {'e': str_event, 's': str_season}
    qs = urllib.parse.urlencode({k: v for k, v in params.items() if v})
    url = f"{api_base}/{api_key}/searchevents.php?{qs}"
    try:
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
    except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError, TimeoutError) as e:
        return [], f"network error: {e}"
    except Exception as e:
        return [], f"error: {e}"
    events = data.get('events') or []
    matches = []
    for e in events:
        if e.get('strSeason') and str_season and e.get('strSeason') != str_season:
            continue
        if int_round and e.get('intRound') and str(e.get('intRound')) != str(int_round):
            continue
        if str_filename and e.get('strFilename') and e.get('strFilename') != str_filename:
            continue
        matches.append(e)
    return matches, None

# Read input CSV
with open(input_csv, newline='') as f:
    reader = csv.DictReader(f)
    fieldnames = list(reader.fieldnames)
    rows = list(reader)

# Ensure idEvent column exists (insert after intRound if present, else append)
if 'idEvent' not in fieldnames:
    if 'intRound' in fieldnames:
        idx = fieldnames.index('intRound') + 1
        fieldnames.insert(idx, 'idEvent')
    else:
        fieldnames.append('idEvent')

# Apply defaults so search criteria are complete
for row in rows:
    for k, v in DEFAULTS.items():
        row.setdefault(k, v)

print(f"Looking up IDs for {len(rows)} rows at {rate}s/call...", file=sys.stderr)

matched = skipped = ambiguous = errored = 0

for i, row in enumerate(rows, 1):
    if row.get('idEvent'):
        print(f"[{i}/{len(rows)}] {row['strEvent']} → keep existing idEvent={row['idEvent']}", file=sys.stderr)
        skipped += 1
        continue

    matches, err = search_events(
        row.get('strEvent', ''),
        row.get('strSeason') or DEFAULTS['strSeason'],
        row.get('intRound') or '',
        row.get('strFilename') or '',
    )

    if err:
        print(f"[{i}/{len(rows)}] {row['strEvent']} → ERROR: {err} (leaving idEvent blank)", file=sys.stderr)
        errored += 1
    elif len(matches) == 1:
        row['idEvent'] = matches[0]['idEvent']
        matched += 1
        print(f"[{i}/{len(rows)}] {row['strEvent']} → {matches[0]['idEvent']}  ✓ matched", file=sys.stderr)
    elif len(matches) == 0:
        print(f"[{i}/{len(rows)}] {row['strEvent']} → (no match — will be a new insert)", file=sys.stderr)
        ambiguous += 1
    else:
        ids = ', '.join(m.get('idEvent', '?') for m in matches[:5])
        more = f" +{len(matches)-5} more" if len(matches) > 5 else ''
        print(f"[{i}/{len(rows)}] {row['strEvent']} → AMBIGUOUS ({len(matches)} matches: {ids}{more}) — leaving blank", file=sys.stderr)
        ambiguous += 1

    if i < len(rows):
        time.sleep(rate)

# Write output CSV (preserve all input columns + populated idEvent)
print(file=sys.stderr)
print(f"Matched:    {matched}", file=sys.stderr)
print(f"Skipped:    {skipped} (idEvent pre-populated)", file=sys.stderr)
print(f"No-match:   {len(rows) - matched - skipped - ambiguous + errored}", file=sys.stderr)
print(f"Ambiguous:  {ambiguous}", file=sys.stderr)
print(f"Errors:     {errored}", file=sys.stderr)

with open(output_csv, 'w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    for row in rows:
        writer.writerow(row)

print(f"\nWrote: {output_csv}", file=sys.stderr)
PYEOF
  then
    echo "ERROR: lookup failed:" >&2
    cat "$py_err" >&2
    exit 5
  fi
  rm -f "$py_err"
  exit 0
fi

if [[ $lookup_mode -eq 1 ]]; then
  : # already handled above
else
  # Default mode = dry-run. TSDB has no public write API, so the only practical
  # way to update events is via the webui — the script prints the values to
  # paste into the edit form. Pass --dry-run explicitly to suppress this hint.
  if [[ $dry_run -eq 0 ]]; then
    echo "(no mode specified — defaulting to --dry-run; pass --lookup to resolve existing IDs instead)"
    dry_run=1
  fi
  echo "→ DRY-RUN mode: no API calls (rate limit ignored). Copy the printed values into the TSDB webui form at the league's Add Event page."
fi
echo

# --- Main loop: POST each row ---
ok=0
fail=0
row=0
declare -a errors=()
declare -a rows_log=()   # captured for the summary table at the end

while IFS="$SEP" read -r strEvent dateEvent strTimeLocal strVenue strCountry \
                     strFilename idLeague strLeague strSport strSeason \
                     intRound idEvent row_tz utc_time epoch; do
  row=$((row + 1))

  # Apply defaults (idLeague/strLeague/strSport/strSeason/timezone)
  [[ -z "$idLeague"  ]] && idLeague="$TSDB_DEFAULT_IDLEAGUE"
  [[ -z "$strLeague" ]] && strLeague="$TSDB_DEFAULT_STRLEAGUE"
  [[ -z "$strSport"  ]] && strSport="$TSDB_DEFAULT_STRSPORT"
  [[ -z "$strSeason" ]] && strSeason="$TSDB_DEFAULT_STRSEASON"

  url="$API_BASE/${api_key}/eventschedule_edit.php"
  args=(
    -sS -u "${api_key}:x" -X POST "$url"
    --data-urlencode "idEvent=${idEvent}"
    --data-urlencode "idLeague=${idLeague}"
    --data-urlencode "strLeague=${strLeague}"
    --data-urlencode "strSport=${strSport}"
    --data-urlencode "strSeason=${strSeason}"
    --data-urlencode "strEvent=${strEvent}"
    --data-urlencode "strVenue=${strVenue}"
    --data-urlencode "strCountry=${strCountry}"
    --data-urlencode "dateEvent=${dateEvent}"
    --data-urlencode "strTime=${utc_time}"
    --data-urlencode "strTimeLocal=${strTimeLocal}"
    --data-urlencode "strTimestamp=${epoch}"
  )
  [[ -n "$strFilename" ]] && args+=(--data-urlencode "strFilename=${strFilename}")
  [[ -n "$intRound"   ]] && args+=(--data-urlencode "intRound=${intRound}")

  # Capture for the summary table at the end
  rows_log+=("$row|$strEvent|$dateEvent|$strTimeLocal|$utc_time|$epoch|$idLeague|$strLeague|$strSport|$strSeason|$intRound|$strFilename|$strVenue|$strCountry|${idEvent:-INSERT}")

  echo
  echo "[$row/$total] $strEvent"
  # Per-row block — labels match TSDB's web Edit form (human-readable).
  printf "  %-25s %s\n" "Date:"                   "$dateEvent"
  printf "  %-25s %s\n" "Local Time HH-MM-SS:"    "$strTimeLocal"
  printf "  %-25s %s\n" "UTC Time HH-MM-SS:"      "$utc_time"
  printf "  %-25s %s\n" "Event Name:"             "$strEvent"
  printf "  %-25s %s\n" "Attendance:"             "—"
  printf "  %-25s %s\n" "Venue:"                  "$strVenue"
  printf "  %-25s %s\n" "Country:"                "${strCountry:-—}"
  printf "  %-25s %s\n" "City:"                   "—"
  printf "  %-25s %s\n" "Season:"                 "$strSeason"
  printf "  %-25s %s\n" "Round:"                  "${intRound:-—}"
  printf "  %-25s %s\n" "Status Event:"           "—"
  printf "  %-25s %s\n" "Postponed Event:"        "No"
  printf "  %-25s %s\n" "Locked Event:"           "Unlocked"
  printf "  %-25s %s\n" "Group:"                  "—"
  printf "  %-25s %s\n" "Weather:"                "—"
  printf "  %-25s %s\n" "Youtube Link:"           "—"
  printf "  %-25s %s\n" "X Link:"                 "—"
  printf "  %-25s %s\n" "Description:"            "—"
  printf "  %-25s %s\n" "List of Event Results:"  "—"
  echo "  ───────────────────────────  API metadata  ───────────────────────────"
  printf "  %-25s %s (id %s)\n" "League:"             "$strLeague" "$idLeague"
  printf "  %-25s %s\n" "Sport:"                  "$strSport"
  printf "  %-25s %s\n" "Filename:"               "${strFilename:-—}"
  printf "  %-25s %s\n" "Epoch timestamp:"        "$epoch"
  if [[ -n "$idEvent" ]]; then
    printf "  %-25s %s (edit existing row)\n" "Event ID:" "$idEvent"
  else
    printf "  %-25s (blank → insert new row)\n" "Event ID:"
  fi

  if [[ $dry_run -eq 1 ]]; then
    ok=$((ok + 1))
    continue
  fi

  # --max-time caps a stuck request at 30s; --connect-timeout caps connect at 10s.
  echo "  → POST (timeout 30s)…"
  if ! resp=$(curl -sS --max-time 30 --connect-timeout 10 "${args[@]}" -w "\n%{http_code}" 2>&1); then
    rc=$?
    echo "  ✗ curl failed (rc=$rc — timeout? connect refused? 429?)"
    fail=$((fail + 1))
    errors+=("Row $row ($strEvent): curl rc=$rc — $resp")
    continue
  fi

  http_code=$(tail -n 1 <<<"$resp")
  body=$(sed '$d' <<<"$resp")

  if [[ "$http_code" =~ ^2 ]]; then
    echo "  ✓ HTTP $http_code"
    [[ -n "$body" && "$body" != "null" ]] && echo "    $body" | head -c 200
    ok=$((ok + 1))
  else
    echo "  ✗ HTTP $http_code — $body" | head -c 300
    fail=$((fail + 1))
    errors+=("Row $row ($strEvent): HTTP $http_code — $body")
  fi

  # Rate limit (skip after last row); show countdown so it doesn't look hung
  if [[ $row -lt $total ]]; then
    echo -n "  ⏱ rate-limit sleep ${rate}s… "
    sleep "$rate"
    echo "done"
  fi
done < "$tsv"

echo
echo "===== Summary ====="
echo "Total:  $total"
echo "Sent:   $ok"
echo "Failed: $fail"

if [[ ${#rows_log[@]} -gt 0 ]]; then
  echo
  echo "===== Events processed (compact view, UI labels) ====="
  # Column widths: Row=3, Event Name=44, Date=10, UTC Time=8, Venue=30, Season=6, Round=5, Action=8
  # Total line width = 3 + 3 + 44 + 3 + 10 + 3 + 8 + 3 + 30 + 3 + 6 + 3 + 5 + 3 + 8 = 135
  printf "%-3s | %-44s | %-10s | %-8s | %-30s | %-6s | %-5s | %-8s\n" \
    "Row" "Event Name" "Date" "UTC Time" "Venue" "Season" "Round" "Action"
  printf -- "-%.0s" {1..135}; echo
  for entry in "${rows_log[@]}"; do
    IFS='|' read -r r ev dt lt utc ep il sl ss sr ir fn vn cy ac <<< "$entry"
    printf "%-3s | %-44.44s | %-10s | %-8s | %-30.30s | %-6s | %-5s | %-8s\n" \
      "$r" "$ev" "$dt" "${utc:0:8}" "$vn" "$sr" "${ir:-—}" "$ac"
  done
  echo
  echo "(full per-row detail with all UI labels shown above per row)"
fi

if [[ ${#errors[@]} -gt 0 ]]; then
  echo
  echo "Errors:"
  printf '  - %s\n' "${errors[@]}"
fi

[[ $fail -gt 0 ]] && exit 1
exit 0