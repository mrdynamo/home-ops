#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-observability}"
SERVICE="${SERVICE:-kube-prometheus-stack-prometheus}"
LOCAL_PORT="${LOCAL_PORT:-9090}"
METRIC="${METRIC:-barman_cloud_cloudnative_pg_io_first_recoverability_point}"
QUERY="${QUERY:-$METRIC}"
DATE_FORMAT="${DATE_FORMAT:-+%Y-%m-%d %H:%M:%S %Z}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-15}"
PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""
DEBUG=0

log() {
	if [[ "$DEBUG" -eq 1 ]]; then
		echo "[cnpg-recover-point] $*"
	fi
}

cleanup() {
	log "Cleaning up"

	if [[ -n "${PORT_FORWARD_PID:-}" ]] && kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
		log "Stopping port-forward (pid: $PORT_FORWARD_PID)"
		kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
		wait "$PORT_FORWARD_PID" 2>/dev/null || true
	fi

	if [[ -n "${PORT_FORWARD_LOG:-}" ]]; then
		log "Removing temporary port-forward log"
		rm -f "$PORT_FORWARD_LOG"
	fi
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [--debug] [query]

Port-forwards Prometheus locally, queries a metric that returns a Unix timestamp,
and prints the formatted datetime.

Arguments:
	--debug  Show progress logging
	query    Optional Prometheus query. Defaults to:
					 ${METRIC}

Environment overrides:
	NAMESPACE        Kubernetes namespace for Prometheus service
	SERVICE          Prometheus service name
	LOCAL_PORT       Local port for port-forward
	METRIC           Default metric name when no query is provided
	QUERY            Full default Prometheus query
	DATE_FORMAT      date output format
	TIMEOUT_SECONDS  Seconds to wait for port-forward readiness

Examples:
	$(basename "$0")
	$(basename "$0") 'barman_cloud_cloudnative_pg_io_first_recoverability_point{cluster="postgres"}'
EOF
}

require_cmd() {
	local command_name=$1
	if ! command -v "$command_name" >/dev/null 2>&1; then
		echo "Missing required command: $command_name" >&2
		exit 1
	fi
}

parse_timestamp() {
	if command -v jq >/dev/null 2>&1; then
		jq -r '.data.result[0].value[1] // empty'
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json, sys; data = json.load(sys.stdin); result = data.get("data", {}).get("result", []); print(result[0]["value"][1] if result else "")'
	else
		echo "Missing required parser: install jq or python3" >&2
		exit 1
	fi
}

main() {
	local query_string=$QUERY
	local encoded_query
	local timestamp
	local response
	local formatted_date
	local arg

	for arg in "$@"; do
		case "$arg" in
			-h|--help)
				usage
				exit 0
				;;
			--debug)
				DEBUG=1
				;;
			*)
				query_string=$arg
				;;
		esac
	done

	require_cmd kubectl
	require_cmd curl
	require_cmd date
	log "Starting recovery point lookup"
	log "Using Prometheus service ${SERVICE} in namespace ${NAMESPACE}"

	PORT_FORWARD_LOG=$(mktemp)
	trap cleanup EXIT INT TERM

	log "Starting kubectl port-forward on local port ${LOCAL_PORT}"
	kubectl -n "$NAMESPACE" port-forward "svc/$SERVICE" "$LOCAL_PORT:9090" >"$PORT_FORWARD_LOG" 2>&1 &
	PORT_FORWARD_PID=$!

	log "Waiting for Prometheus readiness"
	for _ in $(seq 1 "$TIMEOUT_SECONDS"); do
		if curl -fsS "http://127.0.0.1:${LOCAL_PORT}/-/ready" >/dev/null 2>&1; then
			log "Prometheus is ready"
			break
		fi

		if ! kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1; then
			echo "kubectl port-forward exited unexpectedly" >&2
			cat "$PORT_FORWARD_LOG" >&2
			exit 1
		fi

		sleep 1
	done

	if ! curl -fsS "http://127.0.0.1:${LOCAL_PORT}/-/ready" >/dev/null 2>&1; then
		echo "Timed out waiting for Prometheus port-forward to become ready" >&2
		cat "$PORT_FORWARD_LOG" >&2
		exit 1
	fi

	log "Querying metric"
	encoded_query=$(curl -Gso /dev/null -w '%{url_effective}' --data-urlencode "query=${query_string}" "http://127.0.0.1:${LOCAL_PORT}/api/v1/query")
	response=$(curl -fsS "$encoded_query")
	timestamp=$(printf '%s' "$response" | parse_timestamp)

	if [[ -z "$timestamp" || "$timestamp" == "null" ]]; then
		echo "No timestamp returned for query: $query_string" >&2
		printf '%s\n' "$response" >&2
		exit 1
	fi

	log "Converting Unix timestamp ${timestamp} to formatted datetime"
	formatted_date=$(date -d "@${timestamp}" "$DATE_FORMAT")
	echo "First recoverability point: ${formatted_date}"
}

main "$@"
