#!/bin/sh
# Clears the prompt/response bodies on LiteLLM_SpendLogs rows older than
# PROMPT_RETENTION_DAYS. Every row is kept: only messages, response and
# proxy_server_request are reset to '{}', the value LiteLLM itself writes
# when store_prompts_in_spend_logs is off. Spend, tokens, user, key, team,
# tags, status and metadata (usage_object / cost_breakdown) stay untouched.
set -eu

: "${PROMPT_RETENTION_DAYS:=60}"
: "${BATCH_SIZE:=500}"
: "${DRY_RUN:=false}"

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

total=0
while :; do
  # Small batches keep each transaction (and its WAL burst) short and never
  # block LiteLLM's own inserts.
  cleared=$(psql "$DATABASE_URL" -X -A -t -q -v ON_ERROR_STOP=1 \
    -v days="$PROMPT_RETENTION_DAYS" -v batch="$BATCH_SIZE" <<'SQL'
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
  [ "$cleared" -lt "$BATCH_SIZE" ] && break
done

echo "cleared prompt/response bodies on ${total} spend log rows older than ${PROMPT_RETENTION_DAYS} days"

# Plain VACUUM (no lock) marks the freed TOAST space reusable so new prompts
# fill it instead of growing the PVC.
psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -c 'VACUUM (ANALYZE) "LiteLLM_SpendLogs";'
