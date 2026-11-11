---
name: timescaledb-cnpg-extension-upgrade
description: 'Upgrade the TimescaleDB or TimescaleDB Toolkit extension version used by the CNPG-managed "postgres" cluster in this home-ops repo. USE FOR: bumping timescaledb/timescaledb_toolkit extension images, building the bridge image in the home-operations/containers repo (apps/timescaledb-bridge, apps/timescaledb-toolkit), running ALTER EXTENSION UPDATE against CNPG safely. Prevents the class of outage caused by version-string mismatches, wrong build sources, and writing to a replica instead of the primary.'
---

# TimescaleDB / Toolkit extension upgrade (CNPG)

Image build sources live in `home-operations/containers`:
`apps/timescaledb-bridge/` (core `timescaledb`, needs a bridge) and
`apps/timescaledb-toolkit/` (`timescaledb_toolkit`, no bridge needed).
This repo (home-ops) only references the built image digest in the CNPG
`Cluster` manifest's `spec.postgresql.extensions[]` list.

## Why this is dangerous if done carelessly

`timescaledb` is loaded via `shared_preload_libraries`. On **every** new
backend connection (not just calls to its functions), Postgres compares:
- the version string **compiled into** the `.so` file, against
- `pg_extension.extversion`, and (for timescaledb specifically) also against
- `_timescaledb_catalog.metadata` (`key = 'timescaledb_version'`).

Any mismatch between these three FATALs the connection immediately — this
breaks every client, app, and the CNPG metrics collector at once, before any
query runs. `timescaledb_toolkit` is NOT in `shared_preload_libraries`, so a
mismatch there only breaks sessions that call its functions, not all
connections — lower blast radius, same discipline still applies.

## Step 0 — gather facts, don't assume

Never guess versions or upgrade paths. Verify all of this first, read-only:

```bash
# Identify the actual primary (writes will fail on a replica)
kubectl cnpg status postgres -n database
# or: kubectl get pods -n database -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary

# Current installed extension versions
kubectl exec -n database <primary-pod> -c postgres -- psql -U postgres -d <db> -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname LIKE 'timescaledb%';"

# For core timescaledb only — a SECOND version record that must also match
kubectl exec -n database <primary-pod> -c postgres -- psql -U postgres -d <db> -c \
  "SELECT key, value FROM _timescaledb_catalog.metadata WHERE key = 'timescaledb_version';"
```

Then confirm a real upgrade path exists **before** building anything:
- Core timescaledb: check `sql/updates/` in the target tag's GitHub tree for a
  chain of `<from>--<to>.sql` files connecting your current version to target.
  `https://api.github.com/repos/timescale/timescaledb/contents/sql/updates?ref=<TARGET_TAG>`
- Toolkit: fetch `extension/timescaledb_toolkit.control` at the target tag and
  check the `upgradeable_from` field lists your current version.
  `https://raw.githubusercontent.com/timescale/timescaledb-toolkit/<TARGET_TAG>/extension/timescaledb_toolkit.control`

**Known upstream gotcha**: a TimescaleDB git tag's `version.config` does not
always match the tag name — e.g. tag `2.27.0` embeds `version = 2.27.0-dev`.
If you land on a `-dev`-suffixed version, there is no upgrade script starting
from that exact string upstream, and you must relabel both `pg_extension` and
`_timescaledb_catalog.metadata` to the clean version before upgrading further
(see Recovery section below). Toolkit's version comes cleanly from
`Cargo.toml` and does not have this quirk.

## Step 1 — build the image (containers repo)

### Core timescaledb (bridge pattern required)

`apps/timescaledb-bridge/docker-bake.hcl` variables:
- `VERSION` — target version to upgrade TO.
- `OLD_VERSION` — must equal the **exact current `extversion`**, not
  necessarily the raw git tag (see the `-dev` gotcha above).
- `RUNTIME_IMAGE` — must match the CNPG cluster's postgres image exactly
  (same tag+digest as `spec.imageName` in the `Cluster` manifest).
- `PG_DEV_PKG_VERSION` — must match the PGDG `postgresql-server-dev-<major>`
  package version available for that exact runtime minor version.

The Dockerfile builds **both** the new (`VERSION`) and old (`OLD_VERSION`)
loaders from source (never from a pre-built image) — this guarantees the
compiled-in version string matches the label exactly, and both the main
`timescaledb-<version>.so` and the separate `timescaledb-tsl-<version>.so`
(community-licensed functions, a distinct file) are captured.

```bash
cd apps/timescaledb-bridge
docker buildx bake --push image
```

### Toolkit (no bridge, simpler)

`apps/timescaledb-toolkit/docker-bake.hcl`: bump `VERSION`, keep `PG_IMAGE`
and `PG_DEV_PKG_VERSION` matching the CNPG runtime's exact minor version.

```bash
cd apps/timescaledb-toolkit
docker buildx bake --push image
```

Optional pre-flight verification (no cluster access needed) before pushing to
production — inspect what the build actually produced:
```bash
docker buildx bake --load image-local
CID=$(docker create <app>:<version>)
docker cp "$CID:/lib" /tmp/check-lib   # or /share/extension
docker rm "$CID"
ls /tmp/check-lib
```

## Step 2 — deploy (home-ops repo)

Update the extension's `image.reference` (with digest) in the CNPG `Cluster`
manifest under `kubernetes/apps/database/cloudnative-pg/cluster/`, commit,
let Flux reconcile, then confirm health before touching SQL:

```bash
kubectl get pods -n database -l cnpg.io/cluster=postgres -w
```

## Step 3 — run the upgrade (one command at a time, primary only)

Rules that prevent outages:
- Always target the **primary** pod explicitly (`kubectl cnpg status` to
  confirm which one) — writes to a replica fail with
  `cannot execute UPDATE in a read-only transaction`, and CNPG can fail over
  between sessions.
- Never go through pgBouncer/pooler for these commands.
- `ALTER EXTENSION ... UPDATE;` must be the **only** statement in its psql
  invocation — a fresh session, first command, nothing else run before it
  (not even a `SELECT`). Combining commands or reusing a session that already
  touched the extension causes:
  `ERROR: extension "..." cannot be updated after the old version has already been loaded`
- Each step below is its own separate `kubectl exec`/`psql -c` invocation —
  never combine into one `-c "...; ...;"` string, never paste multiple
  statements into one interactive `psql` session.

```bash
# Verify (read-only)
kubectl exec -n database <primary-pod> -c postgres -- psql -U postgres -d <db> -c \
  "SELECT extname, extversion FROM pg_extension WHERE extname='<ext>';"

# Run the upgrade — first and only statement in this session
kubectl exec -n database <primary-pod> -c postgres -- psql -U postgres -d <db> -c \
  "ALTER EXTENSION <ext> UPDATE;"

# Verify
kubectl exec -n database <primary-pod> -c postgres -- psql -U postgres -d <db> -c \
  "SELECT extversion FROM pg_extension WHERE extname='<ext>';"
```

## Recovery: relabeling a `-dev`-tagged version (core timescaledb only)

Only needed if you land on a `2.x.y-dev`-style installed version with no
upstream upgrade script. Do this only when connections are healthy (a
matching `.so` must already be on disk for the label you're about to set —
verify the built image contains it before relabeling, or every connection
will FATAL immediately):

```bash
# 1. Relabel the SQL-level catalog
kubectl exec -n database <primary-pod> -c postgres -- psql -U postgres -d <db> -c \
  "UPDATE pg_extension SET extversion = '<clean-version>' WHERE extname = 'timescaledb';"

# 2. Relabel TimescaleDB's own internal metadata table (separate check!)
kubectl exec -n database <primary-pod> -c postgres -- psql -U postgres -d <db> -c \
  "UPDATE _timescaledb_catalog.metadata SET value = '<clean-version>' WHERE key = 'timescaledb_version';"

# 3. Now the standard upgrade path applies (Step 3 above)
```

If you rebuild the old-loader from source, patch its `version.config` in the
Dockerfile (`sed -i "s/^version[[:space:]]*=.*/version = ${OLD_VERSION}/" version.config`
before `./bootstrap`) so the compiled binary's internal string matches the
label you intend to set — never just rename/copy `.so` bytes to a new
filename, the internal compiled-in version string is checked independently
of the filename and will still FATAL on mismatch.

## Post-upgrade

- Confirm application connectivity, not just `extversion`.
- Retire the bridge image reference once the final version is confirmed
  stable (or keep reusing the same bridge image going forward if that's your
  practice — it already contains the correct final-version files).
