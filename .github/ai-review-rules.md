# Review rules for this repository

Facts about how this cluster is built and which upstream features it relies on. Use
them to decide whether an upstream change is actionable: a breaking change in a
feature listed as **not used** is not a finding; a change in a feature listed as
**used** must be checked against the file named.

These facts were true when written. If the diff or the files you read contradict
them, trust the files and say so in the review.

## Platform

- **OS / Kubernetes**: Talos Linux and Kubernetes; the pinned versions are
  `talosVersion` / `kubernetesVersion` in `talos/topf.yaml`. Upgrades are rolled by
  tuppr (`kubernetes/apps/system-upgrade/tuppr/upgrades/`). A chart or CRD bump that
  raises its minimum Kubernetes version above `kubernetesVersion` is a `blocker`.
- **GitOps**: Flux, installed and managed by flux-operator + a `FluxInstance`
  (`kubernetes/apps/flux-system/`). Every app is a Flux `Kustomization` (`ks.yaml`)
  pointing at an `app/` directory, with `postBuild.substitute` variables (`${APP}`,
  `VOLSYNC_*`, …) and shared Kustomize components in `kubernetes/components/`.
- **Chart delivery**: Helm charts come from `OCIRepository` sources pinned by tag
  **and** digest, many with cosign `verify` blocks. A tag bump that leaves the old
  digest, or a changed signing identity upstream, breaks reconciliation.
- **Most apps use bjw-s `app-template`** (`oci://ghcr.io/bjw-s-labs/helm/app-template`).
  For an app-template chart bump, the relevant changelog is bjw-s-labs/helm-charts
  `app-template-<version>` / `common-<version>`, and every HelmRelease using it is in
  scope. For a container bump inside an app-template HelmRelease, the chart is
  unchanged and only the app's own release notes matter.
- **Mirrored charts**: some charts come from `ghcr.io/home-operations/charts-mirror/*`
  (e.g. longhorn, volsync-perfectra1n). The upstream project is the real source of
  release notes, not the mirror.

## Networking

- **CNI**: Cilium, `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`.
  - **Used**: kube-proxy replacement, native routing with auto direct node routes,
    BPF masquerade with host legacy routing (Talos workaround), BGP control plane
    (`bgp.yaml`, `networks.yaml`), LB IPAM, maglev + DSR load balancing, Gateway API,
    Hubble (relay + UI), local redirect policy, socket LB in host namespace only,
    `cni.exclusive: false` (kept non-exclusive for Multus, which is not currently
    deployed).
  - **Not used**: L2 announcements, cluster-pool IPAM (IPAM mode is `kubernetes`),
    tunnel/VXLAN routing.
- **Ingress**: Gateway API (`gateway.networking.k8s.io/v1` Gateway + HTTPRoute,
  `v1beta1` ReferenceGrant) implemented by **Cilium** (`gatewayClassName: cilium`).
  Gateway API CRDs come from the wiremind `gateway-api-crds` chart. Features of
  other Gateway implementations (Envoy Gateway, Istio, NGINX) are not actionable.
  Experimental-channel-only Gateway API changes matter only if Cilium supports them.
- **DNS**: CoreDNS in-cluster, k8s-gateway for split DNS, external records via
  external-dns-style controllers for Cloudflare and UniFi.

## Certificates and secrets

- **cert-manager**: a Let's Encrypt production `ClusterIssuer` using **ACME DNS-01
  with Cloudflare only**, plus a self-signed CA issuer and trust-manager.
  **Not used**: HTTP-01, Vault, Venafi, other DNS-01 providers.
- **external-secrets**: one `ClusterSecretStore` named `onepassword` using the
  **1Password Connect** provider (`connectHost`), not the 1Password SDK provider.
  Every `ExternalSecret` uses `external-secrets.io/v1`. Changes to other providers
  are not actionable. A Connect-server image bump lives in
  `kubernetes/apps/external-secrets/onepassword/`.
- Secrets in git are SOPS-encrypted (`*.sops.yaml`). Never quote their contents.

## Storage, databases, backups

- **Block storage**: Longhorn (`kubernetes/apps/storage/longhorn/`), storage class
  `longhorn-fast` for almost everything, default replica count 3,
  `replicaAutoBalance: least-effort`. Longhorn upgrades must not skip minor versions;
  check the upstream upgrade path whenever the minor version moves.
- **Local storage**: OpenEBS hostpath (`openebs-hostpath`) for a few workloads.
- **PVC backups**: VolSync from the **perfectra1n fork** with the **kopia** mover
  (shared component `kubernetes/components/volsync/`, `copyMethod: Snapshot`).
  Upstream backube/volsync restic/rclone/rsync changes are not actionable unless the
  fork picked them up; check perfectra1n/volsync release notes.
- **Postgres**: CloudNativePG, one `Cluster` named `postgres`
  (`kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml`), 2 instances on
  `longhorn-fast`, image `ghcr.io/cloudnative-pg/postgresql` (`-standard-trixie`),
  backups through the **barman-cloud plugin** to an object store (not the in-tree
  `barmanObjectStore`), with `postgresql.extensions` image volumes for
  **timescaledb** and **timescaledb_toolkit**, and a `pooler-rw` Pooler. Managed
  roles/databases include authentik, dispatcharr, gatus, litellm, paperless, pgadmin,
  tracearr. A Postgres **major** bump, a CNPG minimum-PG change, or an extension
  image bump that changes the extension version needs the
  `timescaledb-cnpg-extension-upgrade` skill — read it.
- **Cache**: Dragonfly (Redis-compatible), shared by several apps.

## Observability

- Metrics: kube-prometheus-stack (Prometheus Operator CRDs, `ServiceMonitor`s used
  across charts), prometheus-adapter, blackbox-exporter, assorted exporters.
- Dashboards: **grafana-operator** (`kind: Grafana` instance and
  `GrafanaDashboard`/`GrafanaDatasource` CRs), not the standalone Grafana chart.
  A Grafana image bump is set on the `Grafana` CR in
  `kubernetes/apps/observability/grafana/instance/grafana.yaml`.
- Logs: fluent-bit shipping to VictoriaLogs (`victoria-logs-single`).
- Alerting: Alertmanager via kube-prometheus-stack, plus silence-operator.

## Conventions a change must keep

- **Resources**: memory `requests` == memory `limits`, at the smallest value that
  works. CPU has a `request` only — **no CPU limits**. A chart bump that introduces
  default CPU limits, or a values change that sets one, is a finding.
- **Images**: prefer `ghcr.io` over `docker.io` when the same image is published
  there. Every image is pinned `tag@sha256:digest`. A bump that drops the digest is a
  finding.
- **Domains**: internal domains are always templated (`${INTERNAL_SECRET_DOMAIN}` or
  release-name templates), never hardcoded. Never print the resolved value.
- **Manifests**: every YAML document carries a `yaml-language-server` `$schema`
  comment; keep it if the file is rewritten.

## What makes a review useful here

- Name the file in this repo that a breaking change touches, and the exact values key
  or field. "May affect configuration" with no file is not useful.
- For a Helm chart bump, a values key that this repo sets and that the new chart
  renamed, removed, or re-defaulted is a finding even when the release notes never
  mention it. Konflate's rendered diff shows the effect; the chart's values.yaml at
  both tags shows the cause.
- Say explicitly when a breaking change is dismissed because this repo does not use
  the feature, and name the feature ("HTTP-01 not used").
- For CRD-shipping charts (cert-manager, CNPG, external-secrets, Gateway API,
  Prometheus Operator, Longhorn, VolSync), check for removed API versions still
  referenced anywhere under `kubernetes/`.
