#!/bin/sh
# Deletes the VolSync restore leftovers (latestImage VolumeSnapshot, volsync-<rd>-dest, volsync-dst-<rd>-cache)
# once the app PVC populated from that ReplicationDestination no longer needs them.
# Orphaned RDs (app removed: no app PVC, no ReplicationSource) are reported, or removed with DELETE_ORPHANS=true.
set -eu
DRY_RUN="${DRY_RUN:-true}"
MIN_AGE_SECONDS="${MIN_AGE_SECONDS:-3600}"
DELETE_ORPHANS="${DELETE_ORPHANS:-false}"
ONLY_NAMESPACE="${ONLY_NAMESPACE:-}"   # optional: restrict to one namespace (testing)
TMP="${TMPDIR:-/tmp}"
now=$(date +%s)

run() { if [ "$DRY_RUN" = "true" ]; then echo "  DRY-RUN: $*"; else "$@"; fi; }

kubectl -n storage get volumes.longhorn.io -o json > "$TMP/lh.json"
if [ -n "$ONLY_NAMESPACE" ]; then
  kubectl -n "$ONLY_NAMESPACE" get replicationdestinations -o json > "$TMP/rd.json"
else
  kubectl get replicationdestinations -A -o json > "$TMP/rd.json"
fi

jq -r '.items[] | [.metadata.namespace, .metadata.name, (.status.latestImage.name // "-"),
  ([.status.conditions[]? | select(.type=="Synchronizing") | .status][0] // "Unknown"),
  (.metadata.creationTimestamp | fromdateiso8601)] | @tsv' "$TMP/rd.json" |
while IFS="$(printf '\t')" read -r ns rd snap syncing created; do
  dest="volsync-${rd}-dest"
  cache="volsync-dst-${rd}-cache"
  app="${rd%-dst}"
  kubectl -n "$ns" get pvc -o json > "$TMP/pvc.json"

  # What is left to clean?
  have=$(jq -r --arg d "$dest" --arg c "$cache" '[.items[] | select(.metadata.name==$d or .metadata.name==$c)] | length' "$TMP/pvc.json")
  if [ "$snap" != "-" ] && ! kubectl -n "$ns" get volumesnapshot "$snap" >/dev/null 2>&1; then snap="-"; fi

  # Every app PVC that points at this RD must be Bound, old enough, and its Longhorn full-copy clone completed
  verdict=$(jq -r --arg rd "$rd" --argjson now "$now" --argjson min "$MIN_AGE_SECONDS" --slurpfile lh "$TMP/lh.json" '
    [.items[] | select(.spec.dataSourceRef.kind? == "ReplicationDestination" and .spec.dataSourceRef.name == $rd)] as $apps
    | if ($apps | length) == 0 then "no-app-pvc"
      else ($apps | map(
              .spec.volumeName as $pv
              | ([$lh[0].items[] | select(.metadata.name == $pv)][0]) as $v
              | if .status.phase != "Bound" then "\(.metadata.name) not Bound"
                elif ($now - (.metadata.creationTimestamp | fromdateiso8601)) < $min then "\(.metadata.name) younger than \($min)s"
                elif $v == null then "\(.metadata.name) has no Longhorn volume"
                elif (($v.spec.dataSource // "") != "") and ($v.status.cloneStatus.state != "completed") then "\(.metadata.name) clone state=\($v.status.cloneStatus.state)"
                else "ok" end) | map(select(. != "ok")) | if length == 0 then "ok" else join("; ") end)
      end' "$TMP/pvc.json")

  # Orphan: the app's VolSync component is gone (Flux does not prune ssa: IfNotPresent objects)
  orphan=false
  if [ "$verdict" = "no-app-pvc" ] && ! kubectl -n "$ns" get replicationsource "$app" >/dev/null 2>&1 \
     && [ $((now - created)) -gt "$MIN_AGE_SECONDS" ]; then
    orphan=true
  fi

  if [ "$orphan" != "true" ] && [ "$snap" = "-" ] && [ "$have" = "0" ]; then continue; fi

  # Guard 1: the restore itself is idle
  if [ "$syncing" != "False" ] || kubectl -n "$ns" get job "volsync-dst-${rd}" >/dev/null 2>&1; then
    echo "SKIP $ns/$rd: restore mover running or RD not idle (Synchronizing=$syncing)"; continue
  fi
  # Guard 2: the volume populator is not mid-way (it creates vs-prime-<uid> and labels the snapshot volpop-pvc-<uid>)
  if jq -e '.items[] | select(.metadata.name | startswith("vs-prime-"))' "$TMP/pvc.json" >/dev/null; then
    echo "SKIP $ns/$rd: volume populator PVC (vs-prime-*) present in namespace"; continue
  fi
  if [ "$snap" != "-" ] && kubectl -n "$ns" get volumesnapshot "$snap" -o json \
      | jq -e '.metadata.labels // {} | keys | map(select(startswith("volsync.backube/volpop-pvc-") or . == "volsync.backube/do-not-delete")) | length > 0' >/dev/null; then
    echo "SKIP $ns/$rd: snapshot $snap in use by the populator or marked do-not-delete"; continue
  fi

  if [ "$orphan" = "true" ]; then
    if [ "$DELETE_ORPHANS" != "true" ]; then
      echo "ORPHAN $ns/$rd: no app PVC and no ReplicationSource '$app' (set DELETE_ORPHANS=true to remove)"; continue
    fi
  elif [ "$verdict" != "ok" ]; then
    # Guard 3 failed (a non-orphan RD with no app PVC lands here too, e.g. mid-restore)
    echo "SKIP $ns/$rd: $verdict"; continue
  fi

  echo "CLEAN $ns/$rd: snapshot=$snap dest=$dest cache=$cache orphan=$orphan"
  # Snapshot first (its data lives inside the dest volume), then the dest PVC, then the cache.
  if [ "$snap" != "-" ]; then
    run kubectl -n "$ns" delete volumesnapshot "$snap" --wait=true --timeout=10m || { echo "  snapshot delete failed; leaving dest PVC"; continue; }
  fi
  run kubectl -n "$ns" delete pvc "$dest" --ignore-not-found --wait=true --timeout=10m
  run kubectl -n "$ns" delete pvc "$cache" --ignore-not-found --wait=false
  if [ "$orphan" = "true" ]; then run kubectl -n "$ns" delete replicationdestination "$rd" --wait=false; fi
done
