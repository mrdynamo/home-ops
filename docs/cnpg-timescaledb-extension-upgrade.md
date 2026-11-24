---
title: CNPG Extension Upgrade Guide
description: How TimescaleDB and timescaledb_toolkit extension images and PostgreSQL minor versions reach the CNPG cluster, and the exact, checked steps to deploy each kind of update without downtime. Written to be followed by a person or handed to an LLM together with a PR number.
---

# CNPG Extension Upgrade Guide

> **For an LLM (or a person) using this guide.** You will usually be given a PR in `mrdynamo/home-ops` or `mrdynamo/containers`.
> 1. Read §1 and §2 once.
> 2. Classify the PR with §3 (look at its diff).
> 3. Check §6 (current state) for anything pending or version-specific.
> 4. Produce the steps of the matching procedure in §5. Substitute the real versions and image references from the PR, keep every check, and keep every STOP condition.
>
> Never merge, deploy or `ALTER` while a check prints `STOP`, `PENDING` or fails. Never invent a step that is not here; if the situation does not fit a procedure, stop and say so.

---

## 1. How the pipeline works

| | |
|---|---|
| Cluster | CNPG `Cluster` `postgres`, namespace `database`, 2 instances (`postgres-1`, `postgres-2`), defined in `kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml`. Flux deploys home-ops `main`. |
| Who uses the extensions | Only the `tracearr` database (Tracearr, through `pooler-rw`, PgBouncer session mode). |
| `timescaledb` | Image `ghcr.io/mrdynamo/timescaledb-bridge`. Preloaded (`shared_preload_libraries`). Runs scheduled jobs (compression, retention, continuous-aggregate refresh). |
| `timescaledb_toolkit` | Image `ghcr.io/mrdynamo/timescaledb-toolkit`. Not preloaded. Tracearr does not call its functions today. |
| Runtime | `spec.imageName`: `ghcr.io/cloudnative-pg/postgresql:<minor>-standard-trixie@sha256:…` |

**Images** are built in `mrdynamo/containers` (`apps/timescaledb-bridge`, `apps/timescaledb-toolkit`). Each image contains:
- the extension at `VERSION` (in its `docker-bake.hcl`), and
- the shared library of `OLD_VERSION`, the version production runs, so the database keeps working on the new image until `ALTER EXTENSION … UPDATE`;

built from source against `RUNTIME_IMAGE`, recorded in the image label `io.github.mrdynamo.runtime-image`.

**PRs in `mrdynamo/containers`:**

| PR | Opened by | Merge |
|---|---|---|
| New TimescaleDB or toolkit release (`VERSION`) | Renovate | Automatic, once its tests pass |
| New CNPG runtime minor (`RUNTIME_IMAGE` → `X.Y-standard-trixie`) | Renovate | **Manual**, only as part of procedure P3 |
| `OLD_VERSION = production (…)` | `Sync Production Versions` workflow (hourly, at :23; never merges itself) | **Manual**, only after the `ALTER` (P1 step 10). It reads the home-ops `main` tag, so it opens within the hour of the home-ops merge, **before** the `ALTER`: leave it open until then. |

Every PR runs, per app:
- `TestFreshInstall`: the image installs and works; for TimescaleDB, jobs run through the scheduler.
- `TestUpgradeFromProduction`: the rollout rehearsed from production exactly (home-ops `main`: runtime, every extension image, preload and parameters). It restarts on the new image with the same data, requires connections, jobs and functions to keep working on the old version, runs `ALTER EXTENSION … UPDATE` via `psql -X`, and requires everything to work on the new version. It fails if `OLD_VERSION` is not production's version.

**PRs in `mrdynamo/home-ops`** (Renovate, never automerged): see §3. Merging into `main` needs an approving review and squash merge (rulesets `protect-main`, `renovate-pr-reviews`); check `gh pr view PR -R mrdynamo/home-ops --json reviewDecision,mergeStateStatus` shows `APPROVED`, `CLEAN` before each merge.

**Merging a home-ops PR only swaps images.** The extension version in the database changes only when someone runs `ALTER EXTENSION … UPDATE`. That step is manual and follows §5.

---

## 2. Hard rules

1. **No new extension deploy while an `ALTER` is pending.** `pending_alter` must print `OK` for both extensions before merging any home-ops PR that touches an extension image or the runtime. (Why: the next image may no longer carry the library the database still needs.)
2. **Extension images must be built for the cluster's PostgreSQL minor.** `runtime_check <home-ops branch>` must print `OK` for every image. An extension build for another minor only ships together with that runtime change (P3).
3. **Rehearse before every home-ops merge** that changes an extension image: `rehearse <app> <exact image reference>` must succeed. It runs the tests on the published image against production as it is now.
4. **Backup before every `ALTER`**, and it must reach `completed`.
5. **Run `ALTER` only with `psqlp`.** It runs `psql -X` on the primary pod, so the `ALTER` is the first statement of a fresh session (TimescaleDB refuses otherwise: "cannot be updated after the old version has already been loaded"). Never through `pooler-rw`.
6. **Leave `TIMESCALEDB_AUTO_UPDATE` unset on Tracearr.** If set, Tracearr runs `ALTER EXTENSION` itself at boot, racing this guide.
7. **One extension version change per deploy.** The exception is P3, where the runtime and both extension rebuilds go together.
8. **Check §6 compatibility notes** before any TimescaleDB version or PostgreSQL minor change.
9. A PostgreSQL **major** upgrade is out of scope: stop and plan it separately.

---

## 3. Classify the PR

Look at the diff (`gh pr diff <n> -R mrdynamo/home-ops`).

| What changes in `cluster.yaml` | Type | Procedure |
|---|---|---|
| An extension `reference:` **tag** (e.g. `timescaledb-bridge:2.29.2@…` → `:2.32.1@…`) | Extension version upgrade | **P1** |
| An extension `reference:` **digest only**, same tag | Extension rebuild | **P2** |
| `imageName:` (`ghcr.io/cloudnative-pg/postgresql`) minor (e.g. `18.6` → `18.7`) | PostgreSQL minor upgrade | **P3** |
| `imageName:` digest only, same tag | Runtime OS rebuild | **P2** (runtime variant) |
| `imageName:` major (e.g. `18` → `19`) | Major upgrade | Out of scope (rule 9) |

In `mrdynamo/containers`:
- a `VERSION` PR needs nothing (it builds and publishes; home-ops then gets a P1 PR);
- a runtime PR belongs to P3;
- an `OLD_VERSION` PR belongs to P1 step 10.

---

## 4. Helper commands

Load them before starting (zsh or bash):

```sh
source <(awk '/^# Primary pod name/,/^tracearr_restart\(\)/' ~/dev/home-ops/docs/cnpg-timescaledb-extension-upgrade.md)
```

```sh
# Primary pod name, and psql as postgres on the primary, NEW session every call (-X).
PRIMARY() { kubectl -n database get cluster postgres -o jsonpath='{.status.currentPrimary}'; }
psqlp() { kubectl -n database exec "$(PRIMARY)" -c postgres -- psql -X -v ON_ERROR_STOP=1 -d tracearr "$@"; }

# Cluster phase + the runtime and extension images each instance actually runs.
pgstate() {
  kubectl -n database get cluster postgres -o jsonpath='{.status.phase}{"  primary="}{.status.currentPrimary}{"\n"}'
  kubectl -n database get pod -l cnpg.io/cluster=postgres,cnpg.io/podRole=instance -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[?(@.name=="postgres")].image}{"\n"}{range .spec.volumes[?(@.image)]}{"  "}{.image.reference}{"\n"}{end}{end}'
}

# Server version and installed extension versions.
extver() { psqlp -At -c "select current_setting('server_version'), string_agg(extname||'='||extversion, ', ' order by extname) from pg_extension where extname like 'timescale%'"; }

# Make the scheduler run every Tracearr job now (scheduler path, not run_job()); prints the start time T0.
# alter_job() returns a table (set-returning), so it is called through LATERAL; count(alter_job(…)) is an error.
jobs_kick() { psqlp -At -c "select now()"; psqlp -At -c "select count(*) from timescaledb_information.jobs j cross join lateral alter_job(j.job_id, next_start => now()) a where j.job_id <> 1 and j.scheduled" >/dev/null; }

# Job health since T0: every row must show ran_since_t0 = t, with no errors listed.
jobs_check() {
  psqlp -c "select s.job_id, j.proc_name, coalesce(j.hypertable_name,'') as hypertable,
                   s.last_successful_finish > '$1' as ran_since_t0,
                   s.total_failures, s.total_crashes, s.consecutive_failures
            from _timescaledb_internal.bgw_job_stat s join timescaledb_information.jobs j using (job_id)
            where s.job_id <> 1 order by 1" \
        -c "select job_id, finish_time, err_message from timescaledb_information.job_errors
            where finish_time > '$1' order by finish_time"
}

# Production's cluster.yaml (home-ops main, or another branch, e.g. a PR's head branch).
# Through the API, not raw.githubusercontent.com: the raw CDN serves a stale copy for up to ~5 min after a merge.
cluster_yaml() { gh api -H 'Accept: application/vnd.github.raw' "repos/mrdynamo/home-ops/contents/kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml?ref=${1:-main}"; }
# Tag of an extension image in a cluster.yaml: prod_tag timescaledb-bridge [branch]
prod_tag() { cluster_yaml "${2:-main}" | grep -o "mrdynamo/$1:[^@]*" | head -1 | cut -d: -f2; }

# RULE 1: OK only when the installed version equals the deployed (home-ops main) tag, for both extensions.
_pending() {
  local i t
  i=$(psqlp -At -c "select extversion from pg_extension where extname = '$1'")
  t=$(prod_tag "$2")
  if [ "$i" = "$t" ]; then echo "OK       $1: installed $i = deployed $t"; else echo "PENDING  $1: installed $i, deployed $t (finish its ALTER first)"; fi
}
pending_alter() { _pending timescaledb timescaledb-bridge; _pending timescaledb_toolkit timescaledb-toolkit; }

# Digest of a published image tag (default :rolling).
ghcr_digest() {
  local tok; tok=$(curl -fsS "https://ghcr.io/token?scope=repository:mrdynamo/$1:pull" | jq -r .token)
  curl -fsSI -H "Authorization: Bearer $tok" \
    -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json' \
    "https://ghcr.io/v2/mrdynamo/$1/manifests/${2:-rolling}" | awk 'tolower($1)=="docker-content-digest:"{print $2}' | tr -d '\r'
}

# Runtime an extension image (repo:tag@sha256:…) was built for, from its label ("none" for old images).
image_runtime() {
  local ref=$1 repo tok m idx cfg
  local acc='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
  repo=${ref#ghcr.io/}; repo=${repo%%[:@]*}
  tok=$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r .token)
  m=$(curl -fsSL -H "Authorization: Bearer $tok" -H "Accept: $acc" "https://ghcr.io/v2/${repo}/manifests/${ref##*@}")
  idx=$(echo "$m" | jq -r '[.manifests[]? | select(.platform.architecture=="amd64")][0].digest // empty')
  [ -n "$idx" ] && m=$(curl -fsSL -H "Authorization: Bearer $tok" -H "Accept: $acc" "https://ghcr.io/v2/${repo}/manifests/${idx}")
  cfg=$(echo "$m" | jq -r .config.digest)
  curl -fsSL -H "Authorization: Bearer $tok" "https://ghcr.io/v2/${repo}/blobs/${cfg}" | jq -r '.config.Labels["io.github.mrdynamo.runtime-image"] // "none"'
}

# RULE 2: every extension image in a cluster.yaml (branch, default main) built for that cluster's runtime tag.
runtime_check() {
  local y rt ref lab
  y=$(cluster_yaml "${1:-main}")
  rt=$(echo "$y" | sed -n 's/^ *imageName: *//p' | head -1); rt=${rt%@*}
  echo "cluster runtime: $rt"
  for ref in $(echo "$y" | grep -o 'ghcr.io/mrdynamo/[^ ]*'); do
    lab=$(image_runtime "$ref"); lab=${lab%@*}
    if [ "$lab" = "$rt" ]; then echo "OK    $ref"
    elif [ "$lab" = "none" ]; then echo "WARN  $ref (built before runtime labels; only acceptable if it is what production already runs)"
    else echo "STOP  $ref was built for $lab"; fi
  done
}

# RULE 3: re-run the tests (incl. the rehearsal from production = home-ops main now) on an exact published image.
# Watches only the run this call dispatched (not whatever rehearsal ran last).
rehearse() {
  local since id i
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gh workflow run rehearse.yaml -R mrdynamo/containers -f app="$1" -f image="$2" || return 1
  for i in $(seq 1 24); do
    sleep 5
    id=$(gh run list -R mrdynamo/containers -w rehearse.yaml -e workflow_dispatch -L5 --json databaseId,createdAt -q "[.[] | select(.createdAt >= \"$since\")] | last | .databaseId // empty")
    [ -n "$id" ] && break
  done
  [ -n "$id" ] || { echo "STOP  the dispatched rehearse run did not appear"; return 1; }
  gh run watch -R mrdynamo/containers "$id" --exit-status
}

# RULE 4: backup through the barman-cloud plugin, taken on the PRIMARY; waits until completed (~20 min). STOP otherwise.
# - target: primary. On a standby, pg_backup_start waits for a restartpoint and gets cancelled
#   ("canceling statement due to conflict with recovery", hot_standby_feedback is off) when the cluster is busy.
# - Full resource name: the short name "backup" resolves to Longhorn's backups.longhorn.io on this cluster.
pgbackup() {
  kubectl -n database apply -f - <<EOF || return 1
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $1
spec:
  cluster:
    name: postgres
  method: plugin
  target: primary
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  local ph i
  for i in $(seq 1 120); do
    ph=$(kubectl -n database get backups.postgresql.cnpg.io "$1" -o jsonpath='{.status.phase}')
    case "$ph" in
      completed) kubectl -n database get backups.postgresql.cnpg.io "$1"; return 0 ;;
      failed) echo "STOP  backup $1 failed: $(kubectl -n database get backups.postgresql.cnpg.io "$1" -o jsonpath='{.status.error}')"; return 1 ;;
    esac
    sleep 30
  done
  echo "STOP  backup $1 still '$ph' after 60 min"; return 1
}

# Apply home-ops main now instead of waiting for the Flux interval.
flux_apply() { flux reconcile kustomization cloudnative-pg-clusters -n database --with-source; }

# After a timescaledb ALTER: end the other client sessions in the tracearr database. They still hold the old
# library and would FATAL on their next query; ending them now makes PgBouncer (session mode, idle server
# connections kept 300 s) drop them before it can hand one to the restarted Tracearr.
tracearr_drop_sessions() { psqlp -At -c "select count(pg_terminate_backend(pid)) from pg_stat_activity where datname = 'tracearr' and backend_type = 'client backend' and pid <> pg_backend_pid()"; }

# Restart Tracearr so its pool reconnects (after every ALTER).
tracearr_restart() { kubectl -n default rollout restart deploy/tracearr && kubectl -n default rollout status deploy/tracearr --timeout=5m; }
```

**Pre-flight** (start of every procedure):

```sh
pgstate        # phase "Cluster in healthy state"; both instances list the same images
for p in postgres-1 postgres-2; do kubectl -n database exec $p -c postgres -- df -h /var/lib/postgresql/data | tail -1; done   # STOP below 2G free
kubectl -n database get cluster postgres -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'                     # ContinuousArchiving=True
extver; pending_alter                                                                                                                # pending_alter: OK, OK
```

**Rolling out** a home-ops merge: run `flux_apply`, then repeat `pgstate` (for example `while true; do clear; pgstate; sleep 15; done`, Ctrl-C to stop) until **both** instances list the new references and the phase is `Cluster in healthy state`. CNPG restarts the replica first, then switches over: a few seconds without writes for every app on the cluster. The other instance stays primary afterwards (`PRIMARY` follows it). Prefer a quiet moment, and keep clear of the nightly `ScheduledBackup` (00:00 UTC).

**Time budget:** each backup takes ~20 min, each job check 5 min, each containers Release a few minutes. A full toolkit P1 + TimescaleDB P1 + PostgreSQL P3 run took ~3.5 h (2026-11-24).

---

## 5. Procedures

Notation: `EXT` is `timescaledb` or `timescaledb_toolkit`; `APP` is `timescaledb-bridge` or `timescaledb-toolkit`; `OLD`/`NEW` are the versions (installed / in the PR's tag); `REF` is the PR's exact new reference (`ghcr.io/mrdynamo/APP:NEW@sha256:…`); `PR` is the home-ops PR number and `BRANCH` its head branch (`gh pr view PR -R mrdynamo/home-ops --json headRefName -q .headRefName`).

### P1: extension version upgrade (OLD → NEW)

1. **Compatibility:** check §6 for notes on `NEW` with the cluster's PostgreSQL minor. STOP on a known incompatibility.
2. **Preconditions:** pre-flight passes (`pending_alter` OK for both); `extver` shows `EXT=OLD`; the PR is `APPROVED`, `CLEAN`. Read `REF` from the branch at this point, not from an earlier note (Renovate may have moved the digest): `REF=$(cluster_yaml BRANCH | grep -o 'ghcr.io/mrdynamo/APP:[^ ]*')`. `runtime_check BRANCH` must print `OK` for `REF`. The other image's line shows what the **branch** has: Renovate does not rebase a PR that has no conflicts, so after an earlier merge it may still show the image `main` has since replaced. That line must be `OK`, or `WARN` if it is the unlabelled image production already runs; the image actually deployed for it was checked in its own procedure.
3. **Rehearse:** `rehearse APP REF` must succeed.
4. **Backup:** `pgbackup pre-EXT-NEW` (dots → dashes, e.g. `pre-timescaledb-2-32-1`). STOP unless `completed`.
5. **Deploy:** merge the PR (`gh pr merge PR -R mrdynamo/home-ops --squash`), then roll out (§4).
6. **Pre-ALTER checks** (production still on OLD, new image mounted):
   ```sh
   extver                                                                    # EXT=OLD still: connections work on the new image
   kubectl -n database exec "$(PRIMARY)" -c postgres -- ls /extensions/EXT/lib/
   kubectl -n database exec "$(PRIMARY)" -c postgres -- ls /extensions/EXT/share/extension/EXT--OLD--NEW.sql
   ```
   - For **timescaledb**: STOP unless `timescaledb-OLD.so`, `timescaledb-tsl-OLD.so`, `timescaledb-NEW.so`, `timescaledb-tsl-NEW.so` and `timescaledb.so` are listed and the update script exists. Then:
     ```sh
     T0=$(jobs_kick | head -1); sleep 300; jobs_check "$T0"                # every row ran_since_t0 = t, no errors
     ```
   - For **timescaledb_toolkit**: STOP unless `timescaledb_toolkit-OLD.so` and `timescaledb_toolkit-NEW.so` are listed and the update script exists. Then:
     ```sh
     psqlp -At -c "select approx_percentile(0.5, percentile_agg(x::float8)) between 400 and 600 from generate_series(1,1000) x"   # t
     ```
   If anything fails here: revert (§7, before the `ALTER`).
7. **ALTER:**
   ```sh
   psqlp -c 'ALTER EXTENSION EXT UPDATE'
   tracearr_drop_sessions                                                    # timescaledb only
   tracearr_restart
   ```
   For timescaledb, the update script restarts the job scheduler on the new version itself (`bgw_startup.sql` → `restart_background_workers()`). Sessions still holding the old library are cut off with `FATAL: extension "timescaledb" version mismatch` on their next query; `tracearr_drop_sessions` ends them at once (including PgBouncer's idle server connections), the Tracearr restart replaces them, and a few logged connection errors just before it are expected. Tracearr runs one replica with the `Recreate` strategy: it is down for the ~30–60 s of its restart (the database is not).
8. **Verify:**
   ```sh
   extver                                                                    # EXT=NEW
   pending_alter                                                             # OK, OK
   T0=$(jobs_kick | head -1); sleep 300; jobs_check "$T0"                    # every row ran_since_t0 = t, no errors
   ```
   For **timescaledb_toolkit**, also repeat the `approx_percentile` query from step 6 (`t`, now on NEW). For **timescaledb**, check Tracearr came back cleanly: `kubectl -n default logs deploy/tracearr --since=10m | grep -iE 'error|fatal'` shows only the cut-off errors from just before its restart.
9. **Record:** update §6 (production state) in this file.
10. **Sync `OLD_VERSION`** in containers. The `Sync Production Versions` workflow has usually opened the PR `OLD_VERSION = production (…)` already (see §1); to run it now: `gh workflow run sync-production-versions.yaml -R mrdynamo/containers`, then `gh pr list -R mrdynamo/containers --state open --search 'OLD_VERSION in:title'`. Its title must name exactly the versions `extver` shows. Merge it **only now**, after step 8 passed, and once its checks pass (`gh pr checks N -R mrdynamo/containers --watch`, then `gh pr merge N -R mrdynamo/containers --squash`); wait for its `Release` run (`gh run list -R mrdynamo/containers -w release.yaml -L3`). The Release republishes `APP:NEW` without the OLD library. Renovate then offers that as a home-ops **digest-only** PR: P2, optional (it changes nothing functionally). If a P3 comes next, leave it open: P3 deploys a newer build of the same tag, and Renovate autocloses the digest PR when the P3 merges.

### P2: extension (or runtime OS) rebuild, same version

A home-ops PR that changes only a digest. Typical causes: an `OLD_VERSION` sync, a build-tooling change, or a CNPG runtime OS rebuild.

1. **Preconditions:** pre-flight passes (`pending_alter` OK for both: required, because the rebuild may drop a library a pending `ALTER` would still need); `runtime_check BRANCH` prints `OK` for the changed image. **If it prints `STOP` (the image was built for another PostgreSQL minor), this PR belongs to P3: do not merge it alone.**
2. **Rehearse** (extension images only): `rehearse APP REF` must succeed.
3. **Deploy:** merge, roll out.
4. **Verify:** `extver` unchanged; `T0=$(jobs_kick | head -1); sleep 300; jobs_check "$T0"` passes. No `ALTER`, no backup required.

### P3: PostgreSQL minor upgrade (e.g. 18.6 → 18.7)

The runtime change and the extension images rebuilt for the new minor go to production **in one commit**, so CNPG restarts once and never runs the new server with libraries built for the old one.

1. **Compatibility:** read §6 and the upstream release notes of every installed extension version for the new minor. If a newer extension version is required first, do that P1 first. STOP until it's done.
2. **Containers:** Renovate opened one runtime PR per app (`RUNTIME_IMAGE` → the new `X.Y-standard-trixie`). Its digest must equal the one in the home-ops runtime PR. These PRs are often opened long before production is ready. A green check from before the last `OLD_VERSION` sync proves nothing, and the bridge's `TestUpgradeFromProduction` fails (expected) while production runs a TimescaleDB that is broken on the new minor (see §6). So after every P1 from step 1 is finished **and its `OLD_VERSION` sync is merged**, update both branches. A plain re-run reuses the old merge commit, with the old `OLD_VERSION`, and fails again.
   ```sh
   gh pr update-branch BRIDGE_PR -R mrdynamo/containers --rebase
   gh pr update-branch TOOLKIT_PR -R mrdynamo/containers --rebase
   gh pr checks BRIDGE_PR -R mrdynamo/containers --watch                     # STOP unless all pass
   gh pr checks TOOLKIT_PR -R mrdynamo/containers --watch
   ```
   Merge both **only when their checks pass** (`gh pr merge N -R mrdynamo/containers --squash`). The bridge's `TestUpgradeFromProduction` runs from production on the old minor to the rebuild on the new minor, with jobs succeeding through the scheduler on the new minor. Wait for both `Release` runs to succeed (`gh run list -R mrdynamo/containers -w release.yaml -L4`).
3. Renovate then opens home-ops digest-only PRs for both extension images. **Do not merge them on their own** (their `runtime_check` prints `STOP` against the old runtime). Read the exact references from the registry instead; both labels must name the runtime PR's exact digest:
   ```sh
   REF1=ghcr.io/mrdynamo/timescaledb-bridge:TS_VER@$(ghcr_digest timescaledb-bridge TS_VER)
   REF2=ghcr.io/mrdynamo/timescaledb-toolkit:TK_VER@$(ghcr_digest timescaledb-toolkit TK_VER)
   image_runtime "$REF1"; image_runtime "$REF2"                              # both: …postgresql:X.Y-standard-trixie@sha256:<runtime PR digest>
   cluster_yaml BRANCH | grep imageName                                      # the same digest
   ```
4. **Rehearse** both exact new references: `rehearse timescaledb-bridge "$REF1"` and `rehearse timescaledb-toolkit "$REF2"`. Each runs on its labelled runtime, the new minor. Both must succeed.
5. **One commit** on the home-ops runtime PR's branch. Rebase it onto `main` first: the P1s changed the extension lines on `main`, so editing them on the old branch conflicts at merge. Work in a separate worktree so no unrelated local changes are committed:
   ```sh
   git fetch origin
   git worktree add ~/dev/home-ops-pX -B BRANCH origin/BRANCH
   cd ~/dev/home-ops-pX
   git rebase origin/main                                                    # STOP on any conflict
   F=kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml
   sed -i -E "s#ghcr.io/mrdynamo/timescaledb-bridge:[^ ]+#$REF1#; s#ghcr.io/mrdynamo/timescaledb-toolkit:[^ ]+#$REF2#" $F
   git diff origin/main -- $F                                                # exactly 3 lines: imageName, bridge REF1, toolkit REF2
   git commit -m "feat(postgres): extension images rebuilt for PostgreSQL X.Y" -- $F
   git push --force-with-lease origin HEAD:BRANCH
   cd ~/dev/home-ops
   ```
   Then `runtime_check BRANCH` must print `OK` for both, with no `WARN` and no `STOP`. The push dismisses earlier reviews, so the PR shows `REVIEW_REQUIRED`. The AI reviewer re-reviews but withholds approval while its earlier blocker thread (asking for exactly this bundle) is unresolved. Resolve that thread and re-run the `AI PR Reviewer` run for the new head, or approve yourself (Renovate is the author):
   ```sh
   gh api graphql -f query='query{repository(owner:"mrdynamo",name:"home-ops"){pullRequest(number:PR){reviewThreads(first:20){nodes{id isResolved comments(first:1){nodes{body}}}}}}}'
   gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"THREAD_ID"}){thread{isResolved}}}'
   gh run rerun "$(gh run list -R mrdynamo/home-ops --branch BRANCH -w 'AI PR Reviewer' -L1 --json databaseId -q '.[0].databaseId')" -R mrdynamo/home-ops
   gh pr view PR -R mrdynamo/home-ops --json reviewDecision,mergeStateStatus   # APPROVED, CLEAN
   ```
6. Pre-flight; backup: `pgbackup pre-pg-X-Y` (completed). It can run while the review re-runs.
7. **Deploy:** merge the runtime PR (Renovate autocloses the extension digest PRs from step 3 and from the P1 `OLD_VERSION` syncs), then roll out until both instances show the new `imageName` and extension references. Then `git worktree remove ~/dev/home-ops-pX`.
8. **Verify:**
   ```sh
   extver                                                                    # X.Y | extension versions unchanged
   pending_alter                                                             # OK, OK
   runtime_check main                                                        # OK, OK
   T0=$(jobs_kick | head -1); sleep 300; jobs_check "$T0"                    # every row ran_since_t0 = t, no errors
   psqlp -At -c "select approx_percentile(0.5, percentile_agg(x::float8)) between 400 and 600 from generate_series(1,1000) x"   # t
   ```
   No `ALTER`: extension versions do not change.
9. **Post-update steps:** read the "Updating" section of the PostgreSQL release announcement and check each conditional step against every database. The 18.7 ones were `gist_trgm_ops` GiST indexes, B-tree indexes on bare `bpchar` (no length), and `NOT NULL NO INHERIT` constraints on partitioned tables. These can be checked before the deploy (they depend on the schema, not the binaries):
   ```sh
   P=$(PRIMARY); for db in $(kubectl -n database exec $P -c postgres -- psql -X -At -c "select datname from pg_database where datallowconn order by 1"); do
     echo "$db: $(kubectl -n database exec $P -c postgres -- psql -X -At -d "$db" -c "
       select (select count(*) from pg_index i join pg_opclass o on o.oid = any(i.indclass::oid[]) where o.opcname = 'gist_trgm_ops') || ' gist_trgm, ' ||
              (select count(distinct i.indexrelid) from pg_index i join pg_class c on c.oid = i.indexrelid join pg_am am on am.oid = c.relam
                 join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey::int2[])
                 where am.amname = 'btree' and a.atttypid = 'bpchar'::regtype and a.atttypmod = -1) || ' bpchar_btree, ' ||
              (select count(*) from pg_constraint where contype = 'n' and connoinherit
                 and conrelid in (select oid from pg_class where relkind = 'p')) || ' notnull_noinherit'")"
   done                                                                      # all 0 → nothing to do
   ```

   Apply any that match (`REINDEX INDEX …`; `ALTER TABLE … ALTER CONSTRAINT … INHERIT` or `DROP CONSTRAINT`).
10. If jobs fail after the deploy: revert the merge commit (§7; back to the old minor with the old builds). Nothing in this procedure is irreversible.

---

## 6. Current state and compatibility notes

**Production (2026-11-24):** PostgreSQL **18.7** (`18.7-standard-trixie@sha256:1abcfd1c…`), timescaledb **2.32.1** (`timescaledb-bridge:2.32.1@sha256:72167b29…`), timescaledb_toolkit **1.28.0** (`timescaledb-toolkit:1.28.0@sha256:55457da8…`). Both images are built for `18.7-standard-trixie@sha256:1abcfd1c…` (`runtime_check main`: `OK`, `OK`) and carry only their own version's library (containers `OLD_VERSION` = `VERSION` for both apps).

**Pending:** nothing. Home-ops #4054 (PostgreSQL 19.0) is a major upgrade: out of scope (rule 9), do not merge.

**Last run (2026-11-24), for reference:**

| Step | PRs | Backup |
|---|---|---|
| toolkit 1.25.0 → 1.28.0 (P1) | home-ops #4002; containers `OLD_VERSION` sync #31 | `pre-timescaledb-toolkit-1-28-0` |
| timescaledb 2.29.2 → 2.32.1 (P1) | home-ops #4036; containers `OLD_VERSION` sync #32 | `pre-timescaledb-2-32-1` |
| PostgreSQL 18.6 → 18.7 (P3) | containers #19 (bridge), #20 (toolkit); home-ops #3931 with both rebuilt references; digest PRs #4116, #4119 autoclosed | `pre-pg-18-7` |

Before it: both new images were listed from the registry and contained the OLD and NEW libraries and the `OLD--NEW` update script. All chunks, hypertables and Tracearr jobs are owned by `tracearr` (TimescaleDB 2.32.0 #10993 requires chunk ownership). No function referenced a library other than the installed versions and the loader (`$libdir/timescaledb`). After it: functions reference `timescaledb-2.32.1` (184), `timescaledb_toolkit-1.28.0` (975) and the loader (3); the pods mount only those libraries.

**Compatibility notes:**

| Combination | Status | Source |
|---|---|---|
| TimescaleDB **< 2.32.1** on PostgreSQL **≥ 18.7** (also 17.12, 16.16) | **Broken**: every job run by the scheduler fails with `cannot drop portal "" while it is being set up`. Connections and queries work; continuous aggregates stop refreshing, compression and retention stop. | [#11038](https://github.com/timescale/timescaledb/issues/11038), fixed in 2.32.1 by [#11015](https://github.com/timescale/timescaledb/pull/11015); 2.32.0 notes: "compatible only with PostgreSQL versions up to 18.6" |
| TimescaleDB 2.30.x, 2.31.x, 2.32.0 | Built by containers, **never offered** in home-ops (`.renovate/overrides.json5`) | the line above |
| A containers runtime PR for a new minor while production runs TimescaleDB < 2.32.1 | The bridge's `TestUpgradeFromProduction` fails with `cannot drop portal` (production's TimescaleDB on the new minor, the line above): expected. Do the TimescaleDB P1 first, then update the PR's branch (P3 step 2) | containers #19, 2026-11-23 |
| TimescaleDB ≥ 2.32.0: chunk operations | Require ownership of the chunk, not only of the hypertable. All Tracearr chunks are owned by `tracearr`, the jobs' owner (2026-11-24) | 2.32.0 notes, #10993 |
| TimescaleDB 2.31.0, 2.32.0 loader changes | Take effect only after a PostgreSQL restart: the P1 rollout restarts both instances before the `ALTER` | 2.31.0 / 2.32.0 notes |
| timescaledb_toolkit `1.27.0` tag | Broken upstream tag (`-dev` crate version); use `1.27.0+p2`. The build forces the clean version anyway. | upstream tag diff |
| timescaledb_toolkit 1.28.0 | No PostgreSQL 18 notes (drops PostgreSQL 15 builds only); direct update script from 1.25.0 | 1.28.0 notes |
| PostgreSQL 18.7 C-extension ABI (CVE-2026-6460) | Requires C extensions rebuilt for 18.7: P3's rebuilds | 18.7 release notes |
| PostgreSQL 18.7 post-update steps | None apply to this cluster (checked 2026-11-17 and again 2026-11-24 after the upgrade on all 10 databases, with the P3 step 9 query) | 18.7 announcement, "Updating" |

**Tracearr specifics:** 9 TimescaleDB jobs (5 continuous-aggregate refreshes, 2 compression, 1 retention, 1 job-stat retention), all `Success` with 0 failures after the 2026-11-24 upgrade (job 1000 has 1 historical crash). No view, continuous aggregate or column depends on toolkit objects. Tracearr runs 1 replica with the `Recreate` strategy; `TIMESCALEDB_AUTO_UPDATE` is not set (neither in the Deployment nor in `tracearr-secret`).

---

## 7. Rollback

| Point | Rollback |
|---|---|
| Before an `ALTER` (any procedure) | Revert the home-ops merge commit and push it straight to `main` (repository admins bypass the PR rule; commits must be signed, history linear): `git pull --ff-only && git revert --no-edit "$(gh pr view PR -R mrdynamo/home-ops --json mergeCommit -q .mergeCommit.oid)" && git push origin main && flux_apply`. CNPG rolls the instances back to the previous images. |
| `ALTER` returned an error | Nothing changed: the update is one transaction. Investigate; the images can still be reverted. |
| After a successful `ALTER` | The previous image lacks the new library, so reverting the image breaks the extension. Restore from the backup taken in that procedure (barman-cloud, `cloudflare-r2-store`). |

---

## 8. Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| Every connection fails: `FATAL: extension "timescaledb" version mismatch: shared library version X; SQL version Y`, or `could not access file "$libdir/timescaledb-Y"` | The deployed image lacks the library of the installed version Y (rule 1 broken, or a wrong `OLD_VERSION`) | Revert the home-ops commit immediately (§7). Then check `pending_alter` and the containers `OLD_VERSION`. |
| `ALTER EXTENSION` fails: `cannot be updated after the old version has already been loaded` | The session ran something before the `ALTER` | Use `psqlp -c 'ALTER EXTENSION … UPDATE'` exactly (fresh `psql -X` session) |
| `ALTER EXTENSION` fails: no update path | The image lacks `EXT--OLD--NEW.sql` | Should have been caught by the P1 pre-ALTER checks; revert the image (§7) |
| Toolkit function errors `could not access file "$libdir/timescaledb_toolkit-…"` | Image without the installed version's library | Revert, or finish the `ALTER` if the update script is present |
| Jobs fail with `cannot drop portal` | TimescaleDB < 2.32.1 on PostgreSQL ≥ 18.7 | Revert the runtime change (P3 step 10) |
| `rehearse` fails: "OLD_VERSION must be the version running in production" | Containers `OLD_VERSION` is out of sync with home-ops `main` | Run/merge the `Sync Production Versions` PR (only if production's `ALTER` is done) |
| Backup stays in `running` or ends `failed` | barman-cloud plugin / object store | Do not proceed (rule 4); `kubectl -n database describe backups.postgresql.cnpg.io <name>` and the `plugin-barman-cloud` container log of the pod in `.status.instanceID.podName` |
| Backup `failed`: `pg_backup_start command: canceling statement due to conflict with recovery` | Taken on the standby (the CNPG default) while the cluster was busy | Use `pgbackup` (it sets `target: primary`) with a new name |
| `kubectl get backup …` says not found / "No resources found" | The short name resolves to Longhorn's `backups.longhorn.io` | Use `backups.postgresql.cnpg.io` |
| `jobs_kick`: `aggregate function calls cannot contain set-returning function calls` | A copy of the helpers from before 2026-11-24 (`count(alter_job(…))`) | Reload the helpers (§4). The failed statement changed nothing. |
| Containers runtime PR still fails after its P1s are done | Its checks were re-run, which reuses the old merge commit (old `OLD_VERSION`) | `gh pr update-branch N -R mrdynamo/containers --rebase` (P3 step 2) |
| Home-ops runtime PR shows `REVIEW_REQUIRED` after the P3 commit; the AI review says "approval withheld" | An unresolved review thread from its earlier blocker | Resolve the thread and re-run the reviewer, or approve (P3 step 5) |

---

## 9. How the claims in this guide were verified (2026-11-17; procedures exercised end to end 2026-11-24)

| Claim | Evidence |
|---|---|
| Only `tracearr` has the extensions | `pg_extension` queried in every database on the cluster |
| CNPG loads versioned libraries from the image volumes | live functions reference `$libdir/timescaledb-2.29.2` and `$libdir/timescaledb_toolkit-1.25.0`; pods load them from `/extensions/*/lib` (`dynamic_library_path = $libdir:/extensions/timescaledb/lib:/extensions/timescaledb_toolkit/lib`) |
| The rehearsal starts from production | `testhelpers.Production` parses home-ops `main` `cluster.yaml` (runtime, extension images, preload and parameters); checked against the live cluster |
| The toolkit update script never needs the old library, and post-install names the library after `default_version` | toolkit 1.27.0 build: `--1.25.0--1.27.0.sql` repoints all 973 C functions to `$libdir/timescaledb_toolkit-1.27.0`; upstream `tools/post-install` renames `timescaledb_toolkit.so` → `-<default_version>.so` |
| A direct TimescaleDB update script exists from any recent version | upstream `sql/CMakeLists.txt` update chain; the image ships `timescaledb--<v>--<VERSION>.sql` for every prior version |
| `ALTER` must be the first statement of a fresh session; stale sessions are cut off; the scheduler restarts itself | TimescaleDB 2.32.0 source: `loader.c` (`should_load_on_alter_extension`), `extension.c` (version-mismatch FATAL), `bgw_startup.sql` (`restart_background_workers()`) |
| Tracearr does not run `ALTER` itself and survives cut-off sessions | Tracearr source at the deployed revision: auto-update only with `TIMESCALEDB_AUTO_UPDATE=true` (unset); pool `error` handler in `db/client.ts` |
| P1 (twice) and P3 run without downtime | 2026-11-24 live run (toolkit 1.28.0, TimescaleDB 2.32.1, PostgreSQL 18.7): one switchover per deploy, jobs `Success` with 0 failures before and after each `ALTER` and after P3, `runtime_check main` `OK`/`OK` at the end |
| Builds match the runtime exactly | build logs: `postgresql-server-dev-18` and `libpq-dev` at the runtime's versions, "Compiling against PostgreSQL version 18.6 using pg_config '/usr/lib/postgresql/18/bin/pg_config'"; the libraries link only `libc` |
