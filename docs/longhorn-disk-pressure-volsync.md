---
title: Longhorn Disk Pressure and VolSync Leftover PVCs
description: Why k8s-05 hit DiskPressure on 2026-11-20, where worker disk space goes, why VolSync leaves Longhorn PVCs behind, and the steps to reclaim space and stop it from happening again.
---

# Longhorn Disk Pressure and VolSync Leftover PVCs

> **Status (2026-11-20):** k8s-05 hit DiskPressure at 20:07–20:15 UTC and k8s-06 at 20:15–20:21 UTC; both recovered by themselves.
>
> **Done:**
>
> - Steps 1–3 (21:45–22:04 UTC). They freed about 61 GB on k8s-05 and 44 GB on k8s-06, and Longhorn now keeps 20% free (§4a). Step 3b was skipped.
> - Step 4: `cleanupCachePVC: true` in the component, with the 41 live RDs patched in place.
> - The 5 orphaned RDs were deleted.
> - The §6a cleanup CronJob and the `just kube volsync-cleanup` recipe are deployed. The first dry run completed under BusyBox `ash`, and every run now logs a `START` and a `SUMMARY` line.
> - Step 6 (22:59–23:01 UTC): over-provisioning 120%, default-disk reserved 30%, and 100 GiB Storage Reserved on every disk. Limits are 482 / 280 / 280 GB and the bootstrap worst case is 82% (§4a).
>
> **Next:** once a few scheduled runs show the expected `SUMMARY`, set `DRY_RUN` to `"false"` (§6a, "Operating it"). Log progress in §10.
>
> **Talos v1.14.6 rollout completed at 21:17 UTC** (tuppr, started about 20:30 UTC). Afterwards Longhorn was still rebuilding replicas that were stopped by the reboots: 69 volumes were degraded at 21:20 UTC and 53 at 21:24 UTC. Step 1 is safe now. Wait until the §4 checks show no degraded volumes before steps 2 and 3.

---

## 1. What happened on 2026-11-20

| Time (UTC) | Event |
|---|---|
| 19:58–20:08 | Free space on k8s-05 `/var` fell from 70 GB to 51 GB while Longhorn rebuilt replicas onto it |
| 20:07 | k8s-05: `EvictionThresholdMet` ("Attempting to reclaim ephemeral-storage"), then `NodeHasDiskPressure` |
| 20:10–20:15 | Pods evicted from k8s-05 and images garbage-collected; k8s-05 climbed back to 137 GB free. The evicted pods landed on k8s-06, and Longhorn built local replicas for them there: k8s-06 fell from 80 GB to about 53 GB free |
| 20:15 | k8s-05 `NodeHasNoDiskPressure`; k8s-06 `EvictionThresholdMet`, then `NodeHasDiskPressure` |
| 20:16–20:20 | openebs's `cleanup-pvc-7c4e…` helper pod evicted five times on k8s-06; it finished once the pressure cleared (no folder left behind) |
| 20:21 | k8s-06 `NodeHasNoDiskPressure` (151 GB free by 20:25) |
| 20:30–21:17 | tuppr rolled Talos v1.14.6 across all six nodes (no further DiskPressure) |

No VolSync job ran during the event; the last ReplicationSource before it finished at 17:03 UTC. The trigger was replica rebuild traffic landing on a node that was already close to full. Evictions then bounced the problem to the next node: the evicted pods moved to k8s-06, and `best-effort` data locality made Longhorn build full local replicas there (§2).

**Why 51 GB is the limit:** kubelet's `evictionHard` contains `imagefs.available: 15%` and `nodefs.available: 10%`. On Talos, images, kubelet data, Longhorn (`/var/lib/longhorn`) and openebs-hostpath (`/var/mnt/local-hostpath`) all share the one EPHEMERAL partition (`/dev/sda4`, 341 GB on k8s-05 and k8s-06). 15% of 341 GB is 51 GB. Longhorn is configured to keep only 5% free (`storageMinimalAvailablePercentage: "5"`), so it will place replicas well past the point where kubelet starts evicting.

## 2. Where the space goes (k8s-05, 2026-11-20)

These are real on-disk numbers, not apparent sizes. `talosctl usage` reports sparse Longhorn files at their full size, for example 774 GB of "usage" on a 341 GB disk.

| Item | Size on k8s-05 | Needed? |
|---|---|---|
| Longhorn replicas, total | 143 GB (123 GB after the Talos rollout moved pods) | — |
| …of which `volsync-*-dst-dest` | 42 GB (85 GB cluster-wide, both replicas) | No (see §3) |
| VolSync restore caches `volsync-dst-*-dst-cache` (openebs-hostpath) | 18.5 GB (20.8 GB cluster-wide: k8s-04 0.6, k8s-06 1.7) | No; only a restore uses them |
| VolSync backup caches `volsync-src-*-cache` (openebs-hostpath) | 13.5 GB | **Yes**; every backup uses them |
| containerd images | ~45 GB (apparent size) | kubelet image GC manages these |

Checked and found clean:

- No orphaned Longhorn replicas or `orphans.longhorn.io` objects.
- No hostpath directories without a PV, apart from one empty folder on k8s-04 (`pvc-1d97ac22…`, 6 bytes, from May 2026).
- No PVCs stuck in Terminating.

Longhorn has 97 snapshots marked removed (~89 GB logical), but they hold the base data of their volumes. Purging them would free almost nothing.

Replica placement is uneven. k8s-04 (509 GB) held 30 replicas, while k8s-05 and k8s-06 (341 GB each) held about 92 each. After the rollout and its rebuilds (21:37 UTC) it was 26 / 82 / 82.

**The cause is where the pods run, not `replicaAutoBalance`.** All 95 volumes use `dataLocality: best-effort`, so Longhorn keeps one replica on whichever node the pod runs on. At 20:30 UTC on 2026-11-20, 38 of the 46 attached volumes were attached on k8s-05 (5 on k8s-04, 3 on k8s-06), so k8s-05 held a replica of nearly everything in use. It also means every drain or Talos upgrade that moves a pod makes Longhorn rebuild a full local replica on the new node. That is the kind of burst that filled k8s-05 at 19:58–20:08, and then k8s-06 at 20:10–20:15.

The rollout reshuffled pods. Once the rebuilds finished (21:37 UTC), the 46 attached volumes were spread 16 on k8s-04, 16 on k8s-05 and 14 on k8s-06, so new local replicas no longer pile onto k8s-05. The existing replicas stay where they are (26 / 82 / 82), and every `-dst-dest` replica sits on k8s-05 or k8s-06 (46 each). A count taken at 21:24, during the rebuilds, showed 49 volumes "attached" on k8s-04. That included volumes Longhorn attaches only to rebuild them offline, so count attached volumes only when nothing is degraded.

`replicaAutoBalance` can't fix this. Both `least-effort` and `best-effort` balance *each volume's* replicas across nodes. A 2-replica volume on k8s-05 and k8s-06 already counts as balanced, and neither mode moves it to k8s-04 to even out totals. The related disk-pressure threshold (`replica-auto-balance-disk-pressure-percentage`) only moves replicas between disks *on the same node*, so it does nothing with one disk per node. Leave `replicaAutoBalance` as `least-effort`. See [Longhorn: Auto Balance Replicas](https://longhorn.io/docs/1.10.0/high-availability/auto-balance-replicas/).

## 3. Why VolSync leaves Longhorn PVCs behind

### The Longhorn snapshot problem

The `longhorn` VolumeSnapshotClass uses `type: snap`. A `snap` VolumeSnapshot is a Longhorn snapshot *inside the source volume*, not a separate copy. If the source PVC is deleted, the snapshot's data goes with it. Creating a PVC from that snapshot then fails with `failed to verify data source: volume.longhorn.io "pvc-…" not found`.

On a restore, the ReplicationDestination (RD) restores into a temp PVC `volsync-<app>-dst-dest`. It takes a VolumeSnapshot of that PVC and then deletes the PVC if `cleanupTempPVC: true`. With Longhorn, that leaves a broken snapshot. Upstream tracks this as [backube/volsync#1504](https://github.com/backube/volsync/issues/1504), which is still open. The maintainers treat it as a Longhorn problem and rejected the proposed fix (PR #1520).

The repo works around it with `cleanupTempPVC: false` in [replicationdestination.yaml](../kubernetes/components/volsync/replicationdestination.yaml). The side effect is that every app keeps a full Longhorn copy of its first restore, on `longhorn-fast` with 2 replicas, forever.

### The leftover PVCs aren't a useful restore point

- **The app PVCs are independent.** All 41 app volumes restored by VolSync show `cloneMode=full-copy` and `cloneStatus.state=completed` (checked 2026-11-20). Deleting `-dst-dest` doesn't touch live data.
- **The snapshots are stale.** Each RD uses `trigger.manual: restore-once`, so its `status.latestImage` is the snapshot from the *first* restore. For most apps that is 2025-12-13. Deleting only an app PVC and letting the volume populator rebuild it would restore **data from that date, not the latest backup**. A correct restore always needs a fresh RD sync (§6), and a fresh sync makes a new `-dst-dest` anyway.
- **What deleting them breaks:** only the shortcut of rebuilding an app PVC from the old snapshot. With the snapshot gone, a rebuilt PVC sits Pending with the Longhorn "not found" error instead of silently restoring old data. The real backups are in Kopia on the NAS (`192.168.20.21:/mnt/tank/backups/kopia/repository`).

### The caches

| PVC | Used by | Effect of deleting it |
|---|---|---|
| `volsync-src-<app>-cache` | Every scheduled backup (Kopia index/metadata; Plex's is sized for ~12.9 GB metadata and 3.7 GB content) | Every backup starts cold and re-reads indexes from the NAS. **Keep.** |
| `volsync-dst-<app>-dst-cache` | Only RD restores, which ran once | The next restore starts cold. A restore reads all data from the NAS anyway, so it's slightly slower at most. Safe to delete. |

The caches are on openebs-hostpath, not Longhorn, so the snapshot problem above doesn't affect them.

### What has been tried and doesn't work

- **Single-replica Longhorn for temp/cache PVCs** (`longhorn-single-local`, commits `1a4ca9f7` to `a96db2ed`, 2025-10-17 to 2025-10-19). Pods and replicas landed on different nodes and clone copies failed; the commits ended in "revert everything to working spec". The Longhorn issue closest to this ([longhorn#13335](https://github.com/longhorn/longhorn/issues/13335)) was closed after adding `--retry-interval-max=1m` to `csi-attacher`, and this cluster already has that change. The failure where a copy is cut off mid-way and restarts from 0% was never fixed, so **don't retry this**.
- **Removing finalizers from `volsync-<app>-src` after the snapshot** (the commented-out `actions.afterSnapshot` in [replicationsource.yaml](../kubernetes/components/volsync/replicationsource.yaml)). It isn't needed now (nothing is stuck) and can delete data that is still in use. Delete the comment.

## 4. Before you start

Run these first, and wait until all four are true.

```bash
# 0. No Talos upgrade rolling through the nodes (expect Completed)
kubectl get talosupgrade -A

# 1. No node under pressure, no Longhorn volume rebuilding or attaching/detaching
kubectl get nodes -o custom-columns=N:.metadata.name,DP:'.status.conditions[?(@.type=="DiskPressure")].status'
kubectl -n storage get volumes.longhorn.io -o json \
  | jq -r '.items[] | select((.status.state|test("attaching|detaching")) or .status.robustness=="degraded") | .metadata.name'

# 2. No VolSync mover running
kubectl get jobs -A -l app.kubernetes.io/created-by=volsync

# 3. Every ReplicationSource's last backup succeeded
kubectl get replicationsources -A -o json \
  | jq -r '.items[] | [.metadata.namespace,.metadata.name,.status.lastSyncTime,(.status.latestMoverStatus.result//"-")] | @tsv' \
  | column -t
```

If a backup is old or failed, take one before deleting anything: `just kube snapshot <namespace> <pvc>`.

## 4a. Usage metrics: baseline and what to expect after each step

Take a snapshot before starting and after each step, and compare it with the expected column. The script below is read-only and prints Markdown tables you can paste into "Recorded snapshots" at the end of this section.

### Snapshot script

Save it as `longhorn-usage-snapshot.sh` and run it from the repo root with `TALOSCONFIG=./talosconfig bash longhorn-usage-snapshot.sh`. It needs `kubectl`, `jq` and `talosctl`, and works with the macOS system bash. It takes about a minute, mostly for `talosctl usage`.

```bash
#!/usr/bin/env bash
# Read-only usage snapshot for the Longhorn / VolSync cleanup (docs/longhorn-disk-pressure-volsync.md §4a).
# Needs kubectl, jq and talosctl (TALOSCONFIG set). Works with macOS bash 3.2.
set -euo pipefail
NODES="k8s-04 k8s-05 k8s-06"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

kubectl -n storage get volumes.longhorn.io -o json > "$T/v.json"
kubectl -n storage get replicas.longhorn.io -o json > "$T/r.json"
kubectl -n storage get nodes.longhorn.io -o json > "$T/n.json"
kubectl -n storage get settings.longhorn.io -o json > "$T/s.json"
kubectl get pvc -A -o json > "$T/pvc.json"
kubectl get volumesnapshot -A -o json > "$T/vs.json"
kubectl get replicationdestinations -A -o json > "$T/rd.json"
kubectl get replicationsources -A -o json > "$T/rs.json"

echo "Snapshot: $(date -u '+%Y-%m-%d %H:%M UTC')"
echo
echo "| Node | /var free | Longhorn provisioned / limit | Replicas | Attached vols | dst-cache | src-cache |"
echo "|---|---|---|---|---|---|---|"
for node in $NODES; do
  ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  fs=$(kubectl get --raw "/api/v1/nodes/$node/proxy/stats/summary" | jq -r '.node.fs | "\(.availableBytes/1e9|floor) GB (\(100*.availableBytes/.capacityBytes|floor)%)"')
  lh=$(jq -r --arg n "$node" --slurpfile s "$T/s.json" '
    ($s[0].items[] | select(.metadata.name=="storage-over-provisioning-percentage") | .value | tonumber) as $op
    | .items[] | select(.metadata.name==$n)
    | (.spec.disks | to_entries[0].value.storageReserved) as $res
    | .status.diskStatus | to_entries[0].value
    | ((.storageMaximum - $res) * $op / 100) as $lim
    | "\(.storageScheduled/1e9|floor) / \($lim/1e9|floor) GB (\(100*.storageScheduled/$lim|floor)%)"' "$T/n.json")
  reps=$(jq --arg n "$node" '[.items[] | select(.spec.nodeID==$n)] | length' "$T/r.json")
  att=$(jq --arg n "$node" '[.items[] | select(.status.state=="attached" and .status.currentNodeID==$n)] | length' "$T/v.json")
  # hostpath usage by PVC type (real usage; openebs-hostpath is not sparse)
  if talosctl -n "$ip" usage /var/mnt/local-hostpath --depth 1 > "$T/hp.txt" 2>/dev/null; then
    hp=$(awk 'NR>1 && $2 ~ /^pvc-/ {print $2"\t"$1}' "$T/hp.txt" | jq -R -s --slurpfile p "$T/pvc.json" '
      (split("\n") | map(select(length>0) | split("\t") | {(.[0]): (.[1]|tonumber)}) | add // {}) as $u
      | [$p[0].items[] | select(.spec.storageClassName=="openebs-hostpath") | {n:.metadata.name, b:($u[.spec.volumeName] // 0)}]
      | "\(([.[]|select(.n|test("dst-cache$"))|.b]|add // 0)/1e9*10|floor/10) GB | \(([.[]|select(.n|test("^volsync-src-.*-cache$"))|.b]|add // 0)/1e9*10|floor/10) GB"' -r)
  else hp="n/a | n/a"; fi
  echo "| $node | $fs | $lh | $reps | $att | $hp |"
done
echo

jq -n -r --slurpfile v "$T/v.json" --slurpfile n "$T/n.json" --slurpfile s "$T/s.json" --slurpfile p "$T/pvc.json" \
      --slurpfile vs "$T/vs.json" --slurpfile rd "$T/rd.json" --slurpfile rs "$T/rs.json" '
  def gb: . / 1e9 | floor;
  def setting($k): $s[0].items[] | select(.metadata.name==$k) | .value;
  (setting("storage-over-provisioning-percentage") | tonumber) as $op
  | ($p[0].items | map(select(.spec.dataSourceRef.kind? == "ReplicationDestination"))) as $appPvcs
  | ($appPvcs | map(.spec.volumeName)) as $appVols
  | ($v[0].items | map({name:.metadata.name, pvc:(.status.kubernetesStatus.pvcName // ""), size:(.spec.size|tonumber), act:.status.actualSize, r:.spec.numberOfReplicas, rob:.status.robustness})) as $vols
  | ($vols | map(select(.name as $x | $appVols | index($x)))) as $app
  | ($vols | map(select(.pvc | test("^volsync-.*-dst-dest$")))) as $dd
  | ($vols | map(select((.name as $x | $appVols | index($x) | not) and (.pvc | test("^volsync-.*-dst-dest$") | not)))) as $other
  | ([$n[0].items[] | (.spec.disks | to_entries[0].value.storageReserved) as $res | .status.diskStatus | to_entries[0].value | (.storageMaximum - $res) * $op / 100] | add) as $limit
  | ([$n[0].items[] | .status.diskStatus | to_entries[0].value.storageScheduled] | add) as $sched
  | ([$rs[0].items[] | .metadata.namespace + "/" + .metadata.name]) as $rsNames
  | ([$rd[0].items[] | (.metadata.namespace + "/" + (.metadata.name | sub("-dst$"; ""))) as $app
       | .metadata.name as $rdn | .metadata.namespace as $ns
       | select(([$appPvcs[] | select(.metadata.namespace==$ns and .spec.dataSourceRef.name==$rdn)] | length) == 0 and ($rsNames | index($app) | not))]) as $orphans
  | "| Metric | Value |",
    "|---|---|",
    "| Longhorn volumes / degraded | \($vols|length) / \([$vols[]|select(.rob=="degraded")]|length) |",
    "| Longhorn data, one copy (actual) | \([$vols[]|.act]|add|gb) GB |",
    "| Longhorn data, all replicas (actual) | \([$vols[]|.act*.r]|add|gb) GB |",
    "| …of which `-dst-dest`, all replicas (actual) | \([$dd[]|.act*.r]|add // 0|gb) GB |",
    "| Longhorn provisioned, all replicas / limit | \($sched|gb) / \($limit|gb) GB (\(100*$sched/$limit|floor)%) |",
    "| Bootstrap worst case (3 × app + other) / limit | \((3*([$app[]|.size*.r]|add) + ([$other[]|.size*.r]|add))|gb) / \($limit|gb) GB (\(100*(3*([$app[]|.size*.r]|add) + ([$other[]|.size*.r]|add))/$limit|floor)%) |",
    "| `-dst-dest` PVCs / VolumeSnapshots | \([$p[0].items[]|select(.metadata.name|test("^volsync-.*-dst-dest$"))]|length) / \([$vs[0].items[]|select(.spec.source.persistentVolumeClaimName? // "" | test("^volsync-.*-dst-dest$"))]|length) |",
    "| `-dst-cache` PVCs | \([$p[0].items[]|select(.metadata.name|test("^volsync-dst-.*-dst-cache$"))]|length) |",
    "| Orphaned ReplicationDestinations | \($orphans|length) |",
    "| Setting: minimal available / over-provisioning | \(setting("storage-minimal-available-percentage"))% / \($op)% |"'
```

**What the columns mean:**

- **/var free:** kubelet's view of the EPHEMERAL partition. kubelet evicts pods below 15% free (51 GB on k8s-05 and k8s-06).
- **Longhorn provisioned / limit:** the sum of the provisioned sizes of the replicas on that disk, against (disk − reserved) × over-provisioning %. New replicas fail to schedule when they would push it past 100%.
- **Bootstrap worst case:** the §6a estimate. It only changes with the over-provisioning setting or PVC sizes, not with cleanup.
- **dst-cache / src-cache:** real hostpath usage. `src-cache` must not drop; those are the backup caches.

### Expected values

Baseline taken 2026-11-20 21:37 UTC, after the Talos rollout and with all rebuilds finished. The expected numbers are the baseline minus what each step removes. `/var` free also moves a few GB with images and logs, so treat it as ± 5 GB.

| Metric | Baseline | After step 1 | After step 2 | After step 3 | After step 6 (120%, 100 GiB reserved) |
|---|---|---|---|---|---|
| k8s-04 /var free | 391 GB (76%) | ~391 GB | ~391 GB | unchanged | unchanged |
| k8s-05 /var free | 99 GB (29%) | ~117 GB (34%) | ~160 GB (47%) | unchanged | unchanged |
| k8s-06 /var free | 107 GB (31%) | ~109 GB (32%) | ~151 GB (44%) | unchanged | unchanged |
| k8s-04 provisioned / limit | 80 / 372 GB (21%) | same | same | same | ~79 / 482 GB (16%) |
| k8s-05 provisioned / limit | 255 / 306 GB (83%) | same | ~152 / 306 GB (50%) | same | ~153 / 280 GB (54%) |
| k8s-06 provisioned / limit | 269 / 306 GB (87%) | same | ~166 / 306 GB (54%) | same | ~166 / 280 GB (59%) |
| Replicas k8s-04 / 05 / 06 | 26 / 82 / 82 | same | 26 / 36 / 36 | same | same |
| dst-cache k8s-04 / 05 / 06 | 0.5 / 18.5 / 1.7 GB | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| src-cache k8s-04 / 05 / 06 | 9.6 / 13.5 / 6.4 GB | **must not drop** | same | same | same |
| Longhorn volumes / degraded | 95 / 0 | 95 / 0 | 49 / 0 | 49 / 0 | 49 / 0 |
| Longhorn data, all replicas | 296 GB | 296 GB | ~211 GB | same | same |
| …of which `-dst-dest` | 85 GB | 85 GB | 0 | 0 | 0 |
| Longhorn provisioned / limit | 605 / 985 GB (61%) | same | ~399 / 985 GB (40%) | same | ~399 / 1,043 GB (38%) |
| Bootstrap worst case / limit | 858 / 985 GB (87%) | same | same | same | 858 / 1,043 GB (82%) |
| `-dst-dest` PVCs / VolumeSnapshots | 46 / 46 | 46 / 46 | 0 / 0 | 0 / 0 | 0 / 0 |
| `-dst-cache` PVCs | 46 | 0 | 0 | 0 | 0 |
| Orphaned ReplicationDestinations | 5 | 5 | 5 (their PVCs and snapshots are gone; the RD objects remain until deleted, see §6a) | 5 | 0 (deleted 2026-11-20) |
| Minimal available / over-provisioning | 5% / 100% | same | same | 20% / 100% | 20% / 120% |

**Stop and investigate if:**

- any volume is degraded more than a few minutes after a step;
- `src-cache` shrinks;
- `/var` free on a node drops instead of rising;
- after step 3, a Longhorn disk shows `Schedulable=False` (§5 step 3 verify command) while it is still above 20% free.

### Watching trends in Grafana (Explore → Prometheus)

| What | PromQL |
|---|---|
| `/var` free % per worker | `100 * node_filesystem_avail_bytes{mountpoint="/var",instance=~".*30.2[456].*"} / node_filesystem_size_bytes{mountpoint="/var",instance=~".*30.2[456].*"}` |
| Longhorn provisioned % of (disk − reserved), per node | `100 * max by (node) (longhorn_node_storage_scheduled_bytes) / max by (node) (longhorn_node_storage_capacity_bytes - longhorn_node_storage_reservation_bytes)` (assumes 100% over-provisioning) |
| Longhorn used GB per node | `max by (node) (longhorn_node_storage_usage_bytes) / 1e9` |
| `-dst-dest` data, one copy | `sum(max by (volume) (longhorn_volume_actual_size_bytes{pvc=~"volsync-.*-dst-dest"})) / 1e9` |
| Degraded volumes (robustness 2 = degraded, 1 = healthy) | `count(max by (volume) (longhorn_volume_robustness) == 2) or vector(0)` |

At the 2026-11-20 baseline these returned:

- provisioned 21% / 83% / 87%;
- used 118 / 242 / 234 GB;
- `-dst-dest` 43 GB;
- all 95 volumes with robustness 1.

Prometheus keeps 30 days, so take the script snapshots too; they don't expire.

### Recorded snapshots

**Baseline (2026-11-20 21:37 UTC):**

| Node | /var free | Longhorn provisioned / limit | Replicas | Attached vols | dst-cache | src-cache |
|---|---|---|---|---|---|---|
| k8s-04 | 391 GB (76%) | 80 / 372 GB (21%) | 26 | 16 | 0.5 GB | 9.6 GB |
| k8s-05 | 99 GB (29%) | 255 / 306 GB (83%) | 82 | 16 | 18.5 GB | 13.5 GB |
| k8s-06 | 107 GB (31%) | 269 / 306 GB (87%) | 82 | 14 | 1.7 GB | 6.4 GB |

| Metric | Value |
|---|---|
| Longhorn volumes / degraded | 95 / 0 |
| Longhorn data, one copy (actual) | 148 GB |
| Longhorn data, all replicas (actual) | 296 GB |
| …of which `-dst-dest`, all replicas (actual) | 85 GB |
| Longhorn provisioned, all replicas / limit | 605 / 985 GB (61%) |
| Bootstrap worst case (3 × app + other) / limit | 858 / 985 GB (87%) |
| `-dst-dest` PVCs / VolumeSnapshots | 46 / 46 |
| `-dst-cache` PVCs | 46 |
| Orphaned ReplicationDestinations | 5 |
| Setting: minimal available / over-provisioning | 5% / 100% |

2**After step 1 (2026-11-20 21:45 UTC):** everything matched the expected column. The openebs cleanup pods removed every released hostpath PV within about a minute.

| Node | /var free | Longhorn provisioned / limit | Replicas | Attached vols | dst-cache | src-cache |
|---|---|---|---|---|---|---|
| k8s-04 | 391 GB (76%) | 80 / 372 GB (21%) | 26 | 16 | 0 GB | 9.6 GB |
| k8s-05 | 118 GB (34%) | 255 / 306 GB (83%) | 82 | 16 | 0 GB | 13.5 GB |
| k8s-06 | 108 GB (31%) | 269 / 306 GB (87%) | 82 | 14 | 0 GB | 6.4 GB |

| Metric | Value |
|---|---|
| Longhorn volumes / degraded | 95 / 0 |
| Longhorn data, one copy (actual) | 148 GB |
| Longhorn data, all replicas (actual) | 297 GB |
| …of which `-dst-dest`, all replicas (actual) | 85 GB |
| Longhorn provisioned, all replicas / limit | 605 / 985 GB (61%) |
| Bootstrap worst case (3 × app + other) / limit | 858 / 985 GB (87%) |
| `-dst-dest` PVCs / VolumeSnapshots | 46 / 46 |
| `-dst-cache` PVCs | 0 |
| Orphaned ReplicationDestinations | 5 |
| Setting: minimal available / over-provisioning | 5% / 100% |

If `talosctl usage` prints `n/a` for a node's cache columns, openebs is still deleting folders there; it fails when files vanish mid-scan. Wait until `kubectl get pv` shows no `Released` openebs-hostpath PVs and no `cleanup-pvc-*` pods in `storage`, then re-run the script.

**After step 2 (2a homepage test 21:53, 2b the remaining 45, snapshot 2026-11-20 21:58 UTC):** everything matched the expected column.

- **Freed:** about 43 GB on each of k8s-05 and k8s-06 (`/var` 117 → 160 GB and 108 → 151 GB). Provisioned space on those two nodes dropped by 103 GB each, and they lost 46 replicas each.
- **Nothing left behind:** no VolumeSnapshotContents, Longhorn volumes or Longhorn orphans remain for `-dst-dest`, and no PVC is stuck terminating.
- **No side effects:** all 41 backups `Successful`, all 46 RDs `WaitingForManual`, no DiskPressure.
- **Unrelated, found during the check:** `karakeep-meilisearch` was Pending on CPU/memory plus pod affinity to karakeep's node since the Talos rollout, and 42 old `cilium-operator` pods sat in `ContainerStatusUnknown`.

| Node | /var free | Longhorn provisioned / limit | Replicas | Attached vols | dst-cache | src-cache |
|---|---|---|---|---|---|---|
| k8s-04 | 391 GB (76%) | 80 / 372 GB (21%) | 26 | 16 | 0 GB | 9.6 GB |
| k8s-05 | 160 GB (47%) | 152 / 306 GB (49%) | 36 | 16 | 0 GB | 13.5 GB |
| k8s-06 | 151 GB (44%) | 166 / 306 GB (54%) | 36 | 14 | 0 GB | 6.4 GB |

| Metric | Value |
|---|---|
| Longhorn volumes / degraded | 49 / 0 |
| Longhorn data, one copy (actual) | 106 GB |
| Longhorn data, all replicas (actual) | 212 GB |
| …of which `-dst-dest`, all replicas (actual) | 0 GB |
| Longhorn provisioned, all replicas / limit | 399 / 985 GB (40%) |
| Bootstrap worst case (3 × app + other) / limit | 858 / 985 GB (87%) |
| `-dst-dest` PVCs / VolumeSnapshots | 0 / 0 |
| `-dst-cache` PVCs | 0 |
| Orphaned ReplicationDestinations | 5 |
| Setting: minimal available / over-provisioning | 5% / 100% |

**Totals since the baseline:** k8s-05 `/var` free 99 → 160 GB (29% → 47%), k8s-06 107 → 151 GB (31% → 44%). Longhorn holds 84 GB less data across all replicas (296 → 212 GB) and 206 GB less provisioned space (605 → 399 GB), and has 46 fewer volumes (95 → 49).

**After step 3 (commit `6562b6b8`, Helm upgrade `longhorn.v48` succeeded 22:04 UTC):**

- The live setting is `storage-minimal-available-percentage = 20`.
- All three disks are still `Schedulable=True` (76% / 46% / 44% free).
- 49 volumes, 0 degraded; no space change, as expected.
- During the Helm upgrade (about a minute), the HelmRelease showed `Ready=Unknown Progressing` and the snapshot script failed while Longhorn objects were being updated. Wait for `Ready=True` before taking the snapshot.
- Step 3b was skipped by decision.

| Node | /var free | Longhorn provisioned / limit | Replicas | Attached vols | dst-cache | src-cache |
|---|---|---|---|---|---|---|
| k8s-04 | 388 GB (76%) | 80 / 372 GB (21%) | 26 | 16 | 0 GB | 9.6 GB |
| k8s-05 | 160 GB (46%) | 152 / 306 GB (49%) | 36 | 16 | 0 GB | 13.5 GB |
| k8s-06 | 150 GB (44%) | 166 / 306 GB (54%) | 36 | 14 | 0 GB | 6.4 GB |

| Metric | Value |
|---|---|
| Longhorn volumes / degraded | 49 / 0 |
| Longhorn data, one copy (actual) | 106 GB |
| Longhorn data, all replicas (actual) | 212 GB |
| …of which `-dst-dest`, all replicas (actual) | 0 GB |
| Longhorn provisioned, all replicas / limit | 399 / 985 GB (40%) |
| Bootstrap worst case (3 × app + other) / limit | 858 / 985 GB (87%) |
| `-dst-dest` PVCs / VolumeSnapshots | 0 / 0 |
| `-dst-cache` PVCs | 0 |
| Orphaned ReplicationDestinations | 5 |
| Setting: minimal available / over-provisioning | 20% / 100% |

**After step 6 (commit `0a3914b9`; Helm upgrade live 23:00 UTC; Storage Reserved 100 GiB set in the UI; snapshot 2026-11-20 23:01 UTC):** everything matched the expected column.

- Limits are 482 / 280 / 280 GB, with provisioned space at 16 / 54 / 59% of them.
- The cluster is at 399 / 1,043 GB (38%), and the bootstrap worst case is 82%.
- All disks are `Schedulable=True`, and the orphans are gone.
- The fill ratio is 216 / 399 GB = 54%, against a break-even of 61–64%.
- The UI change was made before Flux had applied 120%. For about 15 minutes the limits were 402 / 233 / 233 GB; that was harmless, with nothing being scheduled at the time.

| Node | /var free | Longhorn provisioned / limit | Replicas | Attached vols | dst-cache | src-cache |
|---|---|---|---|---|---|---|
| k8s-04 | 376 GB (73%) | 79 / 482 GB (16%) | 25 | 15 | 0 GB | 9.6 GB |
| k8s-05 | 156 GB (45%) | 153 / 280 GB (54%) | 37 | 17 | 0 GB | 13.5 GB |
| k8s-06 | 149 GB (43%) | 166 / 280 GB (59%) | 36 | 14 | 0 GB | 6.4 GB |

| Metric | Value |
|---|---|
| Longhorn volumes / degraded | 49 / 0 |
| Longhorn data, one copy (actual) | 108 GB |
| Longhorn data, all replicas (actual) | 216 GB |
| …of which `-dst-dest`, all replicas (actual) | 0 GB |
| Longhorn provisioned, all replicas / limit | 399 / 1043 GB (38%) |
| Bootstrap worst case (3 × app + other) / limit | 858 / 1043 GB (82%) |
| `-dst-dest` PVCs / VolumeSnapshots | 0 / 0 |
| `-dst-cache` PVCs | 0 |
| Orphaned ReplicationDestinations | 0 |
| Setting: minimal available / over-provisioning | 20% / 120% |

## 5. The plan

### Step 1: Delete the restore caches (do now; safe)

Frees about 20.8 GB: 18.5 GB on k8s-05, 1.7 GB on k8s-06 and 0.6 GB on k8s-04. All 46 RDs are idle (`WaitingForManual`, re-checked after the rollout), so nothing recreates the caches until the next restore.

```bash
# Confirm nothing mounts them (expect no output)
kubectl get pods -A -o json | jq -r '.items[] | .metadata.namespace as $ns | .metadata.name as $p
  | .spec.volumes[]? | select((.persistentVolumeClaim.claimName? // "") | test("dst-cache$")) | "\($ns)/\($p)"'

# Delete
kubectl get pvc -A --no-headers | awk '$2 ~ /^volsync-dst-.*-dst-cache$/ {print $1, $2}' \
  | while read -r ns n; do kubectl -n "$ns" delete pvc "$n"; done
```

The openebs PVs have `reclaimPolicy: Delete`, so the provisioner removes the directories. Verify:

```bash
kubectl get pvc -A --no-headers | grep -c 'dst-cache$'          # expect 0
talosctl -n 192.168.30.25 mounts | grep -E ' /var$'              # free space up
```

### Step 2: Delete the `-dst-dest` PVCs and their snapshots (optional; read §3 first)

Frees 42 GB on k8s-05 and 85 GB of replica space cluster-wide. Afterwards, restores must follow §6, which they already should.

**Order matters:** delete the VolumeSnapshot first and wait for it to go, then the PVC. The snapshot's data lives in the PVC's Longhorn volume. If the volume goes first, the snapshot deletion has nothing to act on and can get stuck.

#### 2a. Test on one small app (homepage, 1 Gi)

```bash
ns=default app=homepage
snap=$(kubectl -n $ns get replicationdestination ${app}-dst -o jsonpath='{.status.latestImage.name}'); echo "$snap"
kubectl -n $ns delete volumesnapshot "$snap" --wait=true --timeout=5m
kubectl -n $ns delete pvc volsync-${app}-dst-dest --wait=true --timeout=5m

# Make Flux and VolSync reconcile, then confirm nothing came back
flux -n $ns reconcile ks $app --with-source
kubectl -n $ns get pvc volsync-${app}-dst-dest                 # expect NotFound
kubectl -n $ns get replicationdestination ${app}-dst -o jsonpath='{.status.conditions}' | jq .
kubectl -n storage logs deploy/volsync --since=15m | grep -i "${app}-dst"
```

**Pass condition:** after the next hourly Flux reconcile, the PVC is still gone, the RD shows `WaitingForManual` without errors, and the app keeps running. Its next scheduled backup (Thursday 09:00 UTC for homepage, `0 9 * * 4`; the README table says 04:00, which is out of date) also succeeds. To speed up that last check, run `just kube snapshot default homepage`.

**Note on `just kube snapshot`:** it patches `spec.trigger.manual`, and VolSync gives a manual trigger precedence over the schedule (`getTrigger`). Until Flux's next reconcile of that app's Kustomization, the backup source shows `WaitingForManual` and has no `nextSyncTime`. Flux then removes the field: kustomize-controller takes over fields owned by managers whose names start with `kubectl` (prefix match in `fluxcd/pkg/ssa` `matchFieldManager`), and that covers `kubectl-patch`. The schedule then applies again. Expected, not a fault.

#### 2b. All the rest

```bash
kubectl get volumesnapshot -A -o json \
  | jq -r '.items[] | select(.spec.source.persistentVolumeClaimName? // "" | test("^volsync-.*-dst-dest$"))
           | [.metadata.namespace, .metadata.name, .spec.source.persistentVolumeClaimName] | @tsv' \
  | while IFS=$'\t' read -r ns snap pvc; do
      echo "== $ns/$pvc"
      kubectl -n "$ns" delete volumesnapshot "$snap" --wait=true --timeout=5m \
        && kubectl -n "$ns" delete pvc "$pvc" --wait=true --timeout=5m
    done

# Verify
kubectl get pvc -A --no-headers | grep -c 'dst-dest$'                         # expect 0
kubectl get volumesnapshot -A --no-headers | grep -c 'dst-dest'                # expect 0
kubectl -n storage get volumes.longhorn.io --no-headers | wc -l                # 95 → ~49
```

If a VolumeSnapshot hangs in deletion, check `kubectl -n <ns> describe volumesnapshot <name>` and the `csi-snapshotter` logs before removing finalizers by hand.

### Step 3: Stop Longhorn from filling nodes into DiskPressure (do after steps 1 and 2)

Edit [kubernetes/apps/storage/longhorn/app/helmrelease.yaml](../kubernetes/apps/storage/longhorn/app/helmrelease.yaml):

```diff
     defaultSettings:
 ...
-      storageMinimalAvailablePercentage: "5"
+      storageMinimalAvailablePercentage: "20"
       storageReservedPercentageForDefaultDisk: "15"
```

**What it changes:** Longhorn stops placing a *new* replica on a disk whose actual free space would fall below 20% (68 GB on a 341 GB node). New replicas come from new PVCs, rebuilds, locality moves and the VolSync temp `-src` clones. This keeps Longhorn above kubelet's 15% eviction threshold.

**It also gates PVC expansion:** in v1.13.0, `ValidateDiskAvailableForExpansion` refuses to grow a volume if any replica's disk would drop below this percentage of free space.

**What it doesn't change:**

- Existing PVC sizes, and how much existing volumes can write.
- How much you can provision. That limit comes from `storageReservedPercentageForDefaultDisk: "15"` and `storage-over-provisioning-percentage: 100`. Together they allow about 290 GB of *provisioned* size per 341 GB disk; k8s-05 had 266 GB scheduled on 2026-11-20.

**The real cost:** Longhorn can fill a disk to 80% used instead of 95%. Usage between 85% and 95% already triggers kubelet evictions, so only the 80–85% band is lost: about 17 GB per 341 GB node. `"17"` keeps more of that band with a smaller margin; `"20"` leaves room for a large replica (Prometheus is 21 GB) landing at the edge.

**Caveat:** `replica-soft-anti-affinity` is `false` and there are only three storage nodes. While a node is below 20% free, 3-replica volumes (`longhorn` class) can't rebuild a replica there, and new 3-replica volumes run degraded. 2-replica volumes, including the VolSync temp `-src` clones, still schedule on the other two nodes. That is the intended trade (a degraded volume instead of evictions), but it's why steps 1 and 2 come first. After the 2026-11-20 rollout (21:24 UTC), free space was k8s-04 76%, k8s-05 29%, k8s-06 32%.

Commit and push, let Flux reconcile, then verify:

```bash
kubectl -n storage get settings.longhorn.io storage-minimal-available-percentage \
  -o custom-columns=N:.metadata.name,V:.value --no-headers
# A node below the threshold shows a "Schedulable" condition of False on its disk
kubectl -n storage get nodes.longhorn.io -o json | jq -r '.items[] | .metadata.name as $n
  | .status.diskStatus[] | [$n, (.storageAvailable/1e9|floor), (.conditions[]|select(.type=="Schedulable")|.status)] | @tsv'
```

### Step 3b: Spread the load off k8s-05 (optional; decide after watching it)

> **After the 2026-11-20 rollout:** pods are now spread evenly (§2), but replicas aren't (26 / 82 / 82). Step 2 alone takes 46 replicas off each of k8s-05 and k8s-06 (§4a). Re-check the per-node numbers in §4a after step 2, and only rebalance by hand if k8s-05 or k8s-06 is still much fuller than k8s-04.

#### What Longhorn v1.13.0 can and can't do (checked against the live settings API and the longhorn-manager source)

- **No setting balances replicas across nodes by disk usage.**
  - `replica-auto-balance` (global, or per volume through `spec.replicaAutoBalance`) only balances each volume's replica count across nodes and zones. With 3 nodes, hard node anti-affinity (`replica-soft-anti-affinity: false`) and at most 3 replicas per volume, every volume is already balanced. `least-effort` and `best-effort` behave the same here.
  - `replica-auto-balance-disk-pressure-percentage` "rebuilds replicas that are under disk pressure on another disk within the same node". It needs `best-effort` and more than one disk per node, so it does nothing here.
- **New replicas already go to the right node.** Apart from the local replica that data locality places, the scheduler (`getDiskWithMostBalanceScore`) puts a new replica on the node that leaves usable storage most even. Today that is k8s-04. So moving a replica means *deleting* it from the full node and letting Longhorn rebuild it.
- **No per-replica eviction.** `evictionRequested` is set per node or per disk, and the node controller copies it onto every replica. Setting it on a single replica gets overwritten.
- **Which replica Longhorn deletes when a volume has one too many** (v1.13.0 `cleanupExtraHealthyReplicas`):
  - It removes eviction-requested replicas first.
  - On an *attached* volume with locality on, it removes the **non-local replica whose name sorts first**, which is effectively random.
  - Otherwise it removes the replica on the disk with the **least free space**.

#### Upstream status (researched 2026-11-20)

| Issue | What it is | Status |
|---|---|---|
| [longhorn#10512](https://togithub.com/longhorn/longhorn/issues/10512) | "Replica Auto Balance Across Nodes based on Node Disk Space Consumption". Design: LEP [longhorn#11922](https://togithub.com/longhorn/longhorn/pull/11922), `enhancements/20251001-replica-balance-scheduling.md`. Replaces "pick the disk with the most free space" with a balance-aware choice: simulate each placement, then pick the one that leaves usable storage most even, across nodes first and then across disks | **Shipped in v1.11.0** (closed 2025-11-20), so it's in v1.13.0 as `getDiskWithMostBalanceScore`. **New replicas only.** The design doc says it "only improves the disk selection stage"; it never moves existing replicas |
| [longhorn#2977](https://togithub.com/longhorn/longhorn/issues/2977) | "Support automatic rebalance the replicas based on disk usage": move *existing* replicas off fuller disks and nodes | Open since 2021, Backlog. A maintainer's only comment: consider it "next time we do a refactor" of the scheduler |
| [longhorn#11135](https://togithub.com/longhorn/longhorn/issues/11135) | UI / API option to move a specific replica to a chosen node | Open, Backlog; needs a design doc (LEP) first |
| [longhorn#14415](https://togithub.com/longhorn/longhorn/issues/14415) | "auto balance not working as expected (1.13)" | Open; a user-configuration question still in discussion, not a confirmed gap |
| *(none found)* | When data locality removes a surplus replica, prefer the one on the fullest disk | **Not filed.** `cleanupDataLocalityReplicas` deletes the non-local replica with the alphabetically smallest name (same on master as in v1.13.0), while `cleanupAutoBalancedReplicas` already sorts by free space (`getSortedReplicasByAscendingStorageAvailable`). Reusing that helper is a small, contained change and a candidate issue to file |

**What this means here:** the only space-aware mechanism Longhorn has, #10512, works on new and rebuilt replicas. With step 6's settings it strongly favors k8s-04. In the placement score (`StorageAvailable − StorageReserved − StorageScheduled`), on 2026-11-20 23:05 UTC:

| Node | Room in the placement score |
|---|---|
| k8s-04 | 189 GB (47%) |
| k8s-05 | 0 GB |
| k8s-06 | 0 GB |

Every rebuild that is allowed to land on k8s-04 (after a drain or upgrade, a new PVC, a VolSync `-src` clone) goes there, so the imbalance corrects itself as replicas churn. Two exceptions:

- a pod's own local replica, which follows the pod;
- the name-based deletion above, which can still remove the k8s-04 copy when a pod moves.

To move a replica now, delete it as described below; it's rebuilt on k8s-04.

#### Manual rebalance (after the Talos rollout and step 2)

After step 2, roughly 25 GB of replicas could move off k8s-05 and about 40 GB off k8s-06 (estimated 2026-11-20; the numbers shift as pods move). The largest are the Prometheus DB (21.8 GB on k8s-06), postgres-1 and postgres-2 (about 10.5 GB each), radarr (4.3 GB) and victoria-logs (4.3 GB).

List the candidates: healthy 2-replica volumes with no replica on k8s-04, showing the replica that can move.

```bash
kubectl -n storage get volumes.longhorn.io -o json > /tmp/lh-vols.json
kubectl -n storage get replicas.longhorn.io -o json > /tmp/lh-reps.json
jq -r --slurpfile r /tmp/lh-reps.json '.items[]
  | select(.spec.numberOfReplicas==2 and .status.robustness=="healthy")
  | .metadata.name as $v | (.status.currentNodeID // "") as $att
  | [$r[0].items[] | select(.spec.volumeName==$v and .status.currentState=="running")] as $rs
  | select(($rs|length)==2 and ([$rs[].spec.nodeID]|index("k8s-04")|not))
  | ($rs | map(select(.spec.nodeID != $att)) | sort_by(.spec.nodeID) | last) as $mv
  | [(.status.actualSize/1e9*10|floor/10), .status.kubernetesStatus.pvcName, $v, (if $att=="" then "detached" else $att end), $mv.metadata.name, $mv.spec.nodeID] | @tsv' /tmp/lh-vols.json \
  | sort -g -r | column -t
```

Move them **one volume at a time**, and wait for `healthy` before starting the next.

- **Detached volumes (stays at 2+ replicas the whole time):**
  ```bash
  vol=<longhorn volume name>
  kubectl -n storage patch volumes.longhorn.io $vol --type merge -p '{"spec":{"numberOfReplicas":3}}'
  kubectl -n storage get replicas.longhorn.io -l longhornvolume=$vol -w      # wait: third replica on k8s-04, running
  kubectl -n storage patch volumes.longhorn.io $vol --type merge -p '{"spec":{"numberOfReplicas":2}}'
  kubectl -n storage get replicas.longhorn.io -l longhornvolume=$vol -o custom-columns=N:.metadata.name,NODE:.spec.nodeID
  ```
  Longhorn removes the replica on the fullest disk. Confirm on the first one before relying on it.
- **Attached volumes:** the trick above would delete one of the two non-local replicas at random, possibly the new k8s-04 copy. Instead, delete the non-local replica that the list shows:
  ```bash
  kubectl -n storage delete replicas.longhorn.io <replica name from the list>
  kubectl -n storage get replicas.longhorn.io -l longhornvolume=$vol -w      # new replica should schedule on k8s-04
  ```
  The volume runs on its single local replica until the rebuild finishes. Rebuilds take minutes for small volumes and longer for Prometheus. Do the large ones when nothing else is happening, and never while another volume is degraded.

**It won't stay balanced.** With `best-effort` locality, the next time a pod moves to a node without a replica (a drain, an upgrade, an eviction), Longhorn builds a local replica there. It then deletes one of the non-local replicas by name, so the k8s-04 copy may go. A manual rebalance lasts until pods move again. The lasting fix is one of the two levers below.

#### Lasting fixes

There are two levers:

- **Spread the pods.** With `best-effort` locality, replicas follow the pods. Find out why 38 of 46 attached volumes run on k8s-05: k8s-04's freezes, node affinity, GPU placement, or just where pods landed after the last drain. Spreading those pods spreads the replicas with them.
- **Turn locality off** (`dataLocality: disabled`).
  - *Gain:* replicas stay wherever Longhorn first placed them, and drains and upgrades stop triggering full local rebuilds.
  - *Cost:* reads always go over the network. Expect slower I/O for SQLite-heavy apps such as the *arr apps.
  - *How:* it's a per-volume setting (`kubectl -n storage patch volumes.longhorn.io <pv> --type merge -p '{"spec":{"dataLocality":"disabled"}}'`). The StorageClass parameter only applies to new volumes. StorageClass parameters are immutable, so changing [storageclass-fast.yaml](../kubernetes/apps/storage/longhorn/app/storageclass-fast.yaml) means deleting the StorageClass and letting Flux recreate it; existing PVs are unaffected.
  - Try it on one heavy volume first and compare app responsiveness.

### Step 4: Turn on `cleanupCachePVC` (done 2026-11-20)

So that future restores delete their own `-dst-cache` and step 1 doesn't need repeating. The cache class is openebs-hostpath, so the Longhorn problem shouldn't apply. The upstream comment saying both cleanup flags must be `false` came from someone whose cache was on Longhorn. Still, the comment in the component ties both flags to #1504, so prove it first.

1. Pick a small app. Delete its RD and app PVC following §6, but before resuming, change `cleanupCachePVC: false` → `true` in [replicationdestination.yaml](../kubernetes/components/volsync/replicationdestination.yaml). To test one app only, add a new variable such as `${VOLSYNC_CLEANUP_CACHE:=false}` and set it in that app's `ks.yaml`.
2. **Pass condition:** the app PVC is populated with current data, and `volsync-dst-<app>-dst-cache` is gone afterwards.
3. Only then change the default. Existing RDs keep their current spec, because of `ssa: IfNotPresent`, until they are recreated.

Leave `cleanupTempPVC: false` as it is. Turning it on breaks restores (§3).

**Tested 2026-11-20 in an isolated namespace (§6b, phase 4): passed.** With `cleanupCachePVC: true`:

- VolSync deleted `-dst-cache` as soon as the restore mover finished (within 20 s);
- `-dst-dest` and its snapshot stayed intact;
- the app PVC was restored byte-identical from Kopia.

Changing the component default is safe on that evidence, but it is optional if the §6a job is deployed, because the job also removes `-dst-cache`.

**Applied 2026-11-20:**

- **Component:** [replicationdestination.yaml](../kubernetes/components/volsync/replicationdestination.yaml) now has `cleanupCachePVC: true`; `cleanupTempPVC` stays `false`. Every app uses openebs-hostpath for the cache, and none overrides `VOLSYNC_CACHE_STORAGECLASS`.
- **Existing RDs:** Flux never updates them (`ssa: IfNotPresent`), so all 41 live RDs were patched in place:

  ```bash
  kubectl get replicationdestinations -A -o json \
    | jq -r '.items[] | select(.spec.kopia.cleanupCachePVC != true) | "\(.metadata.namespace) \(.metadata.name)"' \
    | while read -r ns rd; do
        kubectl -n "$ns" get replicationsource "${rd%-dst}" >/dev/null 2>&1 || { echo "skip orphan $ns/$rd"; continue; }
        kubectl -n "$ns" patch replicationdestination "$rd" --type merge -p '{"spec":{"kopia":{"cleanupCachePVC":true}}}'
      done
  ```

  A spec change doesn't start a restore: `shouldSync` only compares the manual trigger tag. Afterwards all RDs were still `WaitingForManual`, with no restore jobs and no PVCs recreated.
- **Don't** delete and recreate RDs to pick up the default. Each recreated RD immediately runs a fresh restore.

### Step 5: Give Longhorn its own disk (later)

This is the permanent fix: if Longhorn isn't on EPHEMERAL, it can't cause kubelet DiskPressure. Outline:

1. Provide the space, either a second disk or a partition carved out by capping EPHEMERAL with `maxSize` in [talos/all/05-ephemeral-volume.yaml](../talos/all/05-ephemeral-volume.yaml). Capping EPHEMERAL on an existing node needs a wipe and reinstall of that node.
2. Add a Talos `UserVolumeConfig` (for example, mounted at `/var/mnt/longhorn`). Update the kubelet bind mount in [talos/worker/01-machine-kubelet.yaml](../talos/worker/01-machine-kubelet.yaml) and `defaultDataPath`.
3. Add the new disk to the Longhorn node. Set the old disk's `allowScheduling: false` and `evictionRequested: true`, wait for its replicas to move, then remove it. Do one node at a time.

If you do this, lower each disk's Storage Reserved (step 6) to a few percent first, since nothing else would use the new disk.

### Step 6: Make Longhorn's scheduling limits match reality (over-provisioning 120%, reserved 100 GiB)

#### How Longhorn decides whether a replica fits

Longhorn volumes are **thin**: a PVC's size is a maximum, and disk space is only used for data actually written. Plex's PVC is 19 GB, for example, with about 12 GB written. Across the cluster, volumes hold 53% of what they provision (212 GB actual against 399 GB provisioned, 2026-11-20).

Before placing a replica on a disk, Longhorn (`IsSchedulableToDisk`) checks two separate things:

1. **Physical check:** after placing it, real free space must stay above **Minimum available** (20%, step 3). It uses actual bytes on disk.
2. **Promise check:** the *provisioned* sizes of all replicas on the disk, plus the new one, must stay under **(disk − Storage Reserved) × Over-provisioning %**.

| Setting | Question it answers | Where it's set |
|---|---|---|
| **Storage Reserved** (per disk) | How much of this disk is used by things other than Longhorn (images, hostpath caches, logs, CI runners)? | Longhorn UI per disk, or `nodes.longhorn.io` `spec.disks.*.storageReserved`. Not in Git |
| **Over-provisioning %** | On average, how full are PVCs compared with their size? | HelmRelease `storageOverProvisioningPercentage` |
| **Minimum available %** | How much real free space must always remain? | HelmRelease `storageMinimalAvailablePercentage` |
| Reserved % for default disk | Storage Reserved for a disk Longhorn creates *later* (node rebuild); never changes existing disks | HelmRelease `storageReservedPercentageForDefaultDisk` |

Over-provisioning works like airline overbooking: at 100%, Longhorn never promises more than exists, as if every PVC could fill up completely at once. At 120%, it promises 1.2 times what exists, on the basis that PVCs average well under their maximum. It doesn't change PVC sizes, move data, let a volume exceed its own size, or weaken the physical check.

**The risk:** if many volumes filled toward their maximum at once, the 20% floor would stop *new* replicas but couldn't stop existing volumes from writing. Free space would keep dropping until kubelet evicted pods at 15%. The safe range depends on the **break-even fill**: the average PVC fill at which a disk's promise limit equals the space physically usable by Longhorn (disk − non-Longhorn usage − 20% floor). Today's fill must stay clearly below it.

#### What was wrong (measured 2026-11-20 22:40 UTC)

| Node | Disk | Used by things other than Longhorn | Storage Reserved | Verdict |
|---|---|---|---|---|
| k8s-04 | 509 GB | ~97 GB | 137 GB (27%) | Over-reserved: the node with the most room had the least headroom |
| k8s-05 | 341 GB | ~99 GB | 34 GB (10%) | Under-reserved: Longhorn could promise 306 GB, but only ~173 GB physically fits before the floor |
| k8s-06 | 341 GB | ~91 GB | 34 GB (10%) | Under-reserved (~181 GB physically usable) |

Non-Longhorn usage is about the same 91–99 GB on every node, whatever the disk size, so a single percentage can't fit all three disks. Set an **absolute** value per disk.

#### Choosing the values

With Storage Reserved at **100 GiB (107 GB) on every disk** (measured usage plus ~10 GB headroom for CI runners and image growth):

| Over-provisioning | Limits k8s-04 / 05 / 06 (GB) | Cluster limit | Provisioned today | Bootstrap worst case | Break-even fill, k8s-05 / 06 |
|---|---|---|---|---|---|
| 100% | 402 / 233 / 233 | 869 GB | 19 / 65 / 71% | 98%, too tight | 74 / 77% |
| 110% | 442 / 257 / 257 | 956 GB | 17 / 59 / 64% | 89% | 67 / 70% |
| **120% (chosen)** | **482 / 280 / 280** | **1,043 GB** | **16 / 54 / 59%** | **82%** | **61 / 64%** |
| 125% | 502 / 292 / 292 | 1,087 GB | 15 / 52 / 56% | 79% | 59 / 62% |
| 150% | 603 / 350 / 350 | 1,304 GB | 13 / 43 / 47% | 65% | 49 / 51%, **below today's 53%: already over-promised** |

**120% is the sensible middle.**

- **Backed by real space:** promises stay physically backed until PVCs average 61–64% full, which is 8–11 points above today's 53%.
- **Bootstrap:** the worst case uses 82% of the limit. With the old settings it was 87%, and the §6a job frees each app's `-dst-dest` as its clone finishes.
- **100%, with accurate reservations, would stall a bootstrap** (98%).
- **150% would over-promise already.**

The HelmRelease also sets `storageReservedPercentageForDefaultDisk` from 15 to 30, so a rebuilt node's disk starts near the real ~100 GB on a 341 GB disk. A rebuilt k8s-04 would start at 153 GB, which errs on the safe side; set it to 100 GiB in the UI afterwards.

#### Steps

1. **Push the HelmRelease change** (`storageOverProvisioningPercentage: "120"`, `storageReservedPercentageForDefaultDisk: "30"`), then wait for it to apply:
   ```bash
   kubectl -n storage get hr longhorn -o jsonpath='{.status.conditions[?(@.type=="Ready")].status} {.status.conditions[?(@.type=="Ready")].reason}{"\n"}'   # True UpgradeSucceeded
   kubectl -n storage get settings.longhorn.io storage-over-provisioning-percentage storage-reserved-percentage-for-default-disk \
     -o custom-columns=N:.metadata.name,V:.value --no-headers                                                                   # 120 / 30
   ```
   Do this **before** step 2. Raising Storage Reserved while over-provisioning is still 100% briefly cuts the limits to 402 / 233 / 233 GB. That's harmless for running apps (71% at most), but a bootstrap in that window would stall.
2. **Set Storage Reserved to 100 GiB on each disk** in the Longhorn UI. For each node (k8s-04, k8s-05, k8s-06):
   1. Open **Node**, and on the node's row open the **Operation** menu (⋮), then **Edit node and disks**.
   2. On the disk (`default-disk-1030800000000` on k8s-04, `default-disk-080400000000` on k8s-05/06), set **Storage Reserved** to **100** (the field is in Gi).
   3. **Save.** Leave everything else (scheduling, eviction, tags) unchanged.

   Equivalent from the CLI (100 GiB = 107374182400 bytes):
   ```bash
   kubectl -n storage patch nodes.longhorn.io k8s-04 --type merge -p '{"spec":{"disks":{"default-disk-1030800000000":{"storageReserved":107374182400}}}}'
   for n in k8s-05 k8s-06; do
     kubectl -n storage patch nodes.longhorn.io $n --type merge -p '{"spec":{"disks":{"default-disk-080400000000":{"storageReserved":107374182400}}}}'
   done
   ```
3. **Verify.** Run the §4a snapshot script and compare with the "After step 6" column. Every disk should still show `Schedulable=True`:
   ```bash
   kubectl -n storage get nodes.longhorn.io -o json | jq -r '.items[] | .metadata.name as $n | (.spec.disks|to_entries[0].value.storageReserved/1073741824) as $r
     | .status.diskStatus|to_entries[0].value | "\($n) reserved=\($r)GiB schedulable=\([.conditions[]|select(.type=="Schedulable")|.status][0])"'
   ```

No data moves, and nothing is restarted. Only future scheduling decisions change.

**Keep an eye on the fill ratio.** It's the "Longhorn data, all replicas" ÷ "Longhorn provisioned" rows in the §4a snapshot (53% today). If it climbs toward 60%, lower over-provisioning or grow the disks. Re-measure non-Longhorn usage (`/var` used − Longhorn actual) if you add large images or CI workloads.

## 6. Restoring an app from backup (after step 2)

The populator always uses the RD's `latestImage`, so a restore means recreating the RD to force a fresh restore from Kopia. Before step 2, the same procedure was needed anyway; skipping it restored the 2025-12-13 data.

```bash
ns=default app=<app>

# 0. (Optional) take a backup of the current state first
just kube snapshot $ns $app

# 1. Stop Flux from recreating things mid-way, and stop the app
flux -n $ns suspend ks $app
flux -n $ns suspend hr $app
kubectl -n $ns scale deploy/$app --replicas=0      # or statefulset; wait for the pod to go

# 2. Remove the old restore and the app PVC
kubectl -n $ns delete replicationdestination ${app}-dst
kubectl -n $ns delete pvc $app

# 3. Flux recreates the RD (restore-once runs from Kopia) and the PVC (populated from the new snapshot)
flux -n $ns resume ks $app
kubectl -n $ns get replicationdestination ${app}-dst -w                 # wait for lastSyncTime / latestImage
kubectl -n $ns get pvc $app -w                      # wait for Bound

# 4. Start the app
flux -n $ns resume hr $app
```

The new restore creates a new `volsync-<app>-dst-dest` and snapshot. VolSync deletes the `-dst-cache` itself (step 4). The §6a CronJob removes `-dst-dest` and the snapshot within one run (≤ 15 min) once the app PVC is 15 minutes old and its Longhorn clone has `completed`. To do it right away, run `just kube volsync-cleanup true <namespace>`; it skips the app if the clone isn't finished yet.

## 6a. Keeping it from building up again: bootstrap capacity and an automated cleanup

### Why one-time cleanup isn't enough

Every restore recreates the leftovers, and a bootstrap restores every app at once. Measured on 2026-11-20 (provisioned size × replicas, which is what Longhorn schedules against):

| | Provisioned (GB) | Actual (GB) |
|---|---|---|
| App PVCs restored by VolSync (41) | 229 | 113 |
| `-dst-dest` leftovers | 206 | 85 |
| All other Longhorn volumes | 169 | 101 |
| **Schedulable capacity** (disk − reserved, × 100% over-provisioning) | **984** (k8s-04 372, k8s-05 306, k8s-06 306) | |

**Bootstrap worst case.** Per app, three full copies can coexist:
- the restore's `-dst-dest`
- the app PVC, a full-copy clone of the restore's snapshot
- the first backup's temporary `-src` clone

The third one is there because VolSync starts a backup *immediately* for a ReplicationSource that has never synced (`statemachine/machine.go`: `initialState` → `transitionToSynchronizing`). The mover jitter only spreads job starts over 0–150 s.

That is about 3 × 229 + 169 ≈ **856 GB of 984 (87%)** provisioned. Physically it's about 440 GB on Longhorn, plus up to 251 Gi of hostpath caches requested. The provisioned limit is the one that binds.

**After the bootstrap**, `cleanupTempPVC: false` keeps the `-dst-dest` copies, so the steady state stays about 2× the app data. That is where things stood before step 2.

**The failure mode** is a stalled bootstrap, not data loss. Replicas that don't fit wait in "replica scheduling failed" until something frees space. Physical DiskPressure becomes a risk again only if the data itself grows.

There's not enough history to project growth: Prometheus keeps 30 days and only 9 had data. Live Longhorn data held at 95–110 GB from 2026-11-12 to 2026-11-20.

**Orphans add up silently, too.** Flux does not prune the ReplicationDestination, which carries `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`. Apps that were removed left their RD, `-dst-dest`, snapshot and `-dst-cache` behind: calibre-web-downloader (renamed to shelfmark), paperless-ai, scriberr and streamflow. So did tracearr, whose Kustomization still exists but no longer includes the VolSync component.

### Options considered

| Option | Verdict |
|---|---|
| `cleanupTempPVC: true` (VolSync's own cleanup) | Breaks restores with Longhorn `type: snap` snapshots ([volsync#1504](https://github.com/backube/volsync/issues/1504); no fix planned) |
| Longhorn backup target + `type: bak` VolumeSnapshotClass | No backup target configured. VolSync only waits for the snapshot to be *bound*, not *ready* (the reason PR #1520 was proposed and rejected), so deleting the temp PVC mid-upload is a race |
| Kyverno `ClusterCleanupPolicy` | Kyverno isn't installed, and the safety check needs cross-object state (the Longhorn clone status) |
| **CronJob running a guarded kubectl/jq script** | **Recommended.** Same pattern as [longhorn-pdb-pruner](../kubernetes/apps/storage/longhorn-pdb-pruner/), and it can check every safety condition |

### What the job does

It runs every 15 minutes. For each ReplicationDestination it deletes, in this order, the `status.latestImage` VolumeSnapshot, then `volsync-<rd>-dest`, then `volsync-dst-<rd>-cache`. It only acts when **all** of these hold:

1. **The restore is idle:** the RD's `Synchronizing` condition is `False`, and no `volsync-dst-<rd>` mover Job exists.
2. **The volume populator isn't mid-way:**
   - no `vs-prime-*` PVC exists in the namespace (`volumepopulator_controller.go`: `populatorPvcPrefix = "vs-prime"`);
   - the snapshot carries no `volsync.backube/volpop-pvc-<uid>` label, which the populator sets while it uses a snapshot;
   - the snapshot carries no `volsync.backube/do-not-delete` label.
3. **Every app PVC with `dataSourceRef` → this RD** is `Bound`, older than `MIN_AGE_SECONDS` (900 s in the CronJob and the recipe; the script's own default is 3600 s), and its Longhorn volume shows `cloneStatus.state: completed`. The clone check is essential: Longhorn binds a cloned PVC *before* the copy finishes ([longhorn#14599](https://github.com/longhorn/longhorn/issues/14599)), and deleting the source mid-copy fails the clone (`VolumeCloneFailed`).
4. **Orphans** (no app PVC, no ReplicationSource for the app, RD older than `MIN_AGE_SECONDS`) are only reported. With `DELETE_ORPHANS=true`, the job also deletes any leftovers and the RD. Guards 1 and 2 still apply to orphans.

It ships with `DRY_RUN=true`, so it only logs what it would do. `ONLY_NAMESPACE=<ns>` limits it to one namespace; it was used for the §6b test and is the recipe's optional second argument.

**Fixed 2026-11-20 22:08 UTC:** the first version checked "nothing left to clean" *before* the orphan check. Once step 2 had removed the orphans' PVCs and snapshots, it skipped them silently, and `DELETE_ORPHANS=true` would never remove their RDs. The committed `cleanup.sh` evaluates orphans first. It was re-verified cluster-wide in dry-run mode: the 5 orphans are reported, 0 live RDs need cleaning, and `DELETE_ORPHANS=true` would delete exactly the 5 orphan RDs.

**Why Flux and VolSync don't undo it** (checked 2026-11-20):

| Object | Owner | After the job deletes it |
|---|---|---|
| Live app's ReplicationDestination (41) | Flux: each app's Kustomization inventory lists its PVC, RD and RS | **Never deleted by the job.** Deleting one would make Flux recreate it, and the new RD would immediately run a fresh restore. That is the §6 restore mechanism. |
| Snapshot, `volsync-<rd>-dest`, `volsync-dst-<rd>-cache` | VolSync; not in any Flux inventory | Stay gone. An idle RD only syncs again when `spec.trigger.manual` changes (`shouldSync`: `ManualTag() != LastManualTag()`, both `restore-once` here). Until then the controller only runs its cleanup state and never re-provisions these PVCs. Step 2a verifies this on one app. |
| Orphaned RD | None: not in any inventory (41 RD entries across all Kustomizations, one per live app) | Stays gone. The 5 found on 2026-11-20 were checked (no owned objects, app PVC, RS or inventory entry) and deleted by hand. |

The leftovers come back whenever an RD is created fresh: on bootstrap, during a §6 restore, or whenever an app's Kustomization or RD is recreated. The job exists to clean up after exactly those cases.

**Dry runs against the live cluster (2026-11-20):**

- Before step 2: 41 RDs to clean (the same 41 completed full-copy clones counted in §3) and the 5 orphans reported.
- After step 2 and the orphan removal: nothing to clean (`just kube volsync-cleanup` prints nothing).

**Restores stay safe.** During a §6 restore, the new app PVC is `Pending` and then mid-clone, so guards 2 and 3 skip that app until the clone completes (shown in §6b). Bootstrap behaves the same way. Each app's `-dst-dest` is freed in the first run after its PVC is `MIN_AGE_SECONDS` (15 min) old and its clone has completed.

### Implementation (2026-11-20)

The job is the Flux app [kubernetes/apps/storage/volsync-restore-cleanup/](../kubernetes/apps/storage/volsync-restore-cleanup/), listed in [kubernetes/apps/storage/kustomization.yaml](../kubernetes/apps/storage/kustomization.yaml). It follows the same pattern as `longhorn-pdb-pruner`.

| File | What it is |
|---|---|
| [ks.yaml](../kubernetes/apps/storage/volsync-restore-cleanup/ks.yaml) | Flux Kustomization in `storage`; `dependsOn` longhorn and volsync |
| [resources/cronjob.yaml](../kubernetes/apps/storage/volsync-restore-cleanup/resources/cronjob.yaml) | CronJob `*/15 * * * *`, `concurrencyPolicy: Forbid`, `alpine/k8s` (kubectl + jq), non-root, read-only root filesystem, `/tmp` emptyDir |
| [resources/rbac.yaml](../kubernetes/apps/storage/volsync-restore-cleanup/resources/rbac.yaml) | ServiceAccount + ClusterRole: read and delete RDs, PVCs and VolumeSnapshots; read RSs, Jobs and Longhorn volumes |
| [resources/cleanup.sh](../kubernetes/apps/storage/volsync-restore-cleanup/resources/cleanup.sh) | **The script, single source.** Mounted into the CronJob through a generated ConfigMap (Flux substitution disabled) and run locally by the `just` recipe. It is the version tested in §6b |

**CronJob settings:**

| Variable | Value | Why |
|---|---|---|
| `DRY_RUN` | `"true"` at first | Only logs `CLEAN` / `SKIP` / `ORPHAN` lines. Flip to `"false"` after reviewing a few runs |
| `DELETE_ORPHANS` | `"true"` | Removes an app's leftover RD once its RS and app PVC are gone (only while `DRY_RUN` is `"false"`) |
| `MIN_AGE_SECONDS` | `"900"` | The script default is 3600. The real safety check is the clone-completed check (guard 3); a shorter age drains the bootstrap peak sooner |

The storage namespace's NetworkPolicies are all ingress-only and select Longhorn components, so they don't affect this pod. Validated before commit:

- every object passes `kubectl apply --dry-run=server`;
- the ConfigMap carries the script unchanged;
- the script parses under `dash` (strict POSIX).

The first scheduled dry run confirms it under BusyBox `ash` in the image.

**`just kube volsync-cleanup [apply] [namespace]`** ([kubernetes/mod.just](../kubernetes/mod.just)) runs the same `cleanup.sh` from your workstation with the same settings:

```bash
just kube volsync-cleanup                  # dry run, all namespaces
just kube volsync-cleanup false default    # dry run, one namespace
just kube volsync-cleanup true default     # live, one namespace (e.g. right after a §6 restore)
just kube volsync-cleanup true             # live, all namespaces
```

### Operating it

1. **After the commit is pushed and Flux has reconciled:**
   ```bash
   flux -n storage get ks volsync-restore-cleanup
   kubectl -n storage get cronjob volsync-restore-cleanup
   ```
2. **Review a dry run.** Trigger one instead of waiting up to 15 minutes, then read its log:
   ```bash
   kubectl -n storage create job --from=cronjob/volsync-restore-cleanup volsync-restore-cleanup-manual-$(date +%s)
   kubectl -n storage logs -l app.kubernetes.io/name=volsync-restore-cleanup --tail=-1
   ```
   Every run prints a `START` line with its settings and a `SUMMARY` line, plus one line for each RD it acts on or skips (`CLEAN`, `SKIP`, `ORPHAN`). On 2026-11-20, after steps 1–2 and the orphan removal, the expected output was:
   ```text
   START 2026-11-20T23:00:56Z DRY_RUN=true DELETE_ORPHANS=true MIN_AGE_SECONDS=900 namespace=<all>
   SUMMARY checked=41 clean=0 skipped=0 orphans-reported=0 nothing-to-clean=41 failed=0 (dry run: nothing was deleted)
   ```
   `checked` should equal the number of RDs (41 now). If a snapshot can't be deleted, the run counts it as `failed`, leaves that RD's `-dst-dest` in place and exits non-zero, so the Job shows as `Failed`. A missing `SUMMARY` line means the script stopped early; check the Job's events and log.
3. **Turn it on:** set `DRY_RUN` to `"false"` in `cronjob.yaml` and commit.
4. **After any restore** (§6 or a bootstrap), check that the leftovers drain. Expect `SKIP … clone state=…` while the copy runs, then `CLEAN` within one run (≤ 15 min) after the app PVC is 15 minutes old with its clone `completed`. To see what's left at any time, run `just kube volsync-cleanup`.
5. **Pause it** without removing anything: `kubectl -n storage patch cronjob volsync-restore-cleanup -p '{"spec":{"suspend":true}}'`. Flux reverts this on its next reconcile, so for a longer pause, set `spec.suspend: true` in Git.

### Other levers for the bootstrap peak

- **Over-provisioning and per-disk reserved space:** done as step 6 (§5): over-provisioning 120% and 100 GiB Storage Reserved per disk. That takes the worst case from 87% to 82% while making the limits honest about physical space. An earlier draft suggested 150%; it was rejected because its break-even fill (49–51%) is already below today's 53%.
- **Right-size `VOLSYNC_CAPACITY` for new apps.** It counts up to three times at bootstrap (app, `-dst-dest`, first backup). Existing PVCs can't be shrunk.

## 6b. End-to-end test in an isolated namespace (2026-11-20 22:10–22:27 UTC)

This test runs the real VolSync component, Longhorn, the Kopia repository and the §6a script through a full app lifecycle, without touching any real app. It runs in a throwaway namespace `volsync-e2e` with app name `volsync-e2e` and a 1 Gi PVC. It was rendered from the unmodified component, exactly as Flux would, with no Flux object involved, and the script ran with `ONLY_NAMESPACE=volsync-e2e`.

### How to run it again

```bash
# Render the component as Flux would (kustomize refuses absolute component paths, so copy it)
E=$(mktemp -d); cp -R kubernetes/components/volsync "$E/volsync"
printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: volsync-e2e\ncomponents:\n  - ./volsync\n' > "$E/kustomization.yaml"
kubectl kustomize "$E" | APP=volsync-e2e VOLSYNC_CAPACITY=1Gi VOLSYNC_SCHEDULE="0 3 1 1 *" flux envsubst > "$E/rendered.yaml"
grep -c 'namespace: volsync-e2e' "$E/rendered.yaml"     # expect 4 (PVC, ExternalSecret, RD, RS); nothing else

kubectl create namespace volsync-e2e
kubectl apply -f "$E/rendered.yaml"                       # = bootstrapping a brand-new app

# Test pods: busybox, runAsUser/fsGroup 1000, mounting PVC volsync-e2e
#   seed:  dd 50 MB of /dev/urandom + date into /data/e2e, save sha256sum output locally
#   check: sha256sum /data/e2e/* and diff against the saved sums
# Backups:  kubectl -n volsync-e2e patch replicationsource volsync-e2e --type merge -p '{"spec":{"trigger":{"manual":"<new tag>"}}}'
# Script:   ONLY_NAMESPACE=volsync-e2e MIN_AGE_SECONDS=60 DRY_RUN=true|false TMPDIR=$(mktemp -d) \
#             sh kubernetes/apps/storage/volsync-restore-cleanup/resources/cleanup.sh
#           (the recipe hardcodes MIN_AGE_SECONDS=900, so call the script directly for a quick test)

kubectl delete namespace volsync-e2e                      # teardown
```

### Results

| Phase | What was done | Observed | Result |
|---|---|---|---|
| 1. Bootstrap | Applied the rendered component | 22:10:38 empty restore finished; 22:10:50 app PVC **Bound while the Longhorn clone was still `initiated`**; 22:11:35 clone `completed`; 22:13:18 **first backup ran automatically** (§6a) | ✅ |
| 2. Seed | Wrote 50 MB of random data plus a timestamp; manual backup | Uploaded 48.3 MB, Kopia snapshot `94382f09…` | ✅ |
| 3. Script on bootstrap leftovers | Dry run, then live | Deleted snapshot → `-dst-dest` → `-dst-cache`; app PVC and `src-cache` untouched; checksums OK | ✅ |
| 4. §6 restore with step 4 | Deleted the app PVC and RD; re-applied with `cleanupCachePVC: true`; ran the script every 5 s (dry run, `MIN_AGE_SECONDS=0`) | 22:18:48 mover running → SKIP. 22:19:08 restore done and **`-dst-cache` already deleted by VolSync**, while `-dst-dest` and snapshot were kept. 22:19:10–25 PVC Bound, clone `initiated` / `copy-completed-awaiting-healthy` → SKIP. 22:19:54 clone `completed` → CLEAN at 22:19:56. Restored data **byte-identical** to the seed | ✅ |
| 4b. Script live after restore | Live run, then data check, then backup | Leftovers removed; data still identical; backup at 22:23:59 `Successful`; second pass found nothing to clean | ✅ |
| 5. Idle RD after cleanup | Forced a reconcile (annotation change) | RD stayed `WaitingForManual`; no PVC or snapshot recreated | ✅ |
| 6. Orphan | Deleted the RS and app PVC (simulating app removal) | Report-only: `ORPHAN`; `DELETE_ORPHANS=true` removed the RD; `src-cache` went with the RS (owner reference) | ✅ |
| Teardown | Deleted the namespace | 0 PVs, Longhorn volumes, snapshot contents, Longhorn orphans or hostpath folders left from the test. All 41 real RSs still `Successful`, all 46 real RDs `WaitingForManual`, 49 Longhorn volumes, 0 degraded | ✅ |

**What remains:** three small Kopia snapshots for source `volsync-e2e@volsync-e2e` (about 48 MB of unique data) in the shared repository. They don't affect real apps' snapshots. Remove them with `kopia snapshot delete` from a pod that mounts the repository, or leave them; nothing applies retention to that source any more.

**Unrelated change during the test window:** karakeep's Deployment was modified at 22:09:41 by a client identifying as `node-fetch` (not kubectl). karakeep rolled to k8s-05, which let the Pending `karakeep-meilisearch` (pod affinity, shared RWO volume) run. Separately, a GitHub Actions runner on k8s-04 (started 22:12) used about 10 GB of `/var`.

## 7. Useful queries

Free space on a node's `/var`, from Prometheus:

```bash
q='node_filesystem_avail_bytes{mountpoint="/var",instance=~".*30.25.*"} / 1e9'
kubectl get --raw "/api/v1/namespaces/observability/services/prometheus-operated:9090/proxy/api/v1/query_range?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$q")&start=$(($(date +%s)-86400))&end=$(date +%s)&step=300" \
  | jq -r '.data.result[].values[] | [(.[0]|strftime("%m-%d %H:%M")), (.[1]|tonumber|floor)] | @tsv'
```

kubelet's view and thresholds:

```bash
kubectl get --raw /api/v1/nodes/k8s-05/proxy/stats/summary | jq '.node.fs | {avail: (.availableBytes/1e9), cap: (.capacityBytes/1e9)}'
kubectl get --raw /api/v1/nodes/k8s-05/proxy/configz | jq '.kubeletconfig.evictionHard'
```

Longhorn disk headroom per node:

```bash
kubectl -n storage get nodes.longhorn.io -o json | jq -r '.items[] | .metadata.name as $n | .status.diskStatus[]
  | [$n, (.storageMaximum/1e9|floor), (.storageAvailable/1e9|floor), (.storageScheduled/1e9|floor), ((.scheduledReplica//{})|length)] | @tsv'
```

Real hostpath usage on a node (Longhorn's directories are sparse, so use the Longhorn numbers above for them instead):

```bash
talosctl -n 192.168.30.25 usage /var/mnt/local-hostpath --depth 1
```

Check whether an app volume still depends on its `-dst-dest` (expect `full-copy` and `completed`):

```bash
kubectl -n storage get volumes.longhorn.io -o json | jq -r '.items[] | select(.spec.dataSource|tostring|test("snap://"))
  | [.status.kubernetesStatus.pvcName, .spec.cloneMode, .status.cloneStatus.state] | @tsv'
```

## 8. Upstream issues to watch

| Issue | What it is | State (2026-11-20) |
|---|---|---|
| [backube/volsync#1504](https://github.com/backube/volsync/issues/1504) | Restore breaks with Longhorn when temp/cache PVCs are cleaned up | Open; no fix planned |
| [longhorn#13335](https://github.com/longhorn/longhorn/issues/13335) | Clone volume not attaching after copy (VolSync movers) | Closed; only attacher retry capped at 1m (present in v1.13.0) |
| [longhorn#14599](https://github.com/longhorn/longhorn/issues/14599) | Cloned volumes Bound before usable; ~100 s attach delay | Open |
| [longhorn#14562](https://github.com/longhorn/longhorn/issues/14562) | Snapshot CRs with names over 63 characters can't be deleted | Fixed for v1.13.1 (not released); no such snapshots in this cluster |
| [longhorn#10512](https://togithub.com/longhorn/longhorn/issues/10512) | Disk-space-aware placement of new replicas (LEP [#11922](https://togithub.com/longhorn/longhorn/pull/11922)) | Shipped in v1.11.0; in use on v1.13.0. Doesn't move existing replicas (§5 step 3b) |
| [longhorn#2977](https://togithub.com/longhorn/longhorn/issues/2977) | Automatically rebalance existing replicas by disk usage | Open since 2021, Backlog. Would make §5 step 3b's manual rebalance unnecessary |
| [longhorn#11135](https://togithub.com/longhorn/longhorn/issues/11135) | Move a specific replica to a chosen node (UI / API) | Open, Backlog; needs a design doc (LEP) |
| [longhorn#14415](https://togithub.com/longhorn/longhorn/issues/14415) | "auto balance not working as expected (1.13)" | Open; under discussion |

A Longhorn release that keeps CSI snapshots alive after their source volume is deleted would let `cleanupTempPVC: true` work and make §3 moot. Another way would be to configure a backup target and use a `type: bak` VolumeSnapshotClass for the RD. There is no backup target configured today.

## 9. Config references

- VolSync component: [kubernetes/components/volsync/](../kubernetes/components/volsync/)
- VolSync operator (perfectra1n fork v0.17.11, chart 0.18.5): [kubernetes/apps/storage/volsync/app/helmrelease.yaml](../kubernetes/apps/storage/volsync/app/helmrelease.yaml)
- Longhorn v1.13.0: [kubernetes/apps/storage/longhorn/app/helmrelease.yaml](../kubernetes/apps/storage/longhorn/app/helmrelease.yaml)
- Talos EPHEMERAL volume: [talos/all/05-ephemeral-volume.yaml](../talos/all/05-ephemeral-volume.yaml)
- Restore-leftover cleanup (§6a): [kubernetes/apps/storage/volsync-restore-cleanup/](../kubernetes/apps/storage/volsync-restore-cleanup/), script [resources/cleanup.sh](../kubernetes/apps/storage/volsync-restore-cleanup/resources/cleanup.sh), recipe `volsync-cleanup` in [kubernetes/mod.just](../kubernetes/mod.just)

## 10. Log

| Date (UTC) | Change / event |
|---|---|
| 2026-11-20 20:07 | k8s-05 DiskPressure (51 GB free, `imagefs.available` 15%); recovered 20:16 |
| 2026-11-20 20:15 | k8s-06 DiskPressure (pods evicted from k8s-05 landed there); recovered 20:21 |
| 2026-11-20 20:30 | tuppr began the Talos v1.14.6 rollout (control planes done 20:38; k8s-04 draining) |
| 2026-11-20 21:17 | Talos v1.14.6 rollout completed on all six nodes; Longhorn rebuilding replicas stopped by the reboots (69 degraded at 21:20, 53 at 21:24) |
| 2026-11-20 21:24 | Doc re-validated after the rollout (corrected §1 timeline and §2 placement; restore caches now 20.8 GB cluster-wide; §6a dry run unchanged: 41 to clean, 5 orphans) |
| 2026-11-20 21:37 | Longhorn rebuilds complete (95 volumes, 0 degraded); §4a baseline recorded |
| 2026-11-20 | Step 3 edited in the Longhorn HelmRelease: `storageMinimalAvailablePercentage` 5 → 20 (not yet committed) |
| 2026-11-20 | §6a cleanup script dry-run against the cluster: 41 to clean, 5 orphans (calibre-web-downloader, paperless-ai, scriberr, streamflow, tracearr) |
| 2026-11-20 21:45 | Step 1: all 46 restore caches deleted; k8s-05 /var free 99 → 118 GB; src-caches and all 41 backups unaffected (§4a) |
| 2026-11-20 21:53 | Step 2a passed: homepage snapshot, `-dst-dest` PVC, PV and Longhorn volume gone and not recreated after a Flux reconcile (21:50); RD `WaitingForManual`; manual backup succeeded (2m40s); 94 volumes, 0 degraded; `-dst-dest` 45 / 45 |
| 2026-11-20 21:58 | Step 2b: remaining 45 `-dst-dest` PVCs and snapshots deleted; 49 Longhorn volumes, 0 degraded; k8s-05 / k8s-06 `/var` free 160 / 151 GB; replicas 26 / 36 / 36 (§4a) |
| 2026-11-20 22:04 | Step 3: `storageMinimalAvailablePercentage` 5 → 20 live (commit `6562b6b8`, Helm `longhorn.v48`); all disks schedulable. Step 3b skipped by decision |
| 2026-11-20 22:08 | §6a script fixed (orphans with no leftovers were skipped) and given `ONLY_NAMESPACE`; re-verified cluster-wide in dry-run mode |
| 2026-11-20 22:27 | §6b end-to-end test in namespace `volsync-e2e`: all phases passed, including step 4 (`cleanupCachePVC: true`) and the §6a script live; namespace removed, no leftovers, no real app touched |
| 2026-11-20 | Step 4: component default changed to `cleanupCachePVC: true` (`cleanupTempPVC` stays `false`). All 46 RDs use openebs-hostpath caches; no app overrides `VOLSYNC_CACHE_STORAGECLASS`. Existing RDs keep `false` until recreated (`ssa: IfNotPresent`) |
| 2026-11-20 | Existing RDs patched in place (`kubectl patch … {"spec":{"kopia":{"cleanupCachePVC":true}}}`): homepage first as a test, then the other 40; the 5 orphans skipped. Flux leaves the patch alone (`IfNotPresent`), and no restore was triggered (all 46 `WaitingForManual`, `lastManualSync` unchanged, 0 restore jobs, 0 controller errors, no PVCs recreated) |
| 2026-11-20 | 5 orphaned RDs deleted (calibre-web-downloader, paperless-ai, scriberr, streamflow, tracearr; each checked first: no owned objects, app PVC, RS or Flux inventory entry). Now 41 RDs = 41 RSs |
| 2026-11-20 | §6a implemented in Git: Flux app `storage/volsync-restore-cleanup` (CronJob `*/15`, `DRY_RUN=true`, `DELETE_ORPHANS=true`, `MIN_AGE_SECONDS=900`) and recipe `just kube volsync-cleanup`, sharing one `cleanup.sh`. Server-side dry run passed; recipe dry run printed nothing (nothing to clean) |
| 2026-11-20 22:56 | Cleanup CronJob deployed (commit `972a0bf2`); a manual dry-run Job `Complete` in 11 s under BusyBox `ash`. Its log was empty because there was nothing to clean |
| 2026-11-20 | Step 6 prepared: HelmRelease `storageOverProvisioningPercentage` 100 → 120 and `storageReservedPercentageForDefaultDisk` 15 → 30 (server dry run passed). Chosen from measured fill (53%) and non-Longhorn usage (91–99 GB per node); 150% rejected (break-even below today's fill) |
| 2026-11-20 23:01 | Step 6 applied: commit `0a3914b9` live at 23:00 (settings 120 / 30 / 20); Storage Reserved 100 GiB on all three disks via the UI; all `Schedulable=True`; §4a "After step 6" snapshot matches |
| 2026-11-20 23:01 | `cleanup.sh` now always logs `START` and `SUMMARY` (checked / clean / skipped / orphans-reported / nothing-to-clean / failed) and exits non-zero if a snapshot delete fails. Decision logic unchanged; tested via the recipe, for one namespace, and under `dash` |
| | After a few scheduled runs show the expected `SUMMARY`, set `DRY_RUN: "false"` in `cronjob.yaml` |
