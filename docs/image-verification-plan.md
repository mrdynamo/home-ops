# Supply-Chain Hardening: Image & Chart Verification Plan

Status: research + proposal (revision 3). Nothing has been applied to the cluster.
Date: 2026-11-04

Revision 3 changes: replaced assumptions with a measured inventory of every
chart and image (repo and running cluster), corrected several earlier claims,
and added Talos `ImageVerificationConfig` as a native enforcement option.

## 1. Goals

Reduce the chance that a compromised upstream (hijacked tag, poisoned registry
push, malicious chart release, poisoned CI workflow) reaches a running pod.

1. **Provenance**: prove an artifact was built by the expected publisher's CI.
2. **Immutability**: nothing runs from a mutable tag.
3. **Enforcement point**: choose where checks happen (PR/CI, Flux sync, node
   pull, admission).
4. **Don't break a homelab**: staged rollout, audit before enforce, fast
   rollback.

## 2. Where the cluster is today (measured)

Versions: Kubernetes v1.37.2, Talos 1.14.5, Flux distribution 2.10.0
(source-controller v1.10.1), cosign v3.1.4 used for testing.

| Area | Current state |
|---|---|
| Charts | 102 `OCIRepository` objects, **45 unique chart refs** (57 objects are bjw-s `app-template`). None use `spec.verify`. |
| Images in manifests | 78 unique refs set in repo values. **5 are not digest-pinned** (see §2.2). |
| Images actually running | **153 unique images; 73 are not digest-pinned.** Most come from chart defaults (Longhorn, cert-manager, Prometheus, Cilium, etc.) that the repo never sets, so Renovate's digest pinning does not reach them. |
| Signed artifacts | **Charts: 25 of 45 signed. Images: roughly 55 of ~160 signed (~35%).** Details in §2.1 and Appendix A. |
| Flux sync source | `GitRepository` `https://github.com/mrdynamo/home-ops.git`, no `spec.verify`. **All recent commits are signed and GitHub-verified**: yours are SSH-signed (`commit.gpgsign=true`, `gpg.format=ssh`); Renovate bot (`robot-rosey[bot]`) commits have GitHub as committer and are signed by GitHub's web-flow key. |
| Admission control | No policy engine. |
| Node-level verification | Talos `ImageVerificationConfig` not configured (available since Talos 1.13). |
| Existing security tooling | `trivy-operator` (vuln/config scanning), `kguardian` (network/seccomp advisor). |
| Renovate | `helpers:pinGitHubActionDigests` is on. `minimumReleaseAge` is only set on the GitHub Actions automerge rule (`3 days`; the trusted `actions/*`/`renovatebot/*` rule uses `1 minute`). **Images and charts have no cooldown.** `statusCheckNames.minimumReleaseAge: null` only disables the status check. |
| CI | Label, release, schema, Renovate/PR-review workflows on self-hosted runners (`home-ops-runner`, `arc-home-ops-runner`). No image existence check, no Flux render job, no workflow linting. |

### 2.1 Inventory method and key findings

For every chart and image (repo values plus all images on running pods), I ran
read-only checks: `crane digest` (exists?), `cosign verify` with a wildcard
identity (signed? by whom?), and `gh attestation verify` (GitHub
attestation?). The scripts are throwaway and live outside the repo; Phase 3
turns them into a CI job.

Findings that change the plan:

- **home-operations/containers images have no classic signature, only a SLSA
  provenance attestation** stored as an OCI referrer (`cosign tree` shows only
  `https://slsa.dev/provenance/v1`). cosign v3 `verify` and
  `verify-attestation --type slsaprovenance1` both pass with the
  `app-builder.yaml@refs/heads/main` identity. Any enforcement tool must
  handle **attestation-only, new-bundle-format** images.
- **Not everything under `ghcr.io/home-operations/` is signed.** Unsigned:
  `external-dns-unifi-webhook`, `gatus-sidecar`, `konflate`, `kromgo`, `tuppr`
  (built in their own repos). Their *charts* are signed. A blanket
  `ghcr.io/home-operations/*` rule would block these.
- **Signer identities vary per publisher.** Some sign from `refs/heads/main`
  (bjw-s, cnpg charts, home-operations), others from release tags
  (flux-operator `refs/tags/v0.17.1`, cilium `refs/tags/v1.20.4`, spegel),
  and some via shared/reusable workflows (Flux controllers sign from
  `fluxcd/gha-workflows`, fluent-bit from `action-stars/helm-workflows` pinned
  by SHA). Kubernetes images are signed with Google identities
  (`krel-trust@` / `promoter-summaries@k8s-releng-prod.iam.gserviceaccount.com`).
  One publisher (giantswarm) signs via CircleCI.
- **Big unsigned publishers you depend on**: Longhorn (all images),
  cert-manager core images and charts, prometheus-community charts and
  Prometheus images, openebs, ARC charts and controller, Docker Hub images
  overall, and most single-maintainer `ghcr.io/<user>/<app>` images.
- **One probe artifact**: `deckhouse/prompp` uses a `registry: ghcr.io` split in
  values; it exists on ghcr.io (unsigned). The extractor had misread it as
  docker.io.

### 2.2 Unpinned images in the repo

| Image | File |
|---|---|
| `ghcr.io/mchestr/gotenberg:8.17.3` | `kubernetes/apps/default/paperless/app/helmrelease.yaml` |
| `docker.io/apache/tika:3.3.3.0-full` | same |
| `ghcr.io/deckhouse/prompp:0.8.18` | `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml` |
| `docker.io/alpine/k8s:1.36.2` | `kubernetes/apps/storage/longhorn-pdb-pruner/resources/deployment.yaml` |
| `docker.io/library/alpine:3.24.3` | `kubernetes/apps/ai/litellm/app/helmrelease.yaml` |

## 3. Research

### 3.1 What the home-operations community does

- **home-operations/containers** attests with
  [`attest-build-provenance`](https://github.com/actions/attest-build-provenance).
  README commands (confirmed working against your sonarr digest):

  ```sh
  gh attestation verify --repo home-operations/containers \
    oci://ghcr.io/home-operations/${APP}:${TAG}

  cosign verify-attestation --new-bundle-format --type slsaprovenance1 \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
    --certificate-identity-regexp "^https://github.com/home-operations/containers/.github/workflows/app-builder.yaml@refs/heads/main" \
    ghcr.io/home-operations/${APP}:${TAG}
  ```

- **Flux chart verification** in community repos, e.g. `ishioni/homelab-ops`
  on bjw-s `app-template`, and `phekno/home-ops` PR #880 on flux-operator.
- **Kyverno** is the usual admission engine (e.g. `webgrip/homelab-cluster`,
  Audit + `failurePolicy: Ignore`).
- **onedr0p/home-ops** has no signature verification (GitHub code search found
  none). Its CI does an image pull check on PRs (§3.5) and runs zizmor.
- kubesearch.dev has no documented search API; I could not query it. A manual
  search for `kyverno` there is still worthwhile to compare chart values.
- `ksgate` (already installed) is a scheduling-gate controller, not image
  verification.

### 3.2 Flux native verification: scope

| Feature | Covers | Notes |
|---|---|---|
| `OCIRepository.spec.verify` | Charts via `chartRef`, OCI artifacts | cosign (key or keyless `matchOIDCIdentity`) or Notation. Sets `SourceVerified`; on failure the source stops updating (fails safe). |
| `HelmChart.spec.verify` | Charts from OCI `HelmRepository` | Not used by you (you use `chartRef` + `OCIRepository`). |
| `GitRepository.spec.verify` | Git commits/tags | **PGP (`.asc`) and SSH (`.sshpub`) keys** in a Secret; modes `HEAD`, `Tag`, `TagAndHEAD`. Status `SourceVerified`. |
| Flux's own images | Flux controllers/CLI | Cosign-signed (confirmed: identity `fluxcd/gha-workflows/.../controller-release.yaml@refs/tags/v0.17.0`). Flux does not enforce this itself. |

Important details:

- **Cosign v3 bundles require an explicit identity.** With Flux 2.9+, a bare
  `verify: {provider: cosign}` fails on new-format signatures with
  "can't verify identities without providing at least one identity"
  (`phekno/home-ops` PR #880). Always set `matchOIDCIdentity`.
- **Flux cannot verify the container images your workloads run.** Flux applies
  manifests; the kubelet pulls images. That needs CI, the node (Talos) or an
  admission controller.
- **`GitRepository.spec.verify` is feasible for you.** Every recent commit on
  `main` is signed: yours with your SSH key, Renovate's (committer `GitHub`)
  with GitHub's web-flow GPG key. A Secret with your SSH public key
  (`.sshpub`) plus GitHub's web-flow public key (`.asc`, from
  `https://github.com/web-flow.gpg`) should cover `mode: HEAD`. Before
  enabling, confirm every path that writes to `main` signs (including
  `apply-krr` and any other workflow pushes), since an unsigned HEAD stops
  Flux from syncing until a signed commit lands. Note: verifying locally
  needs `gpg.ssh.allowedSignersFile`; without it `git log --format=%G?` shows
  SSH-signed commits as `N` (an earlier revision of this doc misread that as
  unsigned).

### 3.3 Talos `ImageVerificationConfig` (new; node-level, no webhook)

Talos 1.13+ has a machine-wide, cosign-based image verification policy that
applies to **every image pull on the node**: Talos system images, static pods,
and all Kubernetes workloads.

```yaml
apiVersion: v1alpha1
kind: ImageVerificationConfig
rules:
  - image: registry.k8s.io/*
    keyless:
      issuer: https://accounts.google.com
      subject: krel-trust@k8s-releng-prod.iam.gserviceaccount.com
  - image: ghcr.io/siderolabs/*
    keyless:
      issuer: https://accounts.google.com
      subjectRegex: '(@siderolabs\.com$|^releasemgr-svc@talos-production\.iam\.gserviceaccount\.com$)'
  - image: "*"
    deny: true
```

Fields: `rules[].image` (glob, matched without tag/digest), `keyless`
(`issuer`, `subject` or `subjectRegex`), `publicKey.certificate` (PEM),
`skip`, `deny`. First match wins. **Unmatched images are allowed.** Status is
visible via `talosctl image ls` (`talos.dev/verified` label).

Pros: no extra pods, no webhook to fail open or closed, covers images Kyverno
never sees (Talos/system images), fits a Talos-native setup.

Cons and unknowns:

- **No audit mode.** A rule either verifies (and blocks on failure), skips or
  denies. Mistakes break pulls, possibly of core components at node boot.
- **Pull-time only.** Images already in the node's store are not re-verified.
- **Keyless needs TUF/Sigstore reachability** from nodes.
- **No issuer regex shown**, and I found no documentation on attestation-only
  images. It reports "verified via bundle", so new-bundle signatures work, but
  whether it accepts **home-operations' attestation-only** bundles is
  **untested**. Test on one node before relying on it.
- Interaction with Spegel (peer-to-peer mirror) is undocumented. Verification
  should be keyed on the image reference, but confirm.
- Talos `subject` is exact-match unless you use `subjectRegex`; publishers
  that sign from release tags need a regex.

### 3.4 Kyverno (admission, verified status)

- Current: **v1.19.2** (latest), v1.20.0-rc.1 out. `ImageValidatingPolicy`
  (`policies.kyverno.io/v1`) is stable since 1.19.
- For GitHub attestations, use `attestations[].intoto.type:
  https://slsa.dev/provenance/v1` and `verifyAttestationSignatures(...)`
  (pattern from Nirmata's write-up), not `verifyImageSignatures`. **The
  template in revision 1 of this doc used the wrong function for
  home-operations images.**
- Relevant bugs:
  - [#16678](https://github.com/kyverno/kyverno/issues/16678) cosign v3
    attestations stored as OCI referrers evaluated to 0 (exactly
    home-operations' format). **Closed 2026-10-02**; likely in 1.19.2, but
    confirm in release notes before relying on it.
  - [#17363](https://github.com/kyverno/kyverno/issues/17363) key/KMS on
    bundle-only signatures. Closed 2026-09-29.
  - [#18349](https://github.com/kyverno/kyverno/issues/18349) open; only
    affects `allowInsecureRegistry` (plain HTTP registries). Not you.
- Pros over Talos: **Audit mode + PolicyReports** (see failures without
  breaking anything), attestation *content* checks, digest mutation, and one
  engine for broader policy later.
- Cons: webhook in the pod-creation path, more resource use, doesn't see
  Talos/system pulls.

### 3.5 CI image check (onedr0p pattern)

onedr0p's `ci.yaml`: `flate diff images -p ./kubernetes/apps -o json` lists
images changed by a PR, then a matrix job runs
`talosctl --nodes "$NODE" image pull "$IMAGE"` on an in-cluster runner. PR-only,
same-repo PRs only, `contents: read`, `max-parallel: 4`. It proves the image
exists and is pullable, not who built it (`flate` states it does not verify
signatures). Latest `flate` is v0.6.5.

Worth adding, extended with a verification step:

- Catches typos and bad/retracted digests before merge instead of
  `ImagePullBackOff` after.
- The changed-image list is exactly what pre-merge signature verification
  needs. This is the **audit layer** that Talos lacks: CI tells you a
  publisher's new release is unsigned before it reaches a node.
- Use `crane manifest` on a GitHub-hosted runner if you don't want Talos
  credentials in CI; `talosctl image pull` warms node caches but needs Talos
  API access on the runner.
- Docker Hub rate limits apply (you run ~30 docker.io images).
- `flate diff images` is not documented in its README; confirm with
  `flate diff --help`. Fallback: extract images from the PR's rendered diff.
- **Gap**: chart-default images (73 unpinned running images) only appear if
  the tool renders the HelmRelease. Prefer rendered output over grepping
  values.

### 3.6 zizmor (workflow security)

Static analyzer for GitHub Actions (latest v1.32.0): template injection,
dangerous triggers (`pull_request_target`/`workflow_run`), excessive
permissions, credential persistence, unpinned actions, cache poisoning,
known-vulnerable actions. High value here: your self-hosted runners run inside
the cluster, and the PR-review workflows feed PR/upstream text to an LLM.

## 4. Recommended approach

Layered, cheapest first:

| Layer | Tool | Covers | Status |
|---|---|---|---|
| Inventory | cosign/gh/crane script | What is signed | **Done (Appendix A)** |
| Update hygiene | Renovate `minimumReleaseAge`, pin 5 images | Fresh malicious releases | Quick win |
| Workflow security | zizmor | Poisoned CI | Quick win |
| Pre-merge | CI image-check + verify | Existence, signature on changed images | Medium |
| Chart sync | Flux `OCIRepository.spec.verify` | 25 signed charts | Medium |
| Runtime | **Kyverno (Audit → Deny)** or **Talos `ImageVerificationConfig`** | Signed publishers' images | Larger |
| Git source | Flux `GitRepository.spec.verify` | Repo tampering | Medium (commits already signed) |

**Runtime recommendation**: start with **Kyverno in Audit** for the signed
publishers. Its PolicyReports give visibility Talos can't, and it can check the
attestation-only home-operations images with a documented pattern. Add
**Talos rules** later for a small, high-value set that Kyverno doesn't see
(`ghcr.io/siderolabs/*`, `registry.k8s.io/*`), after a one-node test. If you
don't want Kyverno's footprint, Talos + CI verification is a viable lighter
alternative: CI provides the audit view, Talos provides enforcement.

Honest value assessment: only ~35% of images are signed, so runtime
enforcement protects the core stack (Flux, Cilium, Kubernetes, CNPG,
home-operations apps, kguardian, authentik) but not the long tail. For the long
tail, digest pinning, a Renovate cooldown, and review are the controls that
actually apply.

## 5. Phased plan

### Phase 0: Inventory (done)

Results in Appendix A. Keep the script for CI (Phase 3) and re-run
occasionally; publishers add or drop signing over time.

### Phase 1: Quick wins (no cluster risk)

1. **Renovate cooldown** in `.renovate/`:
   - `minimumReleaseAge: "3 days"` for `docker` and `helm` datasources (and
     github-releases), longer (e.g. 7 days) for majors.
   - Optionally a shorter age for signed core publishers you trust.
2. **Pin the 5 unpinned images** (§2.2) with `@sha256:` digests.
3. **Add zizmor** as its own workflow on changes to `.github/workflows/**`,
   triage first-run findings, then make it required.
   **Implemented (uncommitted, 2026-11-04):**
   - `.github/workflows/zizmor.yaml`: PR/push on workflow changes,
     GitHub-hosted runner, `permissions: contents: read`, zizmor-action
     v0.8.1 (SHA-pinned), zizmor `1.32.0` with a Renovate annotation,
     annotations mode (fails on findings).
   - Local runs (`zizmor .`): installed globally via the dotfiles mise config
     (`~/dev/dotfiles/home/dot_config/mise/private_config.toml`), not this
     repo's `.mise.toml`, so it's available in every repo. CI pins its own
     version through the action's `version:` input.
   - First run: 12 findings (6 high, 1 medium, 4 low, 1 informational),
     all fixed, now 0:
     - `github-app` (5): app tokens scoped with `permission-*` inputs in
       labeler, release, pr-reviewer, renovate-review, renovate-review-local.
     - `artipacked` (4): `persist-credentials: false` on checkout in the
       three review workflows and apply-krr.
     - `excessive-permissions` (1): `permissions: {}` in release (only the
       app token is used).
     - `cache-poisoning` (1): `package-manager-cache: false` on setup-node in
       schemas (publishing workflow).
     - `superfluous-actions` (1): `ncipollo/release-action` replaced with
       `gh release create --generate-notes`.
   - Also lowered `GITHUB_TOKEN` `contents: write` to `read` in the three
     review jobs (only checkout uses it; the reviewer uses the app token).
   - To verify after merge: the app tokens can't be granted permissions the
     GitHub App doesn't have (token step fails loudly if so); run `release`
     and `apply-krr` via `workflow_dispatch` once; watch the next Renovate
     PR's review jobs. Then make the Zizmor check required on `main`.

### Phase 2: Flux chart verification

Add `spec.verify` per signing publisher. Start with flux-operator /
flux-instance (highest impact), then bjw-s (57 objects; use a Kustomize
component or patch, not copy-paste).

```yaml
spec:
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/bjw-s-labs/helm-charts/\.github/workflows/chart-release-steps\.yaml@refs/heads/main$
```

Identity regexes from the inventory (anchor them; tag-signed publishers need a
semver pattern):

| Chart publisher | Subject pattern |
|---|---|
| bjw-s-labs | `^https://github\.com/bjw-s-labs/helm-charts/\.github/workflows/chart-release-steps\.yaml@refs/heads/main$` |
| controlplaneio-fluxcd | `^https://github\.com/controlplaneio-fluxcd/charts/\.github/workflows/release\.yml@refs/tags/v\d+\.\d+\.\d+$` |
| home-operations/charts-mirror | `^https://github\.com/home-operations/charts-mirror/\.github/workflows/app-builder\.yaml@refs/heads/main$` |
| home-operations/charts (konflate, kromgo, tuppr) | `^https://github\.com/home-operations/(konflate\|kromgo\|tuppr)/\.github/workflows/release\.yaml@refs/tags/.+$` |
| cloudnative-pg | `^https://github\.com/cloudnative-pg/charts/\.github/workflows/release-publish\.yml@refs/heads/main$` |
| cilium | `^https://github\.com/cilium/cilium/\.github/workflows/release\.yaml@refs/heads/main$` |
| external-secrets | `^https://github\.com/external-secrets/external-secrets/\.github/workflows/helm\.yml@refs/heads/main$` |
| coredns | `^https://github\.com/coredns/helm/\.github/workflows/release\.yaml@refs/heads/master$` |
| spegel | `^https://github\.com/spegel-org/spegel/\.github/workflows/release\.yaml@refs/tags/v.+$` |
| stakater (reloader) | `^https://github\.com/stakater/Reloader/\.github/workflows/push-helm-chart\.yaml@refs/heads/master$` |
| victoriametrics | `^https://github\.com/VictoriaMetrics/helm-charts/\.github/workflows/release\.yaml@refs/heads/master$` |
| kguardian | `^https://github\.com/kguardian-dev/kguardian/\.github/workflows/charts-release\.yaml@refs/tags/chart/v.+$` |
| mogenius | `^https://github\.com/mogenius/renovate-operator/\.github/workflows/release\.yaml@refs/tags/.+$` |
| fluent-bit | `^https://github\.com/action-stars/helm-workflows/\.github/workflows/release\.yaml@[0-9a-f]{40}$` (reusable workflow pinned by SHA; consider whether this identity is meaningful) |
| node-feature-discovery | issuer `https://accounts.google.com`, subject `^promoter-summaries@k8s-releng-prod\.iam\.gserviceaccount\.com$` (confirm issuer) |

(`\|` in the table is an escaped pipe; use `|` in YAML.)

**Implemented (uncommitted, 2026-11-04):** `spec.verify` added to **81 of
102** `OCIRepository` files (+405 lines, no deletions), one
`matchOIDCIdentity` per publisher, regexes anchored with `^…$`, single-quoted
so backslashes stay literal. Validation:

- All 24 unique chart:tag refs pass `cosign verify` using the issuer/subject
  regexes parsed back out of the YAML (cosign and Flux both use Go RE2).
- Negative tests fail as expected (wrong publisher identity; right repo but
  `refs/heads/main` instead of a release tag for flux-operator).
- All 81 files pass `kubectl apply --dry-run=server` against the cluster's
  OCIRepository CRD.
- Not yet tested: source-controller's own verifier on the live cluster
  (only cosign CLI so far).

Additions beyond the table above: giantswarm (`https://oidc.circleci.com`,
project-specific pipeline-definition subject) and node-feature-discovery
(`^(krel-trust|promoter-summaries)@k8s-releng-prod\.iam\.gserviceaccount\.com$`).
**fluent-bit deliberately excluded**: its signer is a shared third-party
reusable workflow (`action-stars/helm-workflows@<sha>`) that any repo can
call, so the identity doesn't prove the chart came from Fluent.

Unsigned charts (no `verify` possible): jetstack (cert-manager, csi-driver,
trust-manager), prometheus-community (4), openebs, ARC (2), authentik,
dragonfly-operator, reflector, grafana-operator, intel GPU driver, ksgate,
snapshot-controller, gateway-api-crds (wiremind), trivy-operator, k8s-gateway.

Watch: `kubectl get ocirepository -A -o
custom-columns=NS:.metadata.namespace,NAME:.metadata.name,VERIFIED:.status.conditions[?(@.type=="SourceVerified")].status`.
Rollback: remove the `verify` block. The flux-instance/flux-operator
dependency chain can deadlock if their source fails verification (PR #880), so
test the regex with `cosign verify` locally first.

### Phase 3: CI image check + verification

One workflow, PR-triggered, same-repo PRs only, `permissions: contents: read`:

1. Render changed resources and extract changed images (`flate`, confirming
   the subcommand, so chart-default images are included).
2. Existence: `crane manifest "$IMAGE"` (hosted runner) or
   `talosctl image pull` (in-cluster runner, cache warming).
3. Verify: map image prefix → expected identity (same table as Phase 2/4,
   kept in one file in the repo, e.g. `.github/image-identities.yaml`).
   - Publisher known to sign → **fail** if verification fails.
   - Publisher not known to sign → **comment/warn** if it *starts* signing
     (opportunity to add a rule), otherwise pass.
4. Single "status" gate job (onedr0p pattern).

### Phase 4: Runtime enforcement

**Kyverno path (recommended):**

1. Deploy Kyverno ≥1.19.2 via Flux (`kubernetes/apps/kyverno/` with the usual
   `ks.yaml` + `app/` layout). Exclude `kube-system`, `flux-system`, `kyverno`
   from the webhook; `failurePolicy: Ignore` initially.
2. One `ImageValidatingPolicy` per publisher, `validationActions: [Audit]`.
   Signature-signed publishers use `verifyImageSignatures`; attestation-only
   publishers (home-operations/containers) use `verifyAttestationSignatures`:

   ```yaml
   apiVersion: policies.kyverno.io/v1
   kind: ImageValidatingPolicy
   metadata:
     name: verify-home-operations-containers
   spec:
     validationActions: [Audit]
     failurePolicy: Ignore
     matchConstraints:
       resourceRules:
         - apiGroups: [""]
           apiVersions: ["v1"]
           operations: [CREATE, UPDATE]
           resources: [pods]
     # Only images built by home-operations/containers; NOT konflate, kromgo,
     # tuppr, gatus-sidecar, external-dns-unifi-webhook (unsigned).
     matchImageReferences:
       - glob: "ghcr.io/home-operations/actions-runner*"
       - glob: "ghcr.io/home-operations/bazarr*"
       - glob: "ghcr.io/home-operations/busybox*"
       - glob: "ghcr.io/home-operations/emby*"
       - glob: "ghcr.io/home-operations/kopia*"
       - glob: "ghcr.io/home-operations/plex*"
       - glob: "ghcr.io/home-operations/prowlarr*"
       - glob: "ghcr.io/home-operations/radarr*"
       - glob: "ghcr.io/home-operations/sabnzbd*"
       - glob: "ghcr.io/home-operations/sonarr*"
       - glob: "ghcr.io/home-operations/tautulli*"
     attestations:
       - name: slsa
         intoto:
           type: https://slsa.dev/provenance/v1
     attestors:
       - name: gha
         cosign:
           keyless:
             identities:
               - issuer: https://token.actions.githubusercontent.com
                 subject: https://github.com/home-operations/containers/.github/workflows/app-builder.yaml@refs/heads/main
           ctlog:
             url: https://rekor.sigstore.dev
     validations:
       - expression: >-
           images.containers.map(image,
             verifyAttestationSignatures(image, attestations.slsa, [attestors.gha])).all(e, e > 0)
         message: image lacks SLSA provenance from home-operations/containers CI
   ```

   Still a template: `images.containers` only covers regular containers (add
   init containers), and the glob list must be kept in sync with what you run
   (generate it from the Phase 3 identity file rather than hand-editing).
3. Review `kubectl get polr -A` for a week, fix regexes, then switch each
   policy to `Deny`. Consider `failurePolicy: Fail` only when stable (fail-open
   means crashing Kyverno bypasses the check).
4. Alert on PolicyReport failures in Grafana.

**Talos path (complement or lighter alternative):**

1. Write an `ImageVerificationConfig` patch under `talos/patches/` with rules
   only for signed publishers. **No catch-all `deny`**: unmatched images stay
   allowed, so the long tail keeps working.
2. Apply to **one worker** first. Test: a home-operations image
   (attestation-only), a tag-signed publisher (cilium), a Google-signed image
   (registry.k8s.io), and a pull through Spegel. Check `talosctl image ls`
   labels.
3. Roll out to remaining nodes, then control-plane nodes last. Keep the
   previous machine config ready to re-apply.

### Phase 5 (optional): Git source verification

Your commits and Renovate's are already signed, so this is mostly config:

1. Create a SOPS-encrypted (or plain; public keys aren't secret) Secret in
   `flux-system` with `mrdynamo.sshpub` (your signing key) and
   `github-web-flow.asc` (GitHub's web-flow key).
2. Set `verify: {mode: HEAD, secretRef: {name: git-verification-keys}}` on the
   `GitRepository`. With flux-operator, this is likely a patch on the
   `FluxInstance` sync config; check whether flux-operator exposes it
   directly.
3. Audit every workflow that pushes to `main` (`apply-krr`, release, etc.)
   and confirm its commits verify against those keys.
4. Rollback: remove the `verify` block. If a bad HEAD blocks sync, push a
   signed revert.

### Adjacent hardening

- Use kguardian output for NetworkPolicies to limit what a compromised image
  can reach.
- Pod Security Admission labels per namespace (`restricted`/`baseline`) limit
  a compromised image's blast radius. Native, no new components.
- Keep Trivy findings visible: signed images can still be vulnerable.

## 6. What this does and does not protect against

Protects against: registry/tag tampering, pushes with stolen registry
credentials (for signed publishers), unpinned images, compromised chart
publishing outside the expected workflow, poisoned workflows in this repo
(zizmor), and quick adoption of malicious new releases (cooldown).

Does **not** protect against: a compromised legitimate publisher workflow
that signs a malicious build, the ~65% of images that are unsigned (only
pinning and cooldown apply), or malicious dependencies inside a correctly
signed image.

## 7. Risks and operational costs

- **Availability**: Kyverno is in the pod-creation path; Talos rules are in
  the pull path with no audit mode. Start fail-open / narrow, exclude system
  namespaces, document rollback.
- **Sigstore dependency**: keyless verification needs Rekor/Fulcio/TUF. An
  outage delays Flux source updates or new pulls.
- **Identity drift**: publishers change workflows, branches or signing
  method. CI (Phase 3) is where you notice this first.
- **Tag-signed publishers**: regex must allow future tags without allowing
  arbitrary refs.

## 8. Decisions for you

1. Runtime: Kyverno (Audit → Deny), Talos `ImageVerificationConfig`, or both.
2. Fail-open vs fail-closed once policies are stable.
3. Renovate cooldown length (none today for images/charts).
4. CI existence check: `crane` on a hosted runner, or `talosctl image pull`
   in-cluster.
5. Whether to pursue Git commit verification (Phase 5).
6. Unsigned long tail: accept, replace, or rebuild/sign into your own
   `ghcr.io/mrdynamo/*` images.

## Appendix A: Inventory summary (2026-11-04)

**Signed images** (identity; `att` = GitHub attestation API also returns it):

| Publisher | Identity |
|---|---|
| home-operations/containers (11 apps), att | `home-operations/containers/.github/workflows/app-builder.yaml@refs/heads/main` (attestation-only) |
| fluxcd controllers | `fluxcd/gha-workflows/.github/workflows/controller-release.yaml@refs/tags/v0.17.0` |
| flux-operator | `controlplaneio-fluxcd/flux-operator/.github/workflows/release.yaml@refs/tags/v0.62.1` |
| cilium (agent, operator, hubble-relay) | `cilium/cilium/.github/workflows/build-images-releases.yaml@refs/tags/v1.20.4` |
| cilium-envoy | `cilium/proxy/.github/workflows/build-envoy-images-release-base.yaml@refs/heads/v1.39` |
| registry.k8s.io (apiserver, controller-manager, scheduler, descheduler, external-dns, kube-state-metrics, metrics-server, nfd, prometheus-adapter, snapshot-controller) | Google: `krel-trust@` or `promoter-summaries@k8s-releng-prod.iam.gserviceaccount.com` |
| cloudnative-pg operator, pgbouncer | `cloudnative-pg/cloudnative-pg/...release-publish.yml@refs/tags/v1.30.1`, `cloudnative-pg/pgbouncer-containers/...build.yml@refs/heads/main` |
| prometheus-operator, config-reloader | `prometheus-operator/prometheus-operator/.github/workflows/publish.yaml@refs/tags/v0.94.2` |
| external-secrets | `external-secrets/external-secrets/.github/workflows/release.yml@refs/heads/main` |
| authentik, att | `goauthentik/authentik/.github/workflows/release-publish.yml@refs/tags/version/2026.8.5` |
| kguardian (broker, controller, evaluator, frontend), att | `kguardian-dev/kguardian/.github/workflows/<component>-release.yaml@refs/tags/<component>/v…` |
| spegel | `spegel-org/spegel/.github/workflows/release.yaml@refs/tags/v0.8.1` |
| headlamp | `kubernetes-sigs/headlamp/.github/workflows/container-publish.yml@refs/tags/v0.46.0` |
| trust-manager, cert-manager-csi-driver | `cert-manager/trust-manager/...`, `cert-manager/csi-driver/...release.yaml@refs/tags/…` |
| intel device plugins | `intel/intel-device-plugins-for-kubernetes/.github/workflows/lib-publish.yaml@refs/tags/v0.37.1` |
| renovate | `renovatebot/renovate/.github/workflows/build.yml@refs/heads/main` |
| renovate-operator (mogenius) | `mogenius/github-actions/.github/workflows/build-multiarch.yml@<sha>` |
| seerr, meilisearch, shelfmark (att), calibre-web-nextgen (att) | Respective repo release workflows on tags |
| giantswarm silence-operator | CircleCI pipeline identity |

**Notable unsigned images**: Longhorn (all), cert-manager controller/webhook/cainjector,
Prometheus/Alertmanager/node-exporter/blackbox/smartctl, Grafana, CoreDNS
(via mirror.gcr.io), fluent-bit, dragonfly, reflector, reloader, openebs,
nvidia device plugin, ARC controller, CNPG barman plugin, postgres/mongo/mariadb,
victoria-logs, 1Password Connect, and most single-maintainer app images
(gatus, homepage, karakeep, paperless-ngx, open-webui, litellm, mealie, etc.).
Re-run the inventory before writing rules; it changes as publishers adopt
signing.

## Sources

- [home-operations/containers README](https://github.com/home-operations/containers)
- [home-operations/flate](https://github.com/home-operations/flate)
- [onedr0p/home-ops CI workflow](https://github.com/onedr0p/home-ops/blob/main/.github/workflows/ci.yaml)
- [Flux OCIRepository verify](https://fluxcd.io/flux/components/source/ocirepositories/)
- [Flux HelmChart verify](https://fluxcd.io/flux/components/source/helmcharts/)
- [Flux GitRepository verify](https://fluxcd.io/flux/components/source/gitrepositories/)
- [Flux security / SLSA](https://fluxcd.io/flux/security/)
- [phekno/home-ops PR #880 (Flux + cosign v3 identity requirement)](https://github.com/phekno/home-ops/pull/880)
- [Talos: verifying image signatures (v1.13)](https://docs.siderolabs.com/talos/v1.13/security/verifying-image-signatures)
- [Talos ImageVerificationConfig reference](https://docs.siderolabs.com/talos/v1.13/reference/configuration/security/imageverificationconfig)
- [Talos v1.13.0 release](https://github.com/siderolabs/talos/releases/tag/v1.13.0)
- [Kyverno ImageValidatingPolicy](https://kyverno.io/docs/policy-types/image-validating-policy/)
- [Kyverno Sigstore verification](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/sigstore/)
- [Nirmata: GitHub Artifact Attestations with Kyverno](https://nirmata.com/2026/03/16/supply-chain-security-with-github-artifact-attestations-and-kyverno/)
- Kyverno issues [#16678](https://github.com/kyverno/kyverno/issues/16678), [#17363](https://github.com/kyverno/kyverno/issues/17363), [#18349](https://github.com/kyverno/kyverno/issues/18349)
- [Sigstore policy-controller](https://docs.sigstore.dev/policy-controller/overview/)
- [ishioni/homelab-ops chart verify example](https://github.com/ishioni/homelab-ops/blob/main/kubernetes/apps/default/whoami/app/ocirepository.yaml)
- [webgrip/homelab-cluster Kyverno example](https://github.com/webgrip/homelab-cluster/blob/main/kubernetes/apps/kyverno/policies/app/image-verify-ploeg-hq-audit.yaml)
- [zizmor](https://github.com/zizmorcore/zizmor)
- [ksgate](https://github.com/ksgate/ksgate)
