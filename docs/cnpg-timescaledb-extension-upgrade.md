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
| `OLD_VERSION = production (…)` | `Sync Production Versions` workflow (hourly) | **Manual**, only after the `ALTER` (P1 step 10) |

Every PR runs, per app:
- `TestFreshInstall`: the image installs and works; for TimescaleDB, jobs run through the scheduler.
- `TestUpgradeFromProduction`: the rollout rehearsed from production exactly (home-ops `main`: runtime, every extension image, preload and parameters). It restarts on the new image with the same data, requires connections, jobs and functions to keep working on the old version, runs `ALTER EXTENSION … UPDATE` via `psql -X`, and requires everything to work on the new version. It fails if `OLD_VERSION` is not production's version.

**PRs in `mrdynamo/home-ops`** (Renovate, never automerged): see §3.

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
jobs_kick() { psqlp -At -c "select now()"; psqlp -At -c "select count(alter_job(job_id, next_start => now())) from timescaledb_information.jobs where job_id <> 1 and scheduled" >/dev/null; }

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
cluster_yaml() { curl -fsSL "https://raw.githubusercontent.com/mrdynamo/home-ops/${1:-main}/kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml"; }
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
rehearse() {
  gh workflow run rehearse.yaml -R mrdynamo/containers -f app="$1" -f image="$2" && sleep 10
  gh run watch -R mrdynamo/containers "$(gh run list -R mrdynamo/containers -w rehearse.yaml -L1 --json databaseId -q '.[0].databaseId')" --exit-status
}

# RULE 4: backup through the barman-cloud plugin; waits until completed (~20 min). STOP if it does not complete.
pgbackup() {
  kubectl -n database apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $1
spec:
  cluster:
    name: postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  kubectl -n database wait "backup/$1" --for=jsonpath='{.status.phase}'=completed --timeout=45m \
    && kubectl -n database get backup "$1"
}

# Apply home-ops main now instead of waiting for the Flux interval.
flux_apply() { flux reconcile kustomization cloudnative-pg-clusters -n database --with-source; }

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

**Rolling out** a home-ops merge: run `flux_apply`, then repeat `pgstate` (for example `while true; do clear; pgstate; sleep 15; done`, Ctrl-C to stop) until **both** instances list the new references and the phase is `Cluster in healthy state`. CNPG restarts the replica first, then switches over: a few seconds without writes for every app on the cluster. Prefer a quiet moment.

---

## 5. Procedures

Notation: `EXT` is `timescaledb` or `timescaledb_toolkit`; `APP` is `timescaledb-bridge` or `timescaledb-toolkit`; `OLD`/`NEW` are the versions (installed / in the PR's tag); `REF` is the PR's exact new reference (`ghcr.io/mrdynamo/APP:NEW@sha256:…`); `PR` is the home-ops PR number and `BRANCH` its head branch (`gh pr view PR -R mrdynamo/home-ops --json headRefName -q .headRefName`).

### P1: extension version upgrade (OLD → NEW)

1. **Compatibility:** check §6 for notes on `NEW` with the cluster's PostgreSQL minor. STOP on a known incompatibility.
2. **Preconditions:** pre-flight passes (`pending_alter` OK for both); `extver` shows `EXT=OLD`; `runtime_check BRANCH` prints `OK` for `REF` (and `OK`, or for unchanged images `WARN`, for the rest).
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
   tracearr_restart
   ```
   For timescaledb, the update script restarts the job scheduler on the new version itself (`bgw_startup.sql` → `restart_background_workers()`). Sessions still holding the old library are cut off with `FATAL: extension "timescaledb" version mismatch` on their next query; the Tracearr restart replaces them, and a few logged connection errors just before it are expected.
8. **Verify:**
   ```sh
   extver                                                                    # EXT=NEW
   pending_alter                                                             # OK, OK
   T0=$(jobs_kick | head -1); sleep 300; jobs_check "$T0"                    # every row ran_since_t0 = t, no errors
   ```
9. **Record:** update §6 (production state) in this file.
10. **Sync `OLD_VERSION`** in containers. The `Sync Production Versions` workflow opens a PR `OLD_VERSION = production (…)` within the hour. To run it now: `gh workflow run sync-production-versions.yaml -R mrdynamo/containers`. Merge that PR **only now**, after step 8 passed, and once its checks pass. Its Release republishes `APP:NEW` without the OLD library. Renovate then offers that as a home-ops **digest-only** PR, which is P2 (optional: it changes nothing functionally).

### P2: extension (or runtime OS) rebuild, same version

A home-ops PR that changes only a digest. Typical causes: an `OLD_VERSION` sync, a build-tooling change, or a CNPG runtime OS rebuild.

1. **Preconditions:** pre-flight passes (`pending_alter` OK for both: required, because the rebuild may drop a library a pending `ALTER` would still need); `runtime_check BRANCH` prints `OK` for the changed image. **If it prints `STOP` (the image was built for another PostgreSQL minor), this PR belongs to P3: do not merge it alone.**
2. **Rehearse** (extension images only): `rehearse APP REF` must succeed.
3. **Deploy:** merge, roll out.
4. **Verify:** `extver` unchanged; `T0=$(jobs_kick | head -1); sleep 300; jobs_check "$T0"` passes. No `ALTER`, no backup required.

### P3: PostgreSQL minor upgrade (e.g. 18.6 → 18.7)

The runtime change and the extension images rebuilt for the new minor go to production **in one commit**, so CNPG restarts once and never runs the new server with libraries built for the old one.

1. **Compatibility:** read §6 and the upstream release notes of every installed extension version for the new minor. If a newer extension version is required first, do that P1 first. STOP until it's done.
2. **Containers:** Renovate opened one runtime PR per app (`RUNTIME_IMAGE` → the new `X.Y-standard-trixie`). Its digest must equal the one in the home-ops runtime PR. Merge both **only when their checks pass**. The bridge's `TestUpgradeFromProduction` runs from production on the old minor to the rebuild on the new minor, with jobs succeeding through the scheduler on the new minor. Wait for both `Release` runs to succeed.
3. Renovate then opens home-ops digest-only PRs for both extension images. **Do not merge them on their own** (their `runtime_check` prints `STOP` against the old runtime).
4. **Rehearse** both exact new references: `rehearse timescaledb-bridge REF1` and `rehearse timescaledb-toolkit REF2`. Each runs on its labelled runtime, the new minor. Both must succeed.
5. **One commit:** on the home-ops runtime PR's branch, set both extension references to `REF1` and `REF2` and push. Then `runtime_check BRANCH` must print `OK` for both.
6. Pre-flight; backup: `pgbackup pre-pg-X-Y` (completed).
7. **Deploy:** merge the runtime PR (Renovate closes the two digest PRs), then roll out until both instances show the new `imageName` and extension references.
8. **Verify:**
   ```sh
   extver                                                                    # X.Y | extension versions unchanged
   T0=$(jobs_kick | head -1); sleep 300; jobs_check "$T0"                    # every row ran_since_t0 = t, no errors
   ```
   No `ALTER`: extension versions do not change.
9. **Post-update steps:** read the "Updating" section of the PostgreSQL release announcement and check each conditional step against every database (for example, `gist_trgm_ops` GiST indexes, B-tree indexes on bare `bpchar`, `NOT NULL NO INHERIT` constraints on partitioned tables were the 18.7 ones). Apply any that match.
10. If jobs fail after the deploy: revert the merge commit (back to the old minor with the old builds). Nothing in this procedure is irreversible.

---

## 6. Current state and compatibility notes

**Production (2026-11-17):** PostgreSQL **18.6** (`18.6-standard-trixie@sha256:de572898…`), timescaledb **2.29.2** (`timescaledb-bridge:2.29.2@sha256:9d540efa…`), timescaledb_toolkit **1.25.0** (`timescaledb-toolkit:1.25.0@sha256:ed18523d…`). Both images predate runtime labels (`runtime_check` prints `WARN` for them; expected until they are replaced).

**Pending, in this order:**
1. timescaledb_toolkit **1.25.0 → 1.27.0** (P1). Containers #11 (upstream tag `1.27.0+p2`; plain `1.27.0` shipped a `-dev` crate version). Its home-ops PR follows its merge.
2. timescaledb **2.29.2 → 2.32.1** (P1), once 2.32.1 is released (release PR [timescale/timescaledb#11076](https://github.com/timescale/timescaledb/pull/11076), dated 2026-11-19).
3. PostgreSQL **18.6 → 18.7** (P3): home-ops #3931 plus the containers 18.7 runtime PRs. Only after item 2.

Home-ops #3994 (bridge 2.29.2 digest-only, from a rebuild) is not needed: close it.

**Compatibility notes:**

| Combination | Status | Source |
|---|---|---|
| TimescaleDB **< 2.32.1** on PostgreSQL **≥ 18.7** (also 17.12, 16.16) | **Broken**: every job run by the scheduler fails with `cannot drop portal "" while it is being set up`. Connections and queries work; continuous aggregates stop refreshing, compression and retention stop. | [#11038](https://github.com/timescale/timescaledb/issues/11038), fixed in 2.32.1 by [#11015](https://github.com/timescale/timescaledb/pull/11015); 2.32.0 notes: "compatible only with PostgreSQL versions up to 18.6" |
| TimescaleDB 2.30.x, 2.31.x, 2.32.0 | Built by containers, **never offered** in home-ops (`.renovate/overrides.json5`) | the line above |
| timescaledb_toolkit `1.27.0` tag | Broken upstream tag (`-dev` crate version); use `1.27.0+p2`. The build forces the clean version anyway. | upstream tag diff |
| PostgreSQL 18.7 post-update steps | None apply to this cluster (checked 2026-11-17 on every database) | 18.7 announcement, "Updating" |

**Tracearr specifics:** 9 TimescaleDB jobs (5 continuous-aggregate refreshes, 2 compression, 1 retention, 1 job-stat retention), all `Success` with 0 failures on 2026-11-17 (job 1000 has 1 historical crash). No view, continuous aggregate or column depends on toolkit objects.

---

## 7. Rollback

| Point | Rollback |
|---|---|
| Before an `ALTER` (any procedure) | `git revert` the home-ops merge commit, push, `flux_apply`. CNPG rolls the instances back to the previous images. |
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
| Backup stays in `running` or ends `failed` | barman-cloud plugin / object store | Do not proceed (rule 4); `kubectl -n database describe backup <name>` |

---

## 9. How the claims in this guide were verified (2026-11-17)

| Claim | Evidence |
|---|---|
| Only `tracearr` has the extensions | `pg_extension` queried in every database on the cluster |
| CNPG loads versioned libraries from the image volumes | live functions reference `$libdir/timescaledb-2.29.2` and `$libdir/timescaledb_toolkit-1.25.0`; pods load them from `/extensions/*/lib` (`dynamic_library_path = $libdir:/extensions/timescaledb/lib:/extensions/timescaledb_toolkit/lib`) |
| The rehearsal starts from production | `testhelpers.Production` parses home-ops `main` `cluster.yaml` (runtime, extension images, preload and parameters); checked against the live cluster |
| The toolkit update script never needs the old library, and post-install names the library after `default_version` | toolkit 1.27.0 build: `--1.25.0--1.27.0.sql` repoints all 973 C functions to `$libdir/timescaledb_toolkit-1.27.0`; upstream `tools/post-install` renames `timescaledb_toolkit.so` → `-<default_version>.so` |
| A direct TimescaleDB update script exists from any recent version | upstream `sql/CMakeLists.txt` update chain; the image ships `timescaledb--<v>--<VERSION>.sql` for every prior version |
| `ALTER` must be the first statement of a fresh session; stale sessions are cut off; the scheduler restarts itself | TimescaleDB 2.32.0 source: `loader.c` (`should_load_on_alter_extension`), `extension.c` (version-mismatch FATAL), `bgw_startup.sql` (`restart_background_workers()`) |
| Tracearr does not run `ALTER` itself and survives cut-off sessions | Tracearr source at the deployed revision: auto-update only with `TIMESCALEDB_AUTO_UPDATE=true` (unset); pool `error` handler in `db/client.ts` |
| Builds match the runtime exactly | build logs: `postgresql-server-dev-18` and `libpq-dev` at the runtime's versions, "Compiling against PostgreSQL version 18.6 using pg_config '/usr/lib/postgresql/18/bin/pg_config'"; the libraries link only `libc` |
