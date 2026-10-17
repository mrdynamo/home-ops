---
title: Kubernetes OIDC Authentication via Authentik
description: Step-by-step plan to add OIDC authentication for human operators while preserving the Talos-issued bootstrap client-cert rescue path.
---

# Kubernetes OIDC Authentication via Authentik

> **Status:** Reviewed 2026-10-17; not ready to apply unchanged. The current worktree already contains an incomplete OIDC `extraArgs` block in `talos/patches/controller/cluster.yaml` (including an internal-domain placeholder and a `<kubernetes>` client-ID placeholder). Runtime state has not been verified. The bootstrap kubeconfig remains useful while an apiserver is healthy; if all apiservers are down, recovery must use Talos management access.

## Validation review

The architecture is viable: Kubernetes can authenticate Authentik-issued OIDC tokens alongside the existing client certificate, and a group-subject `ClusterRoleBinding` can grant the intended admin access. The steps below need the following corrections before implementation:

| Priority | Plan area | Finding | Required change |
| --- | --- | --- | --- |
| Blocker | Phase 2 / current Talos patch | The checked-out patch uses `https://auth.${INTERNAL_SECRET_DOMAIN}/...` and a literal `<kubernetes>` client ID. Authentik's current HelmRelease attaches its route to the `external` gateway, not an internal route. The issuer and client ID must be real values that are reachable/valid from every control-plane node. | Use the actual public issuer and client ID; verify the issuer discovery document and JWKS are reachable from each control plane. Inspect the generated kube-apiserver manifest before applying. |
| Blocker | Phase 2 / apply command | `talhelper genconfig --with-secrets ... -o -` is not a valid command for the repository's Talhelper version (3.1.17): it has `--secret-file` and `--out-dir`, and writes node configs rather than streaming one config to stdout. | Use the repo's `task talos:generate-config` and per-node `task talos:apply-node IP=...` workflow after checking its generated output. |
| Blocker | Phase 2 / required claim | `oidc-required-claim` compares a claim to a scalar string; Authentik's `groups` claim is a JSON array. `groups=kubernetes-admins` is not a reliable membership test and can reject valid tokens. | Remove this flag. The RBAC binding already denies non-admin groups access to cluster resources. If authentication itself must be restricted, use a Kubernetes `AuthenticationConfiguration` JWT authenticator with a CEL `claimValidationRule`, tested against an actual ID token. |
| Blocker | Phase 4 / kubeconfig | The sample sets shell variables on separate Just recipe lines, so they do not persist to later lines. The cluster entry also has no CA configured; `--embed-certs=true` does not supply one, and the API VIP is still a placeholder. | Implement the recipe as one script/shell, use the real VIP (`https://192.168.30.10:6443`), and embed only the CA from the existing bootstrap kubeconfig (never its client certificate or key). |
| High | Phase 1 / client | The sample places the confidential client secret in exec arguments persisted in kubeconfig and exposed in the process argument list. This is a local native client and Authentik supports PKCE. | Prefer a public client with authorization code + PKCE and no client secret. If a confidential client is retained, do not describe its secret-bearing kubeconfig as safe merely because it is not checked in. |
| High | Phase 1 / refresh | Authentik does not issue refresh tokens by default; `offline_access` and its provider scope mapping are needed. The listed scopes omit it. | Add/request `offline_access` and configure the matching Authentik scope mapping, or explicitly accept interactive reauthentication when the ID token expires. |
| High | Rollback | `talosctl rollback` reverts the previous Talos installation, not a prior machine configuration. The described recovery would not restore the previous apiserver flags. | Save known-good per-node machine configs and restore with `talosctl apply-config` through the Talos management API (or documented console recovery). Do not use `rollback` as a config rollback. |
| Medium | Phase 1 / issuer | In Authentik global issuer mode the discovery document remains under `/application/o/<slug>/.well-known/openid-configuration`; only the metadata `issuer` changes to the root URL. | Validate both the discovery URL and its returned `issuer`, then use that exact issuer value in the apiserver and kubeconfig. |
| Medium | Phase 1 / TLS | Authentik's JWT signing key and the HTTPS certificate for the issuer URL are separate. A self-signed JWT signing key can be used, but the API server and kubelogin still need to validate Authentik's HTTPS certificate. | Keep TLS verification enabled and verify the issuer's HTTPS certificate chain from the clients and control planes. |
| Medium | Phase 4 / callback | The explicit `--listen-address=127.0.0.1:8000` overrides kubelogin's default address list, so it cannot fall back to port 18000 as the notes claim. | Omit the flag to retain kubelogin's 8000/18000 fallback, or specify both listener addresses and allow both callback URIs in Authentik. |
| Medium | Phase 5 / identity check | `kubectl auth whoami` is built into the repository's pinned kubectl v1.37.1; the claimed Krew plugin requirement is false. The sample SelfSubjectReview output also duplicates `system:authenticated`. | Use `kubectl auth whoami -o yaml` and expect `system:authenticated` once. |
| Low | Phase 0 | `aqua:int128/kubelogin` is already pinned in `.mise.toml` at `1.36.4`. | Do not add it again; verify the installed version instead. |

Kubernetes OIDC authenticators validate signed tokens locally. Revoking a user or refresh token prevents future token issuance/renewal, but an already-issued ID token can remain usable until it expires (subject to token-cache behavior); set and test a suitably short Authentik token lifetime if rapid revocation matters.

## Context

The cluster currently relies on a single, long-lived bootstrap admin kubeconfig whose only credential is a Talos-issued client certificate (`kubeconfig` at the repo root, gitignored, user `admin@kubernetes`, context `admin@kubernetes`, cluster `kubernetes`, server `https://192.168.30.10:6443`). That works as a rescue path while at least one kube-apiserver is healthy: it requires only LAN access to that API endpoint and no in-cluster service. If every apiserver is down, this kubeconfig cannot restore API availability; Talos management access is required. The intent here is to add a **second**, parallel auth path for human operators: an OIDC kubeconfig that talks to Authentik and issues short-lived, group-bound credentials without losing the existing bootstrap cert path. Already-issued JWTs are not immediately revoked by disabling a user or refresh token; they remain valid until expiration.

The Headlamp HelmRelease at `kubernetes/apps/observability/headlamp/app/helmrelease.yaml` explicitly anticipates this work ("Will configure k8s OIDC in the future"), and the matching 1Password item `headlamp` already has `HEADLAMP_OIDC_CLIENT_ID/SECRET/ISSUER_URL` waiting in `kubernetes/apps/observability/headlamp/app/externalsecret.yaml`. Authentik itself is already deployed at `auth.${SECRET_DOMAIN}` (`kubernetes/apps/security/authentik/app/helmrelease.yaml`).

User-confirmed scope decisions:

- **LAN-only API exposure.** No Cloudflare Tunnel route for kube-apiserver, no SAN additions to `talconfig.yaml`. OIDC only works on the homelab network. The bootstrap cert remains an independent auth path while kube-apiserver is healthy; Talos management access is needed if all API servers are down.
- **On-demand kubeconfig via justfile.** No checked-in `kubeconfig.oidc.sops.yaml`. A `just kubeconfig-oidc` recipe generates the file locally.
- **Single admin tier only** for the first cut: `kubernetes-admins` group → `cluster-admin`. Developer/viewer tiers deferred.

---

## Phased Implementation

### Phase 0 — Pre-flight (no cluster changes)

1. **Decide and document the OIDC client identity.** Add a new 1Password item named `kubernetes` (so Headlamp's `headlamp` item stays separate). For a public PKCE client, store `KUBERNETES_OIDC_CLIENT_ID` and `KUBERNETES_OIDC_ISSUER_URL` (the exact `issuer` value from Authentik's discovery document). Do not store a client secret for a public client. The issuer must be reachable over HTTPS from the operator's laptop and each control-plane node. The bootstrap cert path is unaffected.
2. **Verify `kubectl-oidc-login` (or `kubelogin`) is available** via mise. `.mise.toml` already pins `aqua:int128/kubelogin` at `1.36.4`; do not add a duplicate entry. This binary is the `exec` plugin the OIDC kubeconfig will call.
3. **Decide the OIDC group name.** Use the literal string `kubernetes-admins`. It will appear both in the Authentik group definition and in the Kubernetes `ClusterRoleBinding`.

### Phase 1 — Authentik side: create the OIDC provider

Goal: have a working OIDC client for the kube-apiserver to validate against. The bootstrap cert is still the only way to authenticate during this phase.

1. In the Authentik UI, **create a new OAuth2/OpenID Provider**:
   - Name: `Kubernetes`
   - Signing Key: the default Authentik signing key is suitable; this is separate from the HTTPS certificate used to serve Authentik
   - Redirect URIs: `http://localhost:8000` and `http://localhost:18000` if retaining kubelogin's default listener fallback. If pinning a single listener port, register only the URI that the chosen configuration actually uses.
   - Scopes/scope mappings: `openid`, `email`, `profile`, `groups`, and `offline_access` if refresh tokens are wanted. Authentik must have the relevant group and offline-access scope mappings enabled.
   - Subject mode: `Based on the User's username`
2. **Create a matching Application** in Authentik:
   - Name: `Kubernetes`
   - Provider: the one above
   - Slug: `kubernetes`
3. **Create an Authentik group** named `kubernetes-admins` and add your operator user to it. The `/application/o/userinfo/` endpoint returns a UserInfo response, not an ID token. Inspect the actual ID token claims locally (and/or call UserInfo with the access token) to confirm that `groups` is an array containing exactly the expected group value. The reserved global slugs in Authentik are `authorize`, `token`, `device`, `userinfo`, `introspect`, `revoke` — there is no `user/info` endpoint.
4. **Store the client ID** in the new 1Password item `kubernetes`. With a public client using PKCE, no client secret is needed or stored.

After Phase 1, the OIDC issuer is live and reachable at `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/`. **You can still `kubectl` only with the bootstrap cert** — the API server isn't configured for OIDC yet.

> **Authentik issuer-mode assumption.** Per-provider issuer mode is the default and uses `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/`. In global issuer mode the discovery document is still served at `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/.well-known/openid-configuration`, but its returned `issuer` is `https://auth.${SECRET_DOMAIN}/`. The API server's configured issuer must exactly match that returned `issuer`; do not infer it from the discovery document's URL alone.

### Phase 2 — Talos: configure the API server JWT authenticator

Goal: enable the API server to validate OIDC tokens. Valid settings add a bearer-token authentication path and do not invalidate client-certificate authentication. However, malformed settings can prevent kube-apiserver from starting, so the bootstrap certificate is not a recovery path for an API-server crashloop.

> **Talos 1.14 / Talhelper 3.1.17.** Talos 1.14 splits control-plane settings into dedicated documents (`KubeAPIServerConfig`, `KubeAuthenticationConfig`, `KubeProxyConfig`, `ResolverConfig`, ...). Talhelper 3.1.17 (final release) already emits them, so legacy `cluster.apiServer`, `cluster.controllerManager`, `cluster.scheduler`, `cluster.proxy`, `cluster.discovery` and `machine.network.nameservers` patches fail generation. The patches under `talos/patches/` were migrated to the document form, and the `oidc-*` flags became a `KubeAuthenticationConfig` JWT authenticator (`--oidc-*` flags are no longer used).

1. **`talos/patches/controller/cluster.yaml`** carries the `KubeAuthenticationConfig` document:

   ```yaml
   apiVersion: v1alpha1
   kind: KubeAuthenticationConfig
   configuration:
     anonymous:            # keep the Talos defaults; the patch replaces this list
       enabled: true
       conditions:
         - path: /livez
         - path: /readyz
         - path: /healthz
     jwt:
       - issuer:
           url: https://auth.${SECRET_DOMAIN}/application/o/kubernetes/
           audiences:
             - <client-id>       # public identifier, not secret
         claimMappings:
           username: {claim: preferred_username, prefix: "oidc:"}
           groups: {claim: groups, prefix: "oidc:"}
   ```

   The issuer URL must exactly match the discovery document's `issuer` value and be reachable from every control-plane node. Authentik is routed on the `external` gateway, so use the public domain. Test DNS, TLS certificate, discovery document and JWKS from the nodes before applying.

   The API server and kubelogin must still validate the HTTPS certificate for the issuer URL. The Authentik JWT signing key can be self-signed because token signatures are checked against JWKS; this does not make an untrusted HTTPS endpoint acceptable.

   **Keeping the domain out of git.** `talos/talenv.yaml` stays plaintext so Renovate can bump Talos/Kubernetes versions. The domain lives in `talos/talenv.sops.yaml` (SOPS-encrypted, covered by the existing `talos/.*\.sops\.ya?ml` rule). Talhelper loads both env files and substitutes `${SECRET_DOMAIN}` in `@file` patches. Flux's `cluster-secrets` substitution does not apply to Talos. Note that `$` in patches must be escaped as `$$` (for example `$$patch: delete`), and `talos/clusterconfig/` contains the resolved domain and must remain gitignored.

   The group name must match between Authentik and the ClusterRoleBinding subject (`oidc:kubernetes-admins` after applying the groups prefix). No `required-claim` equivalent is used; the ClusterRoleBinding is the authorization guard for non-admin groups. To restrict authentication itself, add a CEL `claimValidationRules` entry to the JWT authenticator and test it against a real ID token.

   Subject-mode interaction: with Authentik "Subject mode: Based on the User's username" and `claim: preferred_username`, the OIDC username is `<auth-user-username>`. The binding in Phase 3 uses `Group`, not `User`, so this is fine, but a `User`-subject binding would need the `oidc:` prefix.

   Signing algorithm: the structured authenticator accepts the algorithms Authentik publishes in JWKS (RS256 by default); no separate flag is needed.

2. The two `additionalApiServerCertSans` entries in `talconfig.yaml` remain unchanged. **No change.** LAN-only access means no new SANs.

3. Generate and apply the new config to each control plane. **Do NOT bootstrap Kubernetes.** The direct command previously shown here, `talhelper genconfig --with-secrets ... -o -`, is not supported by this Talhelper version. Use the repository's task flow, which generates node configs and applies them with the configured Talos credentials:

   ```sh
   task talos:generate-config
   task talos:apply-node IP=192.168.30.21
   ```

   The `IP` must be the node being changed; repeat one control plane at a time, waiting for that node and its apiserver to recover before proceeding. Review the generated config and apply mode before rollout. Etcd is not intentionally modified by this change, and the admin client certificate remains a separate authenticator. The bootstrap Talos flow is not the right command here.

   **Never run `talosctl bootstrap`** on a node that's already part of a healthy cluster — that re-initializes etcd and destroys the cluster.

4. **Verify after each roll** (per node). The static-pod manifest on disk is not the same as a healthy running apiserver — if any flag value is malformed (e.g. a literal `${SECRET_DOMAIN}` that wasn't substituted, or an unescaped `<secret-domain>` placeholder left from a partially-edited patch), the manifest still exists on disk but kube-apiserver is crashlooping. Run **all three**:

   ```sh
   # 1. The authentication config is wired into the static-pod manifest:
   talosctl -n <control-plane-node-ip> read /etc/kubernetes/manifests/kube-apiserver.yaml \
     | grep -E 'authentication-config'
   # Expect --authentication-config and no legacy --oidc-* flags.

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

1. **Add the recipe** to `bootstrap/mod.just` (next to the existing `kubeconfig` recipe). Implement it as one Just script/shell invocation; ordinary multi-line recipe commands run in separate shells, so assignments such as `issuer=...` do not carry over to later recipe lines.

   The recipe must:

   - Read the exact issuer and client ID from the 1Password item (the plan already defines `KUBERNETES_OIDC_ISSUER_URL`; do not rely on `${SECRET_DOMAIN}` being a local shell variable).
   - Create a cluster entry for `https://192.168.30.10:6443` and embed the Kubernetes CA from the existing bootstrap kubeconfig or an equivalent trusted source. `--embed-certs=true` only embeds a CA when a CA file is supplied. Never copy the bootstrap user certificate or key into the OIDC kubeconfig.
   - Create an OIDC `exec` user using `kubectl oidc-login get-token`, the actual client ID, and `client.authentication.k8s.io/v1`; select the `oidc` context.
   - Use an Authentik public client with PKCE so no client secret is stored in the kubeconfig. Request `openid`, `profile`, `email`, `groups`, and `offline_access` if the Authentik provider is configured to issue refresh tokens.
   - Write only to `${HOME}/.kube/oidc-kubeconfig.yaml` and fail clearly if `op`, `kubectl`, or `kubectl oidc-login` fails.

   Do not run the original sample unchanged: its shell variables do not persist between lines, it leaves the VIP as a placeholder, it has no cluster CA, and it persists a client secret in exec arguments.

   Flag notes (cross-checked against [kubelogin usage.md](https://github.com/int128/kubelogin/blob/master/docs/usage.md)):
   - `--oidc-extra-scope` (with the `oidc-` prefix) — not `--extra-scope`. The unscoped form is silently ignored. Repeat the flag once per scope, do not comma-join values.
   - By default kubelogin tries `127.0.0.1:8000`, then `127.0.0.1:18000`. Explicitly setting `--listen-address=127.0.0.1:8000` replaces that list and disables the fallback. Register both redirect URIs if retaining the default list; otherwise register the single configured callback.
   - There is **no** `--callback-hostname` flag — the loopback callback host is derived from `--listen-address`.
   - `--token-cache-storage=keyring` keeps cached tokens in the OS keyring instead of plaintext on disk. Drop this only if the machine has no supported keyring and accept the security implications of file-backed token cache under `${HOME}/.kube/cache/oidc-login`.
   - `--grant-type=auto` lets kubelogin pick `authcode` if a browser is reachable, `device-code` otherwise. Useful when SSH'd into a headless box.

   The recipe assumes `op` (1Password CLI) is on `$PATH` and the user is signed in to the `kubernetes-connect` 1Password account. The bootstrap kubeconfig at `${REPO}/kubeconfig` is **not** touched.

2. **Keep the bootstrap credential unchanged.** The repo-root `kubeconfig` (Talos client-cert) is intentionally NOT modified. It remains usable if at least one kube-apiserver is healthy; it cannot restore API availability if all apiservers are down, in which case use Talos management access and the saved known-good machine configs.

### Phase 5 — Verification

End-to-end check, in order. **Each step must pass before moving to the next.**

1. **Bootstrap path still works** (rescue posture):

   ```sh
   KUBECONFIG=./kubeconfig kubectl get nodes
   ```

   Must return all 6 nodes Ready. This is the contract — OIDC work never breaks this.

2. **OIDC arguments live in the API server**:

   ```sh
   talosctl -n <control-plane-node-ip> read /etc/kubernetes/manifests/kube-apiserver.yaml \
     | grep -E 'authentication-config'
   ```

   Also confirm `grep -c '\${' talos/clusterconfig/*.yaml` is 0 so the issuer and client ID are fully resolved.

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

5. **Identity and group claims are correct** (check both an admin and, if available, a non-admin Authentik user):

   ```sh
   KUBECONFIG=~/.kube/oidc-kubeconfig.yaml kubectl auth whoami -o yaml
   ```

   `kubectl auth whoami` is included in the repository's pinned kubectl v1.37.1. An admin's output should have an `oidc:`-prefixed username and include `oidc:kubernetes-admins` and `system:authenticated` once. A non-admin may authenticate but must not receive the admin group.

6. **Verify RBAC**, not just authentication. An admin should be able to list secrets. If testing with a non-admin user, the same operation should return 403. The `oidc-required-claim` flag is not needed for this RBAC check.

### Rollback

Each phase is independently reversible:

- **Phase 4** (justfile recipe): delete the recipe. Nothing checked in.
- **Phase 3** (RBAC): `kubectl delete clusterrolebinding kubernetes-admins` or remove the file from Flux.
- **Phase 2** (Talos apiserver flags): remove the `KubeAuthenticationConfig` JWT entry from `talos/patches/controller/cluster.yaml` and regenerate/apply the node configs. The API server restarts without OIDC support. The bootstrap cert path is unaffected throughout.
- **Phase 1** (Authentik provider/application/group): UI deletion only. No cluster state to undo.
- **Phase 0**: no-op.

Before applying Phase 2, save the currently working, per-node Talos machine configs in a protected local location. `talosctl rollback` is an OS-installation rollback, not a configuration rollback; do not use it to restore apiserver flags.

Recovery sequence:

1. Use the Talos management API (or console/maintenance recovery if the API is unavailable) to re-apply the saved known-good config to the affected node with `talosctl apply-config`.
2. Verify that the kube-apiserver is healthy and the control plane has recovered before restoring any other affected nodes, one at a time.
3. Fix the patch, regenerate node configs with `task talos:generate-config`, and retry a staged per-node apply only after the generated arguments and recovery path have been checked.

The bootstrap kubeconfig (`KUBECONFIG=./kubeconfig kubectl ...`) remains valid when an apiserver is healthy because the admin client cert is unaffected by OIDC configuration. It cannot help if all apiservers are down.

---

## Critical Files

### Modified

- `talos/patches/controller/cluster.yaml` — `KubeAuthenticationConfig` JWT authenticator plus the other Talos 1.14 document migrations; domain comes from encrypted `talos/talenv.sops.yaml`.
- `bootstrap/mod.just` — add `kubeconfig-oidc` recipe alongside the existing `kubeconfig` recipe.
- `kubernetes/apps/security/kustomization.yaml` — register the new `./auth/ks.yaml` under `resources:`.

### Created (under `kubernetes/apps/security/auth/`)

- `clusterrolebinding.yaml` — `oidc:kubernetes-admins` → `cluster-admin` (single admin tier only)
- `kustomization.yaml` — bundles the clusterrolebinding
- `ks.yaml` — Flux Kustomization; `cluster-secrets` substitution is unnecessary unless the auth resources later contain substituted values.

### Reused existing patterns (do not duplicate)

- Group-subject ClusterRoleBinding precedent: `kubernetes/apps/flux-system/flux-operator/app/clusterrolebinding.yaml`
- `cluster-secrets` substitute pattern: `kubernetes/apps/security/authentik/ks.yaml`
- Authentik HelmRelease envFrom ExternalSecret pattern: `kubernetes/apps/security/authentik/app/externalsecret.yaml`
- Talos controller patch (documents): `talos/patches/controller/cluster.yaml`
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
- No separate `SelfSubjectReview` resource; `kubectl auth whoami` uses the API's SelfSubjectReview endpoint.
- No changes to Headlamp's still-commented-out OIDC block — that's a follow-up after Phase 5 verification lands.

---

## Conventions to Honour

- **Domain templating:** Flux substitution variables are not automatically available to local Just recipes or Talos config patches. Read the issuer from the configured 1Password item for the recipe and verify the generated Talos values.
- **Issuer URL must match Authentik discovery metadata** and be reachable from the control planes. The current Authentik HelmRelease uses the `external` gateway; do not configure an internal hostname unless that route and DNS path have been explicitly verified.
- **Flux substitution does not apply to Talos patches.** Resolve any domain or client-ID values before applying the Talos config, and check generated output for placeholders.
- **SOPS-encrypt any checked-in secret-bearing file.** The recipe in Phase 4 reads 1Password at runtime and writes the kubeconfig to `${HOME}` — nothing is committed, so no encryption needed for it.
- **OIDC configuration does not invalidate the existing admin client certificate**, but malformed values can still make kube-apiserver fail to start. Preserve and test the Talos recovery path before rollout.

---

## Placeholders Used in This Document

Some specifics have been abstracted with `<placeholder>` markers. Fill them in from your local repo when implementing:

| Placeholder | What it is | Where to find it |
| --- | --- | --- |
| `<control-plane-node-ip>` | IP of any control-plane node (k8s-01/02/03) | `talos/clusterconfig/talosconfig` `nodes:` list |
| `<api-server-vip>` | HA VIP that fronts the kube-apiserver; currently `192.168.30.10` | `talos/talconfig.yaml` `endpoint:` and each `vip.ip` |
| `<secret-domain>` | The hostname used in the Authentik issuer URL; confirm it against the discovery document | Authentik provider/application and DNS configuration |
| `<kubernetes>` | OIDC client ID (not secret — just the public identifier) | assigned by Authentik when the provider is created |
