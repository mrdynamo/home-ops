---
title: Kubernetes OIDC Authentication via Authentik
description: Step-by-step plan to add OIDC authentication for human operators while preserving the Talos-issued bootstrap client-cert rescue path.
---

# Kubernetes OIDC Authentication via Authentik

> **Status:** Plan only. Not yet implemented. Final design decisions (LAN-only exposure, on-demand kubeconfig, single admin tier) confirmed with the cluster owner.

## Context

The cluster currently relies on a single, long-lived bootstrap admin kubeconfig whose only credential is a Talos-issued client certificate (`kubeconfig` at the repo root, gitignored, user `admin@kubernetes`, context `admin@kubernetes`, cluster `kubernetes`, server `https://192.168.30.10:6443`). That works as a rescue path because it requires nothing but a LAN connection to the kube-apiserver — no in-cluster service needs to be reachable. The intent here is to add a **second**, parallel auth path for human operators: an OIDC kubeconfig that talks to Authentik, so we can issue short-lived, group-bound, revocable credentials to people — without losing the existing bootstrap cert path.

The Headlamp HelmRelease at `kubernetes/apps/observability/headlamp/app/helmrelease.yaml` explicitly anticipates this work ("Will configure k8s OIDC in the future"), and the matching 1Password item `headlamp` already has `HEADLAMP_OIDC_CLIENT_ID/SECRET/ISSUER_URL` waiting in `kubernetes/apps/observability/headlamp/app/externalsecret.yaml`. Authentik itself is already deployed at `auth.${SECRET_DOMAIN}` (`kubernetes/apps/security/authentik/app/helmrelease.yaml`).

User-confirmed scope decisions:

- **LAN-only API exposure.** No Cloudflare Tunnel route for kube-apiserver, no SAN additions to `talconfig.yaml`. OIDC only works on the homelab network. The bootstrap cert path remains a complete rescue.
- **On-demand kubeconfig via justfile.** No checked-in `kubeconfig.oidc.sops.yaml`. A `just kubeconfig-oidc` recipe generates the file locally.
- **Single admin tier only** for the first cut: `kubernetes-admins` group → `cluster-admin`. Developer/viewer tiers deferred.

---

## Phased Implementation

### Phase 0 — Pre-flight (no cluster changes)

1. **Decide and document the OIDC client identity.** Add a new 1Password item named `kubernetes` (so Headlamp's `headlamp` item stays separate). It will hold: `KUBERNETES_OIDC_CLIENT_ID`, `KUBERNETES_OIDC_CLIENT_SECRET`, `KUBERNETES_OIDC_ISSUER_URL` (default to `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/` — must be the **public** domain because Authentik is not exposed on the internal gateway; both the kube-apiserver and the operator's laptop reach it over the public route). The bootstrap cert path is unaffected.
2. **Verify `kubectl-oidc-login` (or `kubelogin`) is available** via mise: update `.mise.toml` to include `aqua:int128/kubelogin` at a pinned version (run `mise install`). This binary is the `exec` plugin the OIDC kubeconfig will call.
3. **Decide the OIDC group name.** Use the literal string `kubernetes-admins`. It will appear both in the Authentik group definition and in the Kubernetes `ClusterRoleBinding`.

### Phase 1 — Authentik side: create the OIDC provider

Goal: have a working OIDC client for the kube-apiserver to validate against. The bootstrap cert is still the only way to authenticate during this phase.

1. In the Authentik UI, **create a new OAuth2/OpenID Provider**:
   - Name: `Kubernetes`
   - Signing Key: use the default authentik self-signed cert (LAN-only — no need for a publicly-trusted cert)
   - Redirect URIs: `http://localhost:8000` (the kubelogin loopback callback)
   - Scopes: `openid`, `email`, `profile`, `groups`
   - Subject mode: `Based on the User's username`
2. **Create a matching Application** in Authentik:
   - Name: `Kubernetes`
   - Provider: the one above
   - Slug: `kubernetes`
3. **Create an Authentik group** named `kubernetes-admins` and add your operator user to it. Confirm the ID-token returned at `/application/o/userinfo/` (note: `userinfo`, not `user/info`) includes `"groups": ["kubernetes-admins"]`. The reserved global slugs in Authentik are `authorize`, `token`, `device`, `userinfo`, `introspect`, `revoke` — there is no `user/info` endpoint.
4. **Store the client ID and secret** in the new 1Password item `kubernetes` (fields `KUBERNETES_OIDC_CLIENT_ID`, `KUBERNETES_OIDC_CLIENT_SECRET`).

After Phase 1, the OIDC issuer is live and reachable at `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/`. **You can still `kubectl` only with the bootstrap cert** — the API server isn't configured for OIDC yet.

> **Authentik issuer-mode assumption.** The path `/application/o/<slug>/` is the default Authentik issuer URL only when the provider's "Unique issuer" mode is enabled (the default for new providers). If anyone has previously disabled Unique Issuer mode on this Authentik instance, the issuer URL becomes just `https://auth.${SECRET_DOMAIN}/` and the `--oidc-issuer-url` flag below needs to drop the `/application/o/kubernetes/` suffix. Verify by visiting `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/.well-known/openid-configuration` — it should return JSON, not a 404.

### Phase 2 — Talos: wire `--oidc-*` flags into the API server

Goal: enable the API server to validate OIDC tokens. Until the next step, the new flags have no effect on existing users (the bootstrap cert is unaffected by `--oidc-*` flags — those only gate tokens presented as `Bearer` headers).

1. **Extend `talos/patches/controller/cluster.yaml`** in the existing `cluster.apiServer.extraArgs` block. Add:

   ```yaml
   cluster:
     apiServer:
       extraArgs:
         # ...existing flags...
         oidc-issuer-url: https://auth.<secret-domain>/application/o/kubernetes/
         oidc-client-id: <kubernetes>          # public identifier, not secret
         oidc-username-claim: preferred_username
         oidc-username-prefix: "oidc:"
         oidc-groups-claim: groups
         oidc-groups-prefix: "oidc:"
         oidc-required-claim: "groups=kubernetes-admins"   # hard guardrail
         oidc-signing-algs: RS256
   ```

   The issuer URL **must use the public `${SECRET_DOMAIN}`** — Authentik is not exposed on the internal gateway in this cluster, so the kube-apiserver (on the LAN) reaches it over the public route to fetch JWKS for token validation. There is no internal-only shortcut here.

   **Talos patches are NOT templated.** `talos/patches/**/*.yaml` files are read by `talhelper genconfig` as static strategic-merge patches and applied verbatim into the kube-apiserver manifest. They are not run through `minijinja-cli` and not picked up by the `cluster-secrets` substitute pipeline (that pipeline is Flux kustomize-only). A literal `${SECRET_DOMAIN}` written here would land in the apiserver manifest as the four characters `$`, `{`, `S`, etc., and the apiserver would fail to start. Hard-code the literal `<secret-domain>` value (the same one `${SECRET_DOMAIN}` resolves to in the cluster-secrets Secret — check the SOPS file) and `<kubernetes>` OIDC client ID. Follow-up work could introduce a separate substitution pass over Talos patches, but it is out of scope here.

   The literal string `kubernetes-admins` appears in **three** places and must be identical in all of them:
   - The Authentik group name (Phase 1 step 3)
   - This `oidc-required-claim` value
   - The ClusterRoleBinding subject (Phase 3 — `oidc:kubernetes-admins` after the prefix)

   `oidc-required-claim` accepts the `key=value` string form, which serialises correctly as a single list item under `extraArgs` — do not break it across multiple lines or comma-separate, the kubelet/kube-apiserver flag parser is strict about the format.

   Subject-mode interaction: with Authentik "Subject mode: Based on the User's username" and `oidc-username-claim: preferred_username`, the OIDC username is `<auth-user-username>`. The binding in Phase 3 uses `Group`, not `User`, so this is fine — but if anyone later adds a `User`-subject binding, kube-apiserver will see users as `oidc:<username>` because of `oidc-username-prefix: "oidc:"`.

   `oidc-signing-algs: RS256` matches Authentik's default signing algorithm. Revisit this if Authentik's signing key is ever rotated to EdDSA/PS256 — the apiserver will reject tokens it cannot verify.

2. The two `additionalApiServerCertSans` entries in `talconfig.yaml` remain unchanged. **No change.** LAN-only access means no new SANs.

3. Apply the new config to each control plane. **Do NOT bootstrap Kubernetes.** `talhelper gencommand apply --extra-flags="--insecure"` (Taskfile `apply-node` task) is the **bootstrap-only** path; once the cluster is up, drop `--insecure` and use the regular talosctl auth:

   ```sh
   # Per control plane node, one at a time:
   talosctl -n <control-plane-node-ip> apply-config -f <(talhelper genconfig --with-secrets ./talos/talsecret.sops.yaml -o -)
   ```

   This rolls kube-apiserver on each control plane to pick up the new flags. Etcd is untouched and the admin client cert stays valid. Apply one node first, wait for it to become Ready and the apiserver to be healthy, then apply the remaining two. Staggering the roll avoids a simultaneous API-server-down event across all three control planes. The `just talos` recipe in `bootstrap/mod.just` is **not** the right command here — it passes `--insecure` and is intended for the bootstrap-only flow.

   **Never run `talosctl bootstrap`** on a node that's already part of a healthy cluster — that re-initializes etcd and destroys the cluster.

4. **Verify after each roll** (per node). The static-pod manifest on disk is not the same as a healthy running apiserver — if any flag value is malformed (e.g. a literal `${SECRET_DOMAIN}` that wasn't substituted, or an unescaped `<secret-domain>` placeholder left from a partially-edited patch), the manifest still exists on disk but kube-apiserver is crashlooping. Run **all three**:

   ```sh
   # 1. Flags landed in the static-pod manifest:
   talosctl -n <control-plane-node-ip> read /etc/kubernetes/manifests/kube-apiserver.yaml \
     | grep -E 'oidc-(issuer|client|username|groups|required|signing)'
   # Expect all six flags.

   # 2. kube-apiserver service is Running, not crashlooping:
   talosctl -n <control-plane-node-ip> service kube-apiserver

   # 3. Recent apiserver logs show clean startup, not flag-parse errors:
   talosctl -n <control-plane-node-ip> logs kube-apiserver | tail -50
   ```

### Phase 3 — Kubernetes RBAC: bind the OIDC group

Goal: an OIDC-authenticated user with the `kubernetes-admins` Authentik group becomes `cluster-admin`. Until the kubeconfig is set up in Phase 4, this binding exists but no one can use it.

1. **Create the file** `kubernetes/apps/security/auth/clusterrolebinding.yaml`. Follow the existing precedent at `kubernetes/apps/flux-system/flux-operator/app/clusterrolebinding.yaml`:

   ```yaml
   ---
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRoleBinding
   metadata:
     name: kubernetes-admins
   subjects:
     - kind: Group
       name: oidc:kubernetes-admins
       apiGroup: rbac.authorization.k8s.io
   roleRef:
     kind: ClusterRole
     name: cluster-admin
     apiGroup: rbac.authorization.k8s.io
   ```

   The `oidc:` prefix matches the `oidc-groups-prefix` from Phase 2. This is the **only new RBAC resource** needed for the single-tier admin model.

2. **Create the file** `kubernetes/apps/security/auth/kustomization.yaml`:

   ```yaml
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - ./clusterrolebinding.yaml
   ```

3. **Create the file** `kubernetes/apps/security/auth/ks.yaml`. Reuse the `cluster-secrets` substitute pattern from `kubernetes/apps/security/authentik/ks.yaml` so `${SECRET_DOMAIN}` resolves in any templated field:

   ```yaml
   ---
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: auth
     namespace: security
   spec:
     interval: 1h
     path: ./kubernetes/apps/security/auth
     postBuild:
       substituteFrom:
         - name: cluster-secrets
           kind: Secret
     prune: true
     retryInterval: 2m
     sourceRef:
       kind: GitRepository
       name: flux-system
       namespace: flux-system
     targetNamespace: security
     timeout: 5m
     wait: false
   ```

4. **Register the new kustomization** by editing `kubernetes/apps/security/kustomization.yaml`. Add `- ./auth/ks.yaml` to `resources:` (alphabetical, between `./authentik/ks.yaml` and any future entries).

### Phase 4 — kubeconfig: generate on demand via justfile

Goal: a single recipe produces an OIDC-enabled kubeconfig that any operator can run from a homelab LAN-attached machine. Nothing is checked into git.

1. **Add the recipe** to `bootstrap/mod.just` (the existing recipe file already has `kubeconfig`, this new one slots in next to it):

   ```just
   [doc('Generate OIDC-enabled kubeconfig (LAN only)')]
   kubeconfig-oidc:
       just log info "Running stage..." "stage" "$0"
       issuer="https://auth.${SECRET_DOMAIN}/application/o/kubernetes/"
       client_id="$(op read 'op://kubernetes/kubernetes/KUBERNETES_OIDC_CLIENT_ID')"
       client_secret="$(op read 'op://kubernetes/kubernetes/KUBERNETES_OIDC_CLIENT_SECRET')"
       kubeconfig_path="${HOME}/.kube/oidc-kubeconfig.yaml"
       mkdir -p "${HOME}/.kube"
       # Seed an empty kubeconfig with cluster + context. `kubectl config set-cluster`
       # creates a kubeconfig with the named cluster plus a default context pointing at it.
       if ! kubectl config set-cluster kubernetes \
               --kubeconfig="${kubeconfig_path}" \
               --server="https://<api-server-vip>:6443" \
               --embed-certs=true; then \
           just log fatal "Failed to seed cluster in kubeconfig" "stage" "$0"; \
       fi
       if ! kubectl config set-context oidc \
               --kubeconfig="${kubeconfig_path}" \
               --cluster=kubernetes \
               --user=oidc; then \
           just log fatal "Failed to set oidc context" "stage" "$0"; \
       fi
       # Register the OIDC user as an exec plugin that delegates to `kubectl oidc-login get-token`.
       # NOTE: `kubectl oidc-login setup` only PRINTS token claims for debugging — it does NOT
       # write a kubeconfig. The actual kubeconfig has to be built by hand via `set-credentials`.
       if ! kubectl config set-credentials oidc \
               --kubeconfig="${kubeconfig_path}" \
               --exec-api-version=client.authentication.k8s.io/v1 \
               --exec-interactive-mode=Never \
               --exec-command=kubectl \
               --exec-arg=oidc-login \
               --exec-arg=get-token \
               --exec-arg="--oidc-issuer-url=${issuer}" \
               --exec-arg="--oidc-client-id=${client_id}" \
               --exec-arg="--oidc-client-secret=${client_secret}" \
               --exec-arg=--oidc-extra-scope=openid \
               --exec-arg=--oidc-extra-scope=profile \
               --exec-arg=--oidc-extra-scope=email \
               --exec-arg=--oidc-extra-scope=groups \
               --exec-arg=--grant-type=auto \
               --exec-arg=--listen-address=127.0.0.1:8000 \
               --exec-arg=--token-cache-storage=keyring; then \
           just log fatal "Failed to set oidc user exec plugin" "stage" "$0"; \
       fi
       if ! kubectl config use-context oidc --kubeconfig="${kubeconfig_path}"; then \
           just log fatal "Failed to set current-context to oidc" "stage" "$0"; \
       fi
       just log info "OIDC kubeconfig written to ${kubeconfig_path}" "stage" "$0"
   ```

   Flag notes (cross-checked against [kubelogin usage.md](https://github.com/int128/kubelogin/blob/master/docs/usage.md)):
   - `--oidc-extra-scope` (with the `oidc-` prefix) — not `--extra-scope`. The unscoped form is silently ignored. Repeat the flag once per scope, do not comma-join values.
   - `--listen-address=127.0.0.1:8000` is the default; kubelogin falls back to `127.0.0.1:18000` if 8000 is in use. The Authentik Redirect URI registered in Phase 1 must match whichever port kubelogin actually binds — re-check after first run, and update the Authentik redirect URI list if it picks 18000.
   - There is **no** `--callback-hostname` flag — the loopback callback host is derived from `--listen-address`.
   - `--token-cache-storage=keyring` keeps the refresh token in the OS keyring (macOS Keychain / Linux Secret Service / Windows Credential Manager) instead of plaintext on disk. Drop this if you're on a headless machine with no keyring — kubelogin will then fall back to a file cache under `${HOME}/.kube/cache/oidc-login`.
   - `--grant-type=auto` lets kubelogin pick `authcode` if a browser is reachable, `device-code` otherwise. Useful when SSH'd into a headless box.

   The recipe assumes `op` (1Password CLI) is on `$PATH` and the user is signed in to the `kubernetes-connect` 1Password account. The bootstrap kubeconfig at `${REPO}/kubeconfig` is **not** touched.

2. **Bootstrap cert is the rescue.** The repo-root `kubeconfig` (Talos client-cert) is intentionally NOT modified. If anything in Phases 2–4 goes wrong, `KUBECONFIG=./kubeconfig kubectl ...` continues to work because the client cert is unaffected by `--oidc-*` flags.

### Phase 5 — Verification

End-to-end check, in order. **Each step must pass before moving to the next.**

1. **Bootstrap path still works** (rescue posture):

   ```sh
   KUBECONFIG=./kubeconfig kubectl get nodes
   ```

   Must return all 6 nodes Ready. This is the contract — OIDC work never breaks this.

2. **OIDC flags live in the API server**:

   ```sh
   talosctl -n <control-plane-node-ip> read /etc/kubernetes/manifests/kube-apiserver.yaml \
     | grep -E 'oidc-(issuer|client|username|groups|required)'
   ```

   Expect all six flags.

3. **OIDC kubeconfig generation succeeds**:

   ```sh
   just kubeconfig-oidc
   ```

   Should print the path and exit 0.

4. **OIDC login works** (browser opens, Authentik challenges, returns token):

   ```sh
   KUBECONFIG=~/.kube/oidc-kubeconfig.yaml kubectl get nodes
   ```

   First invocation opens a browser to `auth.${SECRET_DOMAIN}/...`, you log in, kubelogin captures the redirect, kubectl returns the 6 nodes.

5. **Group binding is honoured** (try with a non-admin Authentik user):

   ```sh
   KUBECONFIG=~/.kube/oidc-kubeconfig.yaml kubectl auth whoami
   ```

   With an admin user → output includes `Groups: [oidc:kubernetes-admins, system:authenticated]`. With a non-admin user → `oidc:kubernetes-admins` is absent, so subsequent `kubectl get secrets -A` returns 403. (A non-admin test user is optional but proves the `oidc-required-claim` guardrail in Phase 2 is wired correctly.) `kubectl auth whoami` requires the `whoami` subcommand, which is **not in stock kubectl** — install it via the [kubectl-whoami krew plugin](https://github.com/rajatjindal/kubectl-whoami) (e.g. add `"krew:whoami" = "<version>"` to `.mise.toml` under `[tools]`). Without the plugin, this command returns `error: unknown command "whoami"`.

6. **SelfSubjectReview is available** (helps future tooling confirm identity; the cluster-managed API endpoint serves it on demand once `auth.k8s.io/v1` SelfSubjectReview is enabled, which it is by default on Kubernetes 1.30+). No additional cluster configuration is required. Verify via:

   ```sh
   KUBECONFIG=~/.kube/oidc-kubeconfig.yaml kubectl create -f - --raw=/apis/authentication.k8s.io/v1/selfsubjectreviews - <<<'{"apiVersion":"authentication.k8s.io/v1","kind":"SelfSubjectReview","metadata":{"creationTimestamp":null}}'
   ```

   The response should show `"username": "oidc:<your-username>"` and `"groups": ["oidc:kubernetes-admins", "system:authenticated", "system:authenticated"]`. This is the same data the `kubectl-whoami` plugin shows; it does not require any plugin install.

### Rollback

Each phase is independently reversible:

- **Phase 4** (justfile recipe): delete the recipe. Nothing checked in.
- **Phase 3** (RBAC): `kubectl delete clusterrolebinding kubernetes-admins` or remove the file from Flux.
- **Phase 2** (Talos apiserver flags): remove the six `oidc-*` entries from `talos/patches/controller/cluster.yaml` and re-render/apply. The API server restarts without OIDC support. The bootstrap cert path is unaffected throughout.
- **Phase 1** (Authentik provider/application/group): UI deletion only. No cluster state to undo.
- **Phase 0**: no-op.

If the apiserver fails to come back up after Phase 2, **the rescue is `talosctl -n <control-plane-node-ip> rollback`** followed by `talosctl -n <control-plane-node-ip> reboot` — that reverts the Talos host to its previous config and brings the apiserver up with the old flags. `rollback` is **per-node**, not cluster-wide — it only reboots the named node into the previous machineconfig. Do **not** assume a single-node rollback fixes the cluster.

Recovery sequence:

1. Pick the control-plane node where you first applied the bad config (the one not currently serving kube-apiserver, if any).
2. `talosctl -n <node> rollback` then `talosctl -n <node> reboot` — this node comes back with the previous machineconfig.
3. Confirm the reverted node's kube-apiserver is healthy (`talosctl -n <node> service kube-apiserver`) and that the cluster has a working apiserver. Etcd membership is preserved across `rollback`.
4. Repeat steps 2–3 on each remaining control-plane node that had the bad config applied, one at a time.
5. Once all control planes are back on the prior config, re-edit the patch (fixing whatever caused the original failure — typically a typo in the hard-coded issuer URL or a misconfigured flag value), regenerate the config with `talhelper genconfig`, and re-apply via the per-node `talosctl apply-config` flow used in Phase 2.

The bootstrap kubeconfig (`KUBECONFIG=./kubeconfig kubectl ...`) works against the reverted apiserver because the admin client cert is unaffected by `--oidc-*` flags.

---

## Critical Files

### Modified

- `talos/patches/controller/cluster.yaml` — add six `--oidc-*` extraArgs under existing `cluster.apiServer.extraArgs` block. **No new file; extend.**
- `bootstrap/mod.just` — add `kubeconfig-oidc` recipe alongside the existing `kubeconfig` recipe.
- `.mise.toml` — pin `aqua:int128/kubelogin`.
- `kubernetes/apps/security/kustomization.yaml` — register the new `./auth/ks.yaml` under `resources:`.

### Created (under `kubernetes/apps/security/auth/`)

- `clusterrolebinding.yaml` — `oidc:kubernetes-admins` → `cluster-admin` (single admin tier only)
- `kustomization.yaml` — bundles the clusterrolebinding
- `ks.yaml` — Flux Kustomization with `cluster-secrets` substitute pattern (mirror of `authentik/ks.yaml`)

### Reused existing patterns (do not duplicate)

- Group-subject ClusterRoleBinding precedent: `kubernetes/apps/flux-system/flux-operator/app/clusterrolebinding.yaml`
- `cluster-secrets` substitute pattern: `kubernetes/apps/security/authentik/ks.yaml`
- Authentik HelmRelease envFrom ExternalSecret pattern: `kubernetes/apps/security/authentik/app/externalsecret.yaml`
- Existing Talos apiserver extraArgs patch slot: `talos/patches/controller/cluster.yaml`
- 1Password as the canonical secret store: every `*App`/`Catalog` value already routed through `ClusterSecretStore: onepassword`.

### Untouched (rescue posture)

- `kubeconfig` at the repo root — the bootstrap client-cert kubeconfig. Stays exactly as-is.
- `talos/clusterconfig/talosconfig` — talosctl config unchanged.
- `talconfig.yaml` `additionalApiServerCertSans` — no new SANs needed (LAN-only).

### Not created (deferred to follow-ups, per scope decisions)

- No `kubeconfig.oidc.sops.yaml` checked in.
- No `cloudflared` route for the kube-apiserver.
- No TLSRoute / TCPRoute / cloudflared-in-cluster.
- No developer / viewer RBAC tiers.
- No `SelfSubjectReview` resource (the cluster-managed API endpoint serves it on demand once `auth.k8s.io/v1` SelfSubjectReview is enabled, which is GA in 1.30+).
- No changes to Headlamp's still-commented-out OIDC block — that's a follow-up after Phase 5 verification lands.

---

## Conventions to Honour

- **Internal domain templating:** every domain literal in this plan uses `${SECRET_DOMAIN}`. Per repo convention, no literal internal-domain strings may appear in YAML or docs.
- **Issuer URL must use `${SECRET_DOMAIN}`** (not `${INTERNAL_SECRET_DOMAIN}`). Authentik is not exposed on the internal gateway in this cluster, so both kube-apiserver (validating tokens via JWKS) and the operator's laptop (running kubelogin) reach `auth.${SECRET_DOMAIN}` over the public route. Substituting an internal-only domain would cause OIDC validation to fail with DNS resolution errors.
- **Talos patches are not templated** — see the explicit warning in Phase 2 step 1. Hard-coded literals in `talos/patches/**/*.yaml` are not a violation of the templating convention; they are the only way these patches can work.
- **SOPS-encrypt any checked-in secret-bearing file.** The recipe in Phase 4 reads 1Password at runtime and writes the kubeconfig to `${HOME}` — nothing is committed, so no encryption needed for it.
- **No `--oidc-*` flag is ever destructive.** None of the six flags touch the existing `admin` client cert — they only gate token-presented requests.

---

## Placeholders Used in This Document

Some specifics have been abstracted with `<placeholder>` markers. Fill them in from your local repo when implementing:

| Placeholder | What it is | Where to find it |
| --- | --- | --- |
| `<control-plane-node-ip>` | IP of any control-plane node (k8s-01/02/03) | `talos/clusterconfig/talosconfig` `nodes:` list |
| `<api-server-vip>` | HA VIP that fronts the kube-apiserver | `talos/talconfig.yaml` `endpoint:` and each `vip.ip` |
| `<secret-domain>` | The literal `${SECRET_DOMAIN}` value (public DNS suffix) — hard-coded because Talos patches aren't templated | `kubernetes/components/common/sops/cluster-secrets.sops.yaml` |
| `<kubernetes>` | OIDC client ID (not secret — just the public identifier) | assigned by Authentik when the provider is created |
