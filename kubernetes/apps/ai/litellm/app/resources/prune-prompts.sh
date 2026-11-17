#!/bin/sh
# Clears the prompt/response bodies on LiteLLM_SpendLogs rows older than
# PROMPT_RETENTION_DAYS. Every row is kept: only messages, response and
# proxy_server_request are reset to '{}', the value LiteLLM itself writes
# when store_prompts_in_spend_logs is off. Spend, tokens, user, key, team,
# tags, status and metadata (usage_object / cost_breakdown) stay untouched.
#
# Clearing and vacuuming write WAL (a full-page image of every page they
# touch), and Postgres can only drop WAL once it is archived to R2, which
# runs at ~6 MB/s. Unthrottled, this job outruns the archiver until pg_wal
# fills the PVC. So before every small batch, and while every VACUUM runs,
# it checks pg_wal and pauses until the archiver catches up. Reading pg_wal
# needs the pg_monitor role; without it the job stops before writing.
set -eu

: "${PROMPT_RETENTION_DAYS:=60}"
: "${BATCH_SIZE:=100}"
: "${DRY_RUN:=false}"
# Pause while more segments than this are waiting to be archived (the job
# outrunning the archiver), or while pg_wal holds more than this. pg_wal
# normally reaches max_wal_size + wal_keep_size (~1.5 GB) between
# checkpoints, so the size limit sits above that and well below free space.
: "${WAL_LIMIT_MB:=2048}"
: "${ARCHIVE_BACKLOG_MAX:=8}"
# Batches between VACUUMs, and their throttle (~4 MB/s of dirtied pages at
# 20ms, below the archiver's rate).
: "${VACUUM_EVERY:=20}"
: "${VACUUM_COST_DELAY_MS:=20}"
# Give up (and fail the Job) if WAL never drains, e.g. archiving is broken.
: "${MAX_WAIT_SECONDS:=1800}"

q() { psql "$DATABASE_URL" -X -A -t -q -v ON_ERROR_STOP=1 "$@"; }

# Sets wal_mb and ready; exits on any failure so the guard never fails open.
read_wal_state() {
  state=$(q -c "SELECT (SELECT coalesce(sum(size), 0) FROM pg_ls_waldir())::bigint / 1048576,
                       (SELECT count(*) FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready')") || {
    echo "cannot read WAL state (does this role have pg_monitor?); stopping" >&2
    exit 1
  }
  wal_mb=${state%|*}
  ready=${state#*|}
  case "$wal_mb$ready" in
    '' | *[!0-9]*) echo "unexpected WAL state '$state'; stopping" >&2; exit 1 ;;
  esac
}

wal_over_limit() {
  read_wal_state
  [ "$wal_mb" -gt "$WAL_LIMIT_MB" ] || [ "$ready" -gt "$ARCHIVE_BACKLOG_MAX" ]
}

wait_for_wal() {
  waited=0
  while wal_over_limit; do
    if [ "$waited" -ge "$MAX_WAIT_SECONDS" ]; then
      echo "pg_wal did not drain in ${MAX_WAIT_SECONDS}s (${wal_mb} MB, ${ready} awaiting archive); stopping" >&2
      exit 1
    fi
    echo "paused: pg_wal ${wal_mb} MB, ${ready} segments awaiting archive"
    sleep 15
    waited=$((waited + 15))
  done
}

# VACUUM is one command, so it runs in the background under a cost delay and
# is cancelled (and retried once WAL drains) if pg_wal still climbs.
vacuum_guarded() {
  while :; do
    wait_for_wal
    q -c "SET vacuum_cost_delay = '${VACUUM_COST_DELAY_MS}ms'" \
      -c 'VACUUM (ANALYZE) "LiteLLM_SpendLogs"' &
    vacuum_pid=$!
    cancelled=false
    while kill -0 "$vacuum_pid" 2>/dev/null; do
      sleep 5
      if wal_over_limit; then
        echo "cancelling VACUUM: pg_wal ${wal_mb} MB, ${ready} segments awaiting archive"
        q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity
               WHERE usename = current_user AND pid <> pg_backend_pid()
                 AND query ILIKE 'VACUUM%LiteLLM_SpendLogs%'" >/dev/null
        cancelled=true
      fi
    done
    if wait "$vacuum_pid"; then
      return 0
    fi
    [ "$cancelled" = true ] || { echo "VACUUM failed; stopping" >&2; exit 1; }
  done
}

read_wal_state
echo "WAL guard: pg_wal ${wal_mb} MB, ${ready} segments awaiting archive (limits ${WAL_LIMIT_MB} MB / ${ARCHIVE_BACKLOG_MAX})"

if [ "$DRY_RUN" = "true" ]; then
  # READ ONLY makes Postgres reject any write, so this can only report.
  psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -v days="$PROMPT_RETENTION_DAYS" <<'SQL'
BEGIN READ ONLY;
SELECT count(*) AS rows_to_clear,
       pg_size_pretty(coalesce(sum(pg_column_size(proxy_server_request)
                                 + pg_column_size(response)
                                 + pg_column_size(messages)), 0)) AS bodies_to_clear,
       min("startTime") AS oldest,
       max("startTime") AS newest
  FROM "LiteLLM_SpendLogs"
 WHERE "startTime" < now() - make_interval(days => :days)
   AND (proxy_server_request <> '{}'::jsonb
     OR response <> '{}'::jsonb
     OR messages <> '{}'::jsonb);
ROLLBACK;
SQL
  echo "dry run: nothing was changed"
  exit 0
fi

# Reclaim anything an earlier, interrupted run already cleared.
vacuum_guarded

total=0
batches=0
while :; do
  wait_for_wal
  cleared=$(q -v days="$PROMPT_RETENTION_DAYS" -v batch="$BATCH_SIZE" <<'SQL'
WITH batch AS (
  SELECT request_id
    FROM "LiteLLM_SpendLogs"
   WHERE "startTime" < now() - make_interval(days => :days)
     AND (proxy_server_request <> '{}'::jsonb
       OR response <> '{}'::jsonb
       OR messages <> '{}'::jsonb)
   LIMIT :batch
   FOR UPDATE SKIP LOCKED
), cleared AS (
  UPDATE "LiteLLM_SpendLogs" AS s
     SET proxy_server_request = '{}'::jsonb,
         response = '{}'::jsonb,
         messages = '{}'::jsonb
    FROM batch
   WHERE s.request_id = batch.request_id
  RETURNING 1
)
SELECT count(*) FROM cleared;
SQL
  )
  total=$((total + cleared))
  batches=$((batches + 1))
  [ "$cleared" -lt "$BATCH_SIZE" ] && break
  # Frequent small VACUUMs keep each one's WAL burst small and keep dead
  # tuples below autovacuum's threshold, so autovacuum (throttled far less,
  # ~40 MB/s) doesn't start mid-run.
  if [ $((batches % VACUUM_EVERY)) -eq 0 ]; then
    echo "cleared ${total} rows so far"
    vacuum_guarded
  fi
done

echo "cleared prompt/response bodies on ${total} spend log rows older than ${PROMPT_RETENTION_DAYS} days"

# Marks the freed TOAST space reusable so new prompts fill it instead of
# growing the PVC.
vacuum_guarded
