---
title: Kubernetes OIDC Authentication via Authentik
description: Step-by-step plan to add OIDC authentication for human operators while preserving the Talos-issued bootstrap client-cert rescue path.
---

# Kubernetes OIDC Authentication via Authentik

> **Status:** Plan only. Not yet implemented. Final design decisions (LAN-only exposure, on-demand kubeconfig, single admin tier) confirmed with the cluster owner.

## Context

The cluster currently relies on a single, long-lived bootstrap admin kubeconfig whose only credential is a Talos-issued client certificate (`kubeconfig` at the repo root, user `admin@kubernetes`, context `main`). That works as a rescue path because it requires nothing but a LAN connection to the kube-apiserver — no in-cluster service needs to be reachable. The intent here is to add a **second**, parallel auth path for human operators: an OIDC kubeconfig that talks to Authentik, so we can issue short-lived, group-bound, revocable credentials to people — without losing the existing bootstrap cert path.

The Headlamp HelmRelease at `kubernetes/apps/observability/headlamp/app/helmrelease.yaml` explicitly anticipates this work ("Will configure k8s OIDC in the future"), and the matching 1Password item `headlamp` already has `HEADLAMP_OIDC_CLIENT_ID/SECRET/ISSUER_URL` waiting in `kubernetes/apps/observability/headlamp/app/externalsecret.yaml`. Authentik itself is already deployed at `auth.${SECRET_DOMAIN}` (`kubernetes/apps/security/authentik/app/helmrelease.yaml`).

User-confirmed scope decisions:

- **LAN-only API exposure.** No Cloudflare Tunnel route for kube-apiserver, no SAN additions to `talconfig.yaml`. OIDC only works on the homelab network. The bootstrap cert path remains a complete rescue.
- **On-demand kubeconfig via justfile.** No checked-in `kubeconfig.oidc.sops.yaml`. A `just kubeconfig-oidc` recipe generates the file locally.
- **Single admin tier only** for the first cut: `kubernetes-admins` group → `cluster-admin`. Developer/viewer tiers deferred.

---

## Phased Implementation

### Phase 0 — Pre-flight (no cluster changes)

1. **Decide and document the OIDC client identity.** Add a new 1Password item named `kubernetes` (so Headlamp's `headlamp` item stays separate). It will hold: `KUBERNETES_OIDC_CLIENT_ID`, `KUBERNETES_OIDC_CLIENT_SECRET`, `KUBERNETES_OIDC_ISSUER_URL` (default to `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/`). The bootstrap cert path is unaffected.
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
3. **Create an Authentik group** named `kubernetes-admins` and add your operator user to it. Confirm the ID-token returned at `/application/o/user/info/` includes `"groups": ["kubernetes-admins"]`.
4. **Store the client ID and secret** in the new 1Password item `kubernetes` (fields `KUBERNETES_OIDC_CLIENT_ID`, `KUBERNETES_OIDC_CLIENT_SECRET`).

After Phase 1, the OIDC issuer is live and reachable at `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/`. **You can still `kubectl` only with the bootstrap cert** — the API server isn't configured for OIDC yet.

### Phase 2 — Talos: wire `--oidc-*` flags into the API server

Goal: enable the API server to validate OIDC tokens. Until the next step, the new flags have no effect on existing users (the bootstrap cert is unaffected by `--oidc-*` flags — those only gate tokens presented as `Bearer` headers).

1. **Extend `talos/patches/controller/cluster.yaml`** in the existing `cluster.apiServer.extraArgs` block. Add:

   ```yaml
   cluster:
     apiServer:
       extraArgs:
         # ...existing flags...
         oidc-issuer-url: https://auth.${INTERNAL_SECRET_DOMAIN}/application/o/kubernetes/
         oidc-client-id: <kubernetes>          # public identifier, not secret
         oidc-username-claim: preferred_username
         oidc-username-prefix: "oidc:"
         oidc-groups-claim: groups
         oidc-groups-prefix: "oidc:"
         oidc-required-claim: "groups=kubernetes-admins"   # hard guardrail
         oidc-signing-algs: RS256
   ```

   The `oidc-issuer-url` and `oidc-client-id` need templating. Two viable paths — pick one before editing:

   - **Hard-code both literals** (issuer URL is the same string everywhere; client ID is stable). Simplest. The client ID is not actually a secret, just a public identifier.
   - **Template them via `postBuild.substitute`** in a new kustomization layer. More correct, more moving parts.

   Recommended: **hard-code** for the first cut. Document the substitution path as a follow-up. The URL and client ID are not secret — only the client secret is.

2. The two `additionalApiServerCertSans` entries in `talconfig.yaml` remain unchanged. **No change.** LAN-only access means no new SANs.

3. Re-render and apply the Talos config patch only — **do NOT bootstrap Kubernetes**. The recipe `just talos` (in `bootstrap/mod.just`) loops over each control plane and runs `talosctl apply-config --insecure`. This rolls kube-apiserver on each control plane to pick up the new flags; etcd is untouched and the admin client cert stays valid. Equivalent: `task talos` from the Taskfile.

   ```sh
   just talos        # or: task talos
   ```

   **Never run `just mod talos -- bootstrap` here** — that would call `talosctl bootstrap` and attempt to re-initialize the etcd cluster. We only want a config apply, not a bootstrap.

4. **Verify after the roll**: confirm the running kube-apiserver has the flags. From any control-plane node via talosctl:

   ```sh
   talosctl -n <control-plane-node-ip> read /etc/kubernetes/manifests/kube-apiserver.yaml | grep -E 'oidc-'
   ```

   Should show the six new flags.

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
       KUBECONFIG="${HOME}/.kube/oidc-kubeconfig.yaml" \
       kubectl oidc-login setup \
           --kubeconfig="${HOME}/.kube/oidc-kubeconfig.yaml" \
           --oidc-issuer-url="${issuer}" \
           --oidc-client-id="${client_id}" \
           --oidc-client-secret="${client_secret}" \
           --grant-type=auto \
           --listen-address=127.0.0.1:8000 \
           --callback-hostname=127.0.0.1 \
           --extra-scope=openid,profile,email,groups
       if ! kubectl config set-cluster main \
               --kubeconfig="${HOME}/.kube/oidc-kubeconfig.yaml" \
               --server="https://<api-server-vip>:6443"; then \
           just log fatal "Failed to set cluster server" "stage" "$0"; \
       fi
       just log info "OIDC kubeconfig written to ${HOME}/.kube/oidc-kubeconfig.yaml" "stage" "$0"
   ```

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

   With an admin user → output includes `Groups: [oidc:kubernetes-admins, system:authenticated]`. With a non-admin user → `oidc:kubernetes-admins` is absent, so subsequent `kubectl get secrets -A` returns 403. (A non-admin test user is optional but proves the `oidc-required-claim` guardrail in Phase 2 is wired correctly.)

6. **SelfSubjectReview is available** (helps future tooling confirm identity; free to add since we're already touching this area):

   ```sh
   KUBECONFIG=~/.kube/oidc-kubeconfig.yaml kubectl auth whoami --output json
   ```

   Already covered by the standard apiserver auth flow.

### Rollback

Each phase is independently reversible:

- **Phase 4** (justfile recipe): delete the recipe. Nothing checked in.
- **Phase 3** (RBAC): `kubectl delete clusterrolebinding kubernetes-admins` or remove the file from Flux.
- **Phase 2** (Talos apiserver flags): remove the six `oidc-*` entries from `talos/patches/controller/cluster.yaml` and re-render/apply. The API server restarts without OIDC support. The bootstrap cert path is unaffected throughout.
- **Phase 1** (Authentik provider/application/group): UI deletion only. No cluster state to undo.
- **Phase 0**: no-op.

If the apiserver fails to come back up after Phase 2, **the rescue is `talosctl -n <control-plane-node-ip> rollback`** — that reverts the Talos host to its previous config and brings the apiserver up with the old flags. The bootstrap kubeconfig then works against the reverted apiserver. After recovery, the patch is re-edited and re-applied.

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

- **Internal domain templating:** every domain literal in this plan uses `${SECRET_DOMAIN}` or `${INTERNAL_SECRET_DOMAIN}`. Per repo convention, no literal internal-domain strings may appear in YAML or docs.
- **Internal-only templating** for the issuer URL when the user is fully on-LAN: `auth.${INTERNAL_SECRET_DOMAIN}` resolves via the in-cluster gateway and avoids any external DNS lookup from the API server. Recommended: use `${INTERNAL_SECRET_DOMAIN}` in the `oidc-issuer-url` arg to remove the public-DNS dependency for cluster-internal OIDC validation. The kube-apiserver validates tokens using the JWKS at this URL, and the internal gateway terminates it the same way it does for any other service.
- **SOPS-encrypt any checked-in secret-bearing file.** The recipe in Phase 4 reads 1Password at runtime and writes the kubeconfig to `${HOME}` — nothing is committed, so no encryption needed for it.
- **No `--oidc-*` flag is ever destructive.** None of the six flags touch the existing `admin` client cert — they only gate token-presented requests.

---

## Placeholders Used in This Document

Some specifics have been abstracted with `<placeholder>` markers. Fill them in from your local repo when implementing:

| Placeholder | What it is | Where to find it |
| --- | --- | --- |
| `<control-plane-node-ip>` | IP of any control-plane node (k8s-01/02/03) | `talos/clusterconfig/talosconfig` `nodes:` list |
| `<api-server-vip>` | HA VIP that fronts the kube-apiserver | `talos/talconfig.yaml` `endpoint:` and each `vip.ip` |
| `<internal-gateway-ip>` | The Cilium `external` gateway IP used internally for service traffic | `kubernetes/apps/kube-system/cilium/gateway/external.yaml` `addresses[0].value` |
| `<kubernetes>` | OIDC client ID (not secret — just the public identifier) | assigned by Authentik when the provider is created |