---
name: kguardian-policies
description: Generate, audit, review and commit network policies (and seccomp/PSS recommendations) from kguardian for workloads in this home-ops repo. Use when asked to implement kguardian recommendations, write a NetworkPolicy or CiliumNetworkPolicy for an app, or promote an AuditNetworkPolicy to enforcement.
---

# kguardian policies for home-ops

kguardian observes pod traffic and syscalls with eBPF and writes least-privilege
policy YAML from what it saw. It never applies anything. You review the output,
turn it into hand-maintained manifests in this repo, and let Flux apply them.

This file is committed to a public repository. Never put secrets, internal
hostnames, IP addresses, or pod IPs in policies, comments, commit messages or
this skill. Generated output contains pod IPs and peer details: treat it as
scratch and never commit it as-is.

## Environment facts

- CNI is Cilium (`enable-policy: default`, `enable-k8s-networkpolicy: true`), so
  both `NetworkPolicy` and `CiliumNetworkPolicy` are enforced. They are additive
  and can coexist on a pod.
- Ingress is Gateway API (`HTTPRoute`) served by Cilium gateways, not an ingress
  controller. Traffic from a gateway reaches pods as the Cilium `ingress`
  entity (or `host`/`remote-node` depending on path); it is easy to miss.
- kguardian is deployed from `kubernetes/apps/kguardian/`. The CRDs
  `AuditNetworkPolicy`, `AuditClusterNetworkPolicy` and `SeccompProfile`
  (group `kguardian.dev`) are installed.
- The CLI is pinned in `.mise.toml` as `github:kguardian-dev/kguardian` with
  `version_prefix = "advisor/v"` and `bin = "kubectl-kguardian"`. Renovate
  updates it. Run `mise install` in the repo, then use `kubectl kguardian`
  from inside the repo directory (outside it the mise shim has no version).
- The only existing hand-written policy is
  `kubernetes/apps/storage/longhorn/app/networkpolicy.yaml`. Follow its style:
  schema comment, a comment explaining why the policy exists, one file per app
  at `kubernetes/apps/<ns>/<app>/app/networkpolicy.yaml`, listed in that
  directory's `kustomization.yaml`.

## CLI usage (verified against advisor v1.12.0)

The broker service in this cluster is named `kguardian-broker`, but the CLI
defaults to `broker`. Always pass `--broker-service kguardian-broker`.

```sh
# one pod / all pods in a namespace / everything; kubernetes (default) or cilium
kubectl kguardian --broker-service kguardian-broker -n <ns> \
  gen networkpolicy [pod] [-a | -A] [-t kubernetes|cilium] --output-dir <scratch-dir>

# syscall allow-list (SeccompProfile CR); default action SCMP_ACT_ERRNO
kubectl kguardian --broker-service kguardian-broker -n <ns> \
  gen seccomp [pod] [--all | -A] --output-dir <scratch-dir>

# posture / PSS view and a securityContext patch recommendation
kubectl kguardian --broker-service kguardian-broker profile get <ns>/<Kind>/<name>
kubectl kguardian --broker-service kguardian-broker profile export <ns>/<Kind>/<name> --format pss

# audit -> enforce (Kubernetes NetworkPolicy only)
kubectl kguardian audit promote <name> -n <ns> --output-dir <scratch-dir>
kubectl kguardian audit promote-cluster <name> --target-namespace <ns>
```

- `--dry-run` is on by default; output goes to files. Use a scratch directory
  outside the repo (for example under `$TMPDIR`), never `./network-policies`.
- Generation is per pod. A pod with no recorded traffic returns
  "No pod traffic found in database"; that is normal for idle replicas and does
  not stop the other pods from being generated.
- Let kguardian observe for days, including periodic jobs (cron jobs, backups,
  cert renewals, Renovate/Flux reconciles), before trusting the baseline.

## Workflow

1. **Pick the workload** and read its manifests under `kubernetes/apps/<ns>/<app>/`
   (HelmRelease values, HTTPRoute, database/dragonfly components, ExternalSecrets)
   so you know what traffic is *expected*, not only what was observed.
2. **Generate** into a scratch directory. For the audit step use
   `-t kubernetes` (the audit CRDs are byte-identical to `NetworkPolicy` and
   cannot be Cilium). For final enforcement prefer `-t cilium`.
3. **Consolidate by hand.** Generated output is a draft, not a deliverable.
   See "Cleaning generated output" below.
4. **Audit first.** Commit the cleaned policy as an `AuditNetworkPolicy`
   (same spec as a `NetworkPolicy`) and let the evaluator report would-deny
   flows in the kguardian UI for a few days. Fix gaps, repeat.
5. **Enforce.** Either `kubectl kguardian audit promote` (Kubernetes
   `NetworkPolicy`) or write the `CiliumNetworkPolicy` from the audited spec.
   Commit it, remove the audit resource, and let Flux apply. Enforce one
   workload at a time, low-risk apps first.
6. **Verify after rollout**: the app is healthy, its HTTPRoute still serves,
   Prometheus targets are up, and `hubble observe --verdict DROPPED` (or the
   kguardian would-deny view) shows no unexpected drops.

## Cleaning generated output

Observed in real generated Cilium output; fix all of these before committing:

- **Per-pod names and selectors.** The policy is named after one pod and the
  `endpointSelector` includes `pod-template-hash`, which changes on every
  rollout and would stop matching. Replace with a stable workload selector
  (`app.kubernetes.io/name`, `app.kubernetes.io/instance`, or the
  `controller` label) and a stable policy name such as `<app>`.
- **Duplicated replicas.** Generate for one pod per workload (or merge) and
  dedupe rules across replicas.
- **Peer IPs.** Ingress and egress may use `fromCIDR`/`toCIDR` with `/32` pod or
  service IPs. Pod IPs are ephemeral: replace with `toEndpoints`/`fromEndpoints`
  label selectors (include `k8s:io.kubernetes.pod.namespace` for cross-namespace
  peers). Never commit raw cluster IPs; this repo is public.
- **External egress.** Calls to SaaS or API providers appear as `/32` CIDRs
  that rotate. Rewrite as `toFQDNs` (`matchName`/`matchPattern`) and make sure a
  DNS rule with `rules.dns` is present so Cilium can learn the addresses.
  Anything you cannot name belongs in an explicit, commented `world` rule.
- **Host / node traffic.** Probes and the kguardian controller show up as
  `host`/`remote-node` entities. Keep `fromEntities: [host, remote-node]`
  for kubelet probes if the app uses them; do not include entities that exist
  only because the observer itself connected.
- **Gateway ingress.** Add the gateway path deliberately (Cilium `ingress`
  entity or the matching entity for your gateway setup) and confirm with a real
  request; the observed baseline may omit it.
- **Always-needed egress**: DNS to kube-dns, and the kube-apiserver
  (`toEntities: [kube-apiserver]`) for anything using the Kubernetes API.
- **Monitoring**: allow Prometheus scrapes (namespace `observability`,
  `app.kubernetes.io/name: prometheus`) to metrics ports, as the Longhorn
  policy does.
- **Named ports.** Output may reference named ports (`http`, `pgbouncer`).
  Prefer numeric ports in committed policies unless you have confirmed
  Cilium resolves the name for that direction.
- **Datastores.** CNPG poolers/clusters (`database` namespace) and Dragonfly
  instances need explicit rules both ways; match their labels from the
  manifests in the repo rather than from observed pod labels.

## Conventions

- Add a short comment above each policy saying what it protects and that the
  baseline came from kguardian.
- Keep one policy file per app in `app/networkpolicy.yaml` and register it in
  the app's `kustomization.yaml`; no cluster-wide default-deny until most apps
  in the namespace have policies.
- Commit style: ALWAYS `chore(<app>): …`, for every change this skill makes
  (new policies, audit resources, promotions, tweaks, removals). `fix` and
  `feat` are reserved for Renovate; never use them.
- Seccomp: only a `full`-capture profile is safe to enforce; start in audit
  mode, and apply the `SeccompProfile` CR before referencing it from a pod via
  `seccompProfile.type: Localhost`.
- PSS recommendations from `profile export --format pss` are patches to review,
  not to apply blindly; check them against the app's HelmRelease values.

## Rollback

Policies are plain manifests, so revert the commit and reconcile
(`flux reconcile kustomization <app> --with-source`). To unblock an app fast,
delete the offending `CiliumNetworkPolicy`/`NetworkPolicy` with `kubectl`
and then fix it in git, since Flux will otherwise recreate it.
