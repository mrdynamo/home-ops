---
title: Kubernetes OIDC Authentication via Authentik
description: Step-by-step plan to add OIDC authentication for human operators while preserving the Talos-issued bootstrap client-cert rescue path.
---

# Kubernetes OIDC Authentication via Authentik

> **Status:** Reviewed 2026-10-17. Talos config moved from talhelper to topf on 2026-10-26 (see [talos-1.14-upgrade-prep.md](talos-1.14-upgrade-prep.md)): the JWT authenticator now lives in `talos/control-plane/04-oidc.yaml.tpl` and the domain in the SOPS-encrypted `data.secretDomain` of `talos/topf.yaml`. The validation table below records the review findings against the talhelper-era plan. The bootstrap kubeconfig remains useful while an apiserver is healthy; if all apiservers are down, recovery must use Talos management access.

## Validation review

The architecture is viable: Kubernetes can authenticate Authentik-issued OIDC tokens alongside the existing client certificate, and a group-subject `ClusterRoleBinding` can grant the intended admin access. The steps below need the following corrections before implementation:

| Priority | Plan area | Finding | Required change |
| --- | --- | --- | --- |
| Blocker | Phase 2 / current Talos patch | The checked-out patch uses `https://auth.${INTERNAL_SECRET_DOMAIN}/...` and a literal `<kubernetes>` client ID. Authentik's current HelmRelease attaches its route to the `external` gateway, not an internal route. The issuer and client ID must be real values that are reachable/valid from every control-plane node. | Use the actual public issuer and client ID; verify the issuer discovery document and JWKS are reachable from each control plane. Inspect the generated kube-apiserver manifest before applying. |
| Blocker | Phase 2 / apply command | `talhelper genconfig --with-secrets ... -o -` is not a valid command for the repository's Talhelper version (3.1.17): it has `--secret-file` and `--out-dir`, and writes node configs rather than streaming one config to stdout. | Use the repo's per-node workflow after checking its output: `just talos diff-node <host>`, then `just talos apply-node <host>` (topf; talhelper and the Taskfiles are retired). |
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

- **LAN-only API exposure.** No Cloudflare Tunnel route for kube-apiserver, no SAN additions to `talos/all/04-machine-certsans.yaml`. OIDC only works on the homelab network. The bootstrap cert remains an independent auth path while kube-apiserver is healthy; Talos management access is needed if all API servers are down.
- **On-demand kubeconfig via justfile.** No checked-in `kubeconfig.oidc.sops.yaml`. A `just kubeconfig-oidc` recipe generates the file locally.
- **Single admin tier only** for the first cut: `kubernetes-admins` group → `cluster-admin`. Developer/viewer tiers deferred.

---

## Phased Implementation

### Phase 0 — Pre-flight (no cluster changes)

1. **Decide and document the OIDC client identity.** Add a new 1Password item named `kubernetes` (so Headlamp's `headlamp` item stays separate). For a public PKCE client, store `KUBERNETES_OIDC_CLIENT_ID` and `KUBERNETES_OIDC_ISSUER_URL` (the exact `issuer` value from Authentik's discovery document). Do not store a client secret for a public client. The issuer must be reachable over HTTPS from the operator's laptop and each control-plane node. The bootstrap cert path is unaffected.

   **Vault:** store the `kubernetes` item in the `Chezmoi` vault, not `kubernetes-connect`. The `kubernetes-connect` vault holds the cluster-provisioning secrets (1Password Connect token, SOPS age key) and the in-cluster `ClusterSecretStore` is scoped to it; headless Linux hosts authenticate with a 1Password **service account** that only has access to `Chezmoi`, so a `kubernetes-connect` item is unreachable there. Neither OIDC field is a secret (public PKCE client, public identifier), so the vault choice costs nothing in confidentiality.
2. **Verify `kubectl-oidc-login` (or `kubelogin`) is available** via mise. `.mise.toml` already pins `aqua:int128/kubelogin` at `1.36.4`; do not add a duplicate entry. This binary is the `exec` plugin the OIDC kubeconfig will call.
3. **Decide the OIDC group name.** Use the literal string `kubernetes-admins`. It will appear both in the Authentik group definition and in the Kubernetes `ClusterRoleBinding`.

### Phase 1 — Authentik side: create the OIDC provider

Goal: have a working OIDC client for the kube-apiserver to validate against. The bootstrap cert is still the only way to authenticate during this phase.

1. In the Authentik UI, **create a new OAuth2/OpenID Provider**:
   - Name: `Kubernetes`
   - Signing Key: the default Authentik signing key is suitable; this is separate from the HTTPS certificate used to serve Authentik
   - Redirect URIs: `http://localhost:8000` and `http://localhost:18000` if retaining kubelogin's default listener fallback. If pinning a single listener port, register only the URI that the chosen configuration actually uses.
   - **Grant Types**: the provider must include **Device-code** (`urn:ietf:params:oauth:grant-type:device_code`). The device authorization grant is what lets a headless host sign in from another browser with no callback listener and no tunnel (see Phase 4). The device authorization endpoint rejects a client whose provider does not allow it (`invalid_client`).
   - Scopes/scope mappings: `openid`, `email`, `profile`, and `offline_access` if refresh tokens are wanted. Authentik must have the relevant group and offline-access scope mappings enabled. Note how the `groups` **claim** reaches the token: it is produced by one of the provider's scope mappings, and that mapping's *scope name* need not be `groups`. Authentik clamps every request to the configured scope names (the server log says *"Application requested scopes not configured, setting to overlap"*), so kubelogin's `--oidc-extra-scope=groups` is dropped as a scope and the claim arrives with the scope that does carry it. What matters is the claim, not the scope name: `claims_supported` in the discovery document must list `groups`.
   - Subject mode: `Based on the User's username`
2. **Create a matching Application** in Authentik:
   - Name: `Kubernetes`
   - Provider: the one above
   - Slug: `kubernetes`
3. **Create an Authentik group** named `kubernetes-admins` and add your operator user to it. The `/application/o/userinfo/` endpoint returns a UserInfo response, not an ID token. Inspect the actual ID token claims locally (and/or call UserInfo with the access token) to confirm that `groups` is an array containing exactly the expected group value. The reserved global slugs in Authentik are `authorize`, `token`, `device`, `userinfo`, `introspect`, `revoke` — there is no `user/info` endpoint.
4. **Give the brand a device code flow.** The device authorization grant needs one thing the provider does not cover: a flow on the *brand*. Authentik ships no default for it — `blueprints/default/default-brand.yaml` sets `flow_authentication`, `flow_invalidation`, `flow_user_settings` and `flow_request`, and leaves `flow_device_code` null.
   - **Flows and Stages → Flows → Create**: Name `Device code flow`, Title `Device code flow`, Slug `default-device-code-flow`, **Designation: `Stage Configuration`**, **Authentication: `Require authentication`** → Create. The flow can stay empty — Authentik appends the code-entry stage itself.
   - **System → Brands → Default brand → Edit**: set **Device code flow** to that flow → Update. The picker only lists flows whose designation is `Stage Configuration`, so the designation above is what makes the flow selectable.

   Without this, `/device?code=…` answers **HTTP 404 with an empty body** — a blank white page after the login. The server log says *"Brand has no device code flow configured"* (`authentik.providers.oauth2.views.device_init`). The check happens before the code is even looked at, so the `?code=` link fails exactly like the plain URL.

   The device code itself lives for the provider's **access code validity** (`expires_in`, one minute with the Authentik default), so the browser step has to be completed within that window. Raise the provider's *Access code validity* (e.g. `minutes=5`) if a minute is too short to log in and approve.
5. **Store the client ID** in the new 1Password item `kubernetes`. With a public client using PKCE, no client secret is needed or stored.

After Phase 1, the OIDC issuer is live and reachable at `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/`. **You can still `kubectl` only with the bootstrap cert** — the API server isn't configured for OIDC yet.

> **Authentik issuer-mode assumption.** Per-provider issuer mode is the default and uses `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/`. In global issuer mode the discovery document is still served at `https://auth.${SECRET_DOMAIN}/application/o/kubernetes/.well-known/openid-configuration`, but its returned `issuer` is `https://auth.${SECRET_DOMAIN}/`. The API server's configured issuer must exactly match that returned `issuer`; do not infer it from the discovery document's URL alone.

### Phase 2 — Talos: configure the API server JWT authenticator

Goal: enable the API server to validate OIDC tokens. Valid settings add a bearer-token authentication path and do not invalidate client-certificate authentication. However, malformed settings can prevent kube-apiserver from starting, so the bootstrap certificate is not a recovery path for an API-server crashloop.

> **Talos 1.14 / topf.** Talos 1.14 splits control-plane settings into dedicated documents (`KubeAPIServerConfig`, `KubeAuthenticationConfig`, `KubeProxyConfig`, `ResolverConfig`, ...), and legacy `cluster.apiServer`, `cluster.controllerManager`, `cluster.scheduler`, `cluster.proxy`, `cluster.discovery` and `machine.network.nameservers` patches are rejected. The patches under `talos/` use the document form, and the `oidc-*` flags became a `KubeAuthenticationConfig` JWT authenticator (`--oidc-*` flags are no longer used).

1. **`talos/control-plane/04-oidc.yaml.tpl`** carries the `KubeAuthenticationConfig` document:

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
           url: https://auth.{{ .Data.secretDomain }}/application/o/kubernetes/
           audiences:
             - <client-id>       # public identifier, not secret
         claimMappings:
           username: {claim: preferred_username, prefix: "oidc:"}
           groups: {claim: groups, prefix: "oidc:"}
   ```

   The issuer URL must exactly match the discovery document's `issuer` value and be reachable from every control-plane node. Authentik is routed on the `external` gateway, so use the public domain. Test DNS, TLS certificate, discovery document and JWKS from the nodes before applying.

   The API server and kubelogin must still validate the HTTPS certificate for the issuer URL. The Authentik JWT signing key can be self-signed because token signatures are checked against JWKS; this does not make an untrusted HTTPS endpoint acceptable.

   **Keeping the domain out of git.** The domain is `data.secretDomain` in `talos/topf.yaml`. Only that `data:` block is SOPS-encrypted (the `talos/topf\.yaml$` rule in `.sops.yaml`), so the rest of the file stays plaintext and Renovate can still bump the Talos and Kubernetes versions. topf decrypts the file in memory and fills `{{ .Data.secretDomain }}` in `.yaml.tpl` patches; plain `.yaml` patches are not templated. Flux's `cluster-secrets` substitution does not apply to Talos. Rendered configs (`just talos render-config` → `talos/output/`) contain the resolved domain and every cluster secret; the directory is gitignored.

   The group name must match between Authentik and the ClusterRoleBinding subject (`oidc:kubernetes-admins` after applying the groups prefix). No `required-claim` equivalent is used; the ClusterRoleBinding is the authorization guard for non-admin groups. To restrict authentication itself, add a CEL `claimValidationRules` entry to the JWT authenticator and test it against a real ID token.

   Subject-mode interaction: with Authentik "Subject mode: Based on the User's username" and `claim: preferred_username`, the OIDC username is `<auth-user-username>`. The binding in Phase 3 uses `Group`, not `User`, so this is fine, but a `User`-subject binding would need the `oidc:` prefix.

   Signing algorithm: the structured authenticator accepts the algorithms Authentik publishes in JWKS (RS256 by default); no separate flag is needed.

2. The certificate SANs in `talos/all/04-machine-certsans.yaml` (`127.0.0.1`, `192.168.30.10`) remain unchanged. **No change.** LAN-only access means no new SANs.

3. Review and apply the new config to each control plane. **Do NOT bootstrap Kubernetes.** topf renders each node's config in memory and shows the diff against the running config before applying:

   ```sh
   just talos diff-node k8s-01    # dry run: shows the diff, changes nothing
   just talos apply-node k8s-01   # shows the diff again and asks before applying
   ```

   Repeat one control plane at a time, waiting for that node and its apiserver to recover before proceeding. The diff must contain only the `KubeAuthenticationConfig` change and say "without a reboot". Etcd is not intentionally modified by this change, and the admin client certificate remains a separate authenticator. `just bootstrap` is not the right command here.

   **Never run `talosctl bootstrap`** on a node that's already part of a healthy cluster — that re-initializes etcd and destroys the cluster.

4. **Verify after each roll** (per node). The static-pod manifest on disk is not the same as a healthy running apiserver — if any flag value is malformed (e.g. a template placeholder left in a plain `.yaml` patch that topf does not template, or a `<secret-domain>` placeholder left from a partially-edited patch), the manifest still exists on disk but kube-apiserver is crashlooping. Run **all three**:

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
   - Write only to `kubeconfig-oidc` in the repo root (gitignored), and fail clearly if `op`, `kubectl`, or `kubectl oidc-login` fails.

   **Implemented:** `just bootstrap kubeconfig-oidc` in `bootstrap/mod.just`. The recipe takes one optional argument — the mode — and nothing else. The 1Password references are module-level variables (`oidc_issuer_ref`, `oidc_client_ref`), so they never appear on the command line:

   | Command | Sign-in flow |
   |---------|--------------|
   | `just bootstrap kubeconfig-oidc` | **The default.** The browser authorization-code flow on a machine that has a browser: kubelogin opens the browser on this machine and captures the callback on `127.0.0.1:8000` (falling back to `:18000`). On a machine with **no display** — a headless Linux box — it falls back to the device grant instead, because the browser flow cannot work there. |
   | `just bootstrap kubeconfig-oidc headless` | **The device authorization grant** (RFC 8628), explicitly. kubelogin prints a verification URL and a code to complete on another device. No callback listener, no tunnel, no stdin. Same result as the default on a headless host. |
   | `just bootstrap kubeconfig-oidc browser` | Forces the browser flow on a headless machine, for the `ssh -L 8000:127.0.0.1:8000` tunnel case. Rarely needed — the device grant works everywhere. |

   The default decides between the two grants by whether the host has a display: `DISPLAY` or `WAYLAND_DISPLAY` set means a browser can be opened, and the browser flow is used; on Linux with neither, the device grant is used and the recipe says so on stderr. The reason is that the browser flow fails in a confusing way on a headless host — kubelogin tries to listen on `127.0.0.1:8000` for the callback and either reports `bind: address already in use` or waits for a callback that can never arrive.

   | Field | Value |
   |-------|-------|
   | `op://Chezmoi/kubernetes/KUBERNETES_OIDC_ISSUER_URL` | The exact `issuer` from Authentik's discovery document, usually `https://auth.<domain>/application/o/kubernetes/` (trailing slash included). It must equal the `url` in `talos/control-plane/04-oidc.yaml.tpl` once rendered. Check with `curl -s <issuer>.well-known/openid-configuration \| jq -r .issuer`. |
   | `op://Chezmoi/kubernetes/KUBERNETES_OIDC_CLIENT_ID` | The Authentik provider's client ID (same value as the `audiences` entry in `04-oidc.yaml.tpl`). |

   The `kubernetes` item name is a choice; change the two variables in `bootstrap/mod.just` if you store the fields elsewhere. The recipe does not need the bootstrap `kubeconfig`: the API server URL comes from `clusterEndpoint` in `talos/topf.yaml`, and the cluster CA certificate (public part only) is decrypted with sops from the secrets bundle that `topf.yaml`'s `secretsPath` names (`talos/secrets.sops.yaml`), so the age key must be available.

   Do not run the original sample unchanged: its shell variables do not persist between lines, it leaves the VIP as a placeholder, it has no cluster CA, and it persists a client secret in exec arguments.

   Flag notes (cross-checked against [kubelogin usage.md](https://github.com/int128/kubelogin/blob/master/docs/usage.md)):
   - `--oidc-extra-scope` (with the `oidc-` prefix) — not `--extra-scope`. The unscoped form is silently ignored. Repeat the flag once per scope, do not comma-join values.
   - By default kubelogin tries `127.0.0.1:8000`, then `127.0.0.1:18000`. Explicitly setting `--listen-address=127.0.0.1:8000` replaces that list and disables the fallback. Register both redirect URIs if retaining the default list; otherwise register the single configured callback.
   - There is **no** `--callback-hostname` flag — the loopback callback host is derived from `--listen-address`.
   - `--grant-type` defaults to `auto`. In kubelogin v1.36.4 `auto` resolves to the browser **authcode** flow — it only switches to the password grant when `--username` is set, and it never falls back to device-code. So the recipe picks the grant itself: `authcode` on a host with a display, `device-code` (plus `--skip-open-browser`, so kubelogin does not try to launch a browser that does not exist) on a host without one. `just bootstrap kubeconfig-oidc browser` forces `authcode`; `headless` forces `device-code`.

   The recipe assumes `op` (1Password CLI) is on `$PATH` and signed in to the account that owns the `Chezmoi` vault. Desktop hosts use the 1Password desktop-app integration; native Linux hosts authenticate with a 1Password service account. The 1Password access model lives in the `mrdynamo/dotfiles` repo (the `onepassword.command` / `onepassword.mode: service` settings and the shell profile that exports the token), so every host resolves `op` the same way. Because that resolution happens through a **zsh alias** on WSL, the recipe body runs under `zsh -lic` rather than bash — the dotfiles stay the single source of truth for which CLI is used, and the recipe contains no machine-type checks. The bootstrap kubeconfig at `${REPO}/kubeconfig` is **not** touched.

   **No token in plaintext.** The recipe never selects kubelogin's `disk` storage — `~/.kube/cache/oidc-login/<sha256>` (dir `0700`, file `0600`) is plaintext JSON holding the **refresh token**, and anyone who reads it can mint fresh ID tokens and authenticate as `oidc:kubernetes-admins` → `cluster-admin` until it is revoked.

   The keyring is owned by the **dotfiles**, not by this repo. The recipe asks one helper where the token may go:

   ```sh
   oidc-token-cache   # prints "keyring" or "none", nothing else
   ```

   | Host | Storage | Where the token lives |
   |------|---------|----------------------|
   | macOS | `keyring` | macOS Keychain, unlocked by the login session |
   | Linux / WSL2, unlocked by `chezmoi update` | `keyring` | gnome-keyring, encrypted with the passphrase from 1Password |
   | Anything else, or a locked keyring | `none` | Nowhere — every `kubectl` call re-runs the sign-in |

   The recipe prints a notice when the storage is `none`, so a silent downgrade to a plaintext cache is not possible. The kubeconfig it writes holds no token and no secret — issuer URL, client ID, CA certificate and exec command only — and is installed `0600`.

   The `keyring` answer is not cosmetic: kubelogin stores the token in the login collection, and a failed write is **fatal** — the whole `kubectl` call aborts with `could not write the token cache`. A locked collection would therefore break every command, so the helper asks the Secret Service for the collection's `Locked` property and answers `none` when it is not `false`.

   ### The keyring lifecycle (dotfiles)

   `mrdynamo/dotfiles` is applied by chezmoi on every machine, and `chezmoi update` is the one command that leaves a machine ready:

   | File in `mrdynamo/dotfiles` | What it does |
   |---|---|
   | `home/run_always_after_30-keyring.sh.tmpl` | Makes the keyring available and unlocked. Runs on every apply. |
   | `home/dot_local/bin/executable_oidc-token-cache.tmpl` | `~/.local/bin/oidc-token-cache` — prints `keyring` or `none`. |
   | `home/dot_config/keyring/packages.{debian,ubuntu}.conf` | The pinned apt packages; Renovate bumps them through the `deb` datasource. |
   | `home/dot_config/zsh/env.zsh.tmpl` | Exports `DBUS_SESSION_BUS_ADDRESS`, so kubectl's exec plugin reaches the same Secret Service. |

   *How the pinned versions are kept current.* The pins are the versions the distributions install by default: on Ubuntu 24.04 that is the release and the `-updates` pocket (`46.1-2ubuntu0.2`, `1.14.10-4ubuntu4.1`, …), and on Debian 13 it is the release pocket (`48.0-1`, `1.16.2-2`, …). Renovate tracks them through the `deb` datasource with a custom regex manager in the dotfiles repository, and the Ubuntu rule follows the `-updates` and `-security` pockets as well, so a new point release arrives as a pull request. Two limits are worth knowing: the `deb` datasource only reads `Packages.gz`, and Debian publishes its security pocket as `Packages.xz` only — a **Debian** security update for one of these four packages is therefore *not* picked up automatically; and the pinned version is only used when the package is missing, so an installed package is never downgraded to a pin.

   It needs one 1Password item: **`op://chezmoi/gnome-keyring/PASSPHRASE`** (vault `chezmoi`, item `gnome-keyring`, password field `PASSPHRASE`). It holds the passphrase of the gnome-keyring *login keyring* only — not an OIDC token. The value is piped straight from the 1Password CLI into `gnome-keyring-daemon --unlock` on stdin; it is never written to a file and never appears in a process argument list.

   What `chezmoi update` does per host:

   | Host | What happens |
   |---|---|
   | macOS | Nothing is unlocked: the login keychain is unlocked by the login session. The script only checks that the keychain can be used, with a throwaway item that is written and deleted again. It never touches the items you have stored. |
   | Linux / WSL2 | Installs the pinned packages that are missing, makes sure a session bus exists, stops the systemd `gnome-keyring-daemon` units for this session, and unlocks the login keyring with the passphrase from 1Password. The install needs `sudo`: passwordless where the host is configured for it, otherwise the script asks for the password once on the terminal (`sudo -v`) and sudo caches it for the rest of the run. Without a terminal to ask on, it prints the `apt-get install` command instead of hanging. |

   Two details of the Linux path are why it is a script and not a one-liner:

   - **The daemon that owns `org.freedesktop.secrets` has to be the one that unlocks.** gnome-keyring requests the bus name without `REPLACE`, so a daemon that is already running — the systemd unit, or the one D-Bus activates on demand — keeps the name, leaves the collection **locked**, and `gnome-keyring-daemon --unlock` then does nothing. The script stops the systemd units and replaces a foreign owner before unlocking.
   - **A wrong passphrase is silent.** The daemon starts and owns the name, but the collection stays locked. The script checks the `Locked` property, not the exit code, and when the passphrase does not open the keyring that is on disk it moves that keyring aside (`login.keyring.bak-<timestamp>`) and lets `--unlock` create a fresh one. Nothing is ever deleted.

   The unlock applies to the running daemon, so it has to be redone whenever the daemon restarts. `chezmoi update` after a reboot is the intended way to do it — that is the command you already run on every machine. On WSL that means running it again after the distro has been shut down (`wsl --shutdown`, a Windows reboot, or a restart from the VS Code WSL extension): the encrypted `login.keyring` file survives the restart, but the daemon that holds the unlocked collection in memory does not.

   > **The systemd units are stopped, not disabled.** `gnome-keyring-daemon.service` and `gnome-keyring-daemon.socket` are stopped for the session, because that daemon owns the bus name with a locked collection. They come back at the next login, and the next `chezmoi update` stops them again. Make it permanent with `systemctl --user disable gnome-keyring-daemon.service gnome-keyring-daemon.socket` if a graphical session should never own the Secret Service name.

   **WSL.** WSL is not special-cased anywhere. The dotfiles decide which `op` runs (the alias `op='op.exe'` on WSL), and the keyring script uses the same Linux path as a native Linux host: gnome-keyring and dbus come from the pinned Ubuntu packages, and the session bus comes from the systemd user session — or from a private bus when WSL has no systemd, whose address is remembered in `~/.local/state/chezmoi/dbus-session-address` and exported by the shell profile.

   Two things are specific to WSL, and the same script handles both:

   - **The keyring is not installed natively.** WSL ships no gnome-keyring, so `chezmoi update` installs it. The install needs root and WSL's `sudo` asks for the password, so the **first `chezmoi update` on a WSL host prompts for the sudo password** — enter it once and the rest of the run needs no password again. Run it from a terminal; from a script, a CI job or a task runner with no terminal to ask on, the script prints the `apt-get install` command for you to run as root instead of hanging on a prompt nobody can see.
   - **The passphrase comes from the Windows 1Password app.** `op` is the alias for `op.exe`, so the passphrase is read through the Windows desktop app, which has to be running and unlocked. There is no 1Password service account on WSL, and none is needed. A locked Windows app makes the read fail; the script then says so and points at the app.

   *What the old recipe did.* The previous implementation selected kubelogin's storage like this:

   ```bash
   if [ "$(uname -s)" = Linux ] && [ -z "${GNOME_KEYRING_CONTROL:-}" ]; then
       token_cache_storage=disk
   else
       token_cache_storage=keyring
   fi
   ```

   `GNOME_KEYRING_CONTROL` is normally unset on WSL, so the old recipe selected `disk` there: the **refresh token was written in plaintext** to `~/.kube/cache/oidc-login/<sha256>` (directory `0700`, file `0600`), inside the distro's ext4.vhdx. That file is a complete cluster-admin credential — it can mint fresh ID tokens and authenticate as `oidc:kubernetes-admins` → `cluster-admin` until the refresh token is revoked. The current recipe never selects `disk`; the token goes to the keyring, or nowhere.

   *Where the keyring file lives.* gnome-keyring keeps it in `$XDG_DATA_HOME/keyrings/` — `~/.local/share/keyrings/login.keyring` on Linux and WSL. It is one encrypted file (`0600`), encrypted with the passphrase from 1Password, so a leaked file is not a cluster-admin credential.

   *Troubleshooting.*

   | Symptom | Cause | Fix |
   |---|---|---|
   | `No unlocked OS keyring` when generating the kubeconfig | The keyring was not unlocked in this session | `chezmoi update` |
   | `could not read op://chezmoi/gnome-keyring/PASSPHRASE` | The item does not exist, or 1Password is not signed in | Create the item, then `chezmoi update` |
   | `the login keyring could not be unlocked` | The passphrase does not open the keyring on disk | The script moves the stale keyring aside and retries; if it still fails, delete the `~/.local/share/keyrings/login.keyring.bak-*` files you no longer need |
   | `sudo needs a password and there is no terminal to ask on` | The packages are missing, `sudo` needs a password, and `chezmoi update` was not run from a terminal | Run the printed `apt-get install -y ...` command as root, then `chezmoi update` from a terminal |
   | `sudo needs a password; enter it to install the keyring packages` | The packages are missing on WSL and `sudo` asks for the password | Enter the sudo password — the install and the unlock then continue |
   | `could not write the token cache` from kubectl | The keyring was locked after the kubeconfig was generated | `chezmoi update`, then run the command again |
   | The device-code link opens a **blank white page** after logging in | The brand has no device code flow: `/device?code=…` answers 404 with an empty body | Create a `Stage Configuration` flow and set it as the brand's **Device code flow** (see Phase 1) |
   | The sign-in succeeds but `kubectl auth whoami` shows **no groups** | The ID token has no `groups` claim: no scope mapping on the provider produces one. The *scope name* `groups` is irrelevant — Authentik clamps the requested scopes to the configured scope names and the claim has to ride along with a scope that is granted | Check `claims_supported` in the discovery document; if `groups` is absent, add a scope mapping whose expression produces the claim (see Phase 1) |
   | The device code is rejected as expired | The device code lives for the provider's access code validity (one minute by default) | Complete the browser step within the window, or raise the provider's access code validity |

   *Verifying.* The helper answers with the storage the recipe would pick, `secret-tool search --all` lists the cached items, and the plaintext cache directory must not exist:

   ```sh
   oidc-token-cache                              # keyring
   secret-tool search --all                      # the cached kubelogin item
   ls ~/.kube/cache/oidc-login/                  # must not exist
   ```

   **Headless hosts.** The device authorization grant (RFC 8628) — no callback listener, no SSH tunnel, and no stdin needed. `just bootstrap kubeconfig-oidc` picks it by itself on a host with no display, so the plain command is enough:

   ```sh
   just bootstrap kubeconfig-oidc            # picks device-code here
   just bootstrap kubeconfig-oidc headless   # asks for it explicitly
   ```

   kubelogin prints a verification URL plus a code; open the URL in any browser — the laptop, the phone — approve it, and the token returns to the terminal over the device endpoint. Authentik supports this: `DEVICE_CODE` is one of the provider's grant types and the discovery document always advertises `device_authorization_endpoint`, so the only provider-side requirement is adding `urn:ietf:params:oauth:grant-type:device_code` to the provider's allowed grant types (see Phase 1).

   If you would rather keep the browser flow on a headless host, run `just bootstrap kubeconfig-oidc browser` and forward the callback port to the machine that has the browser — `ssh -L 8000:127.0.0.1:8000 <headless-host>` — and the provider's redirect to `http://localhost:8000` travels back through the tunnel. Both loopback URIs must be registered on the Authentik provider (see Phase 1). The keyboard variant (paste the authorization code back into the terminal) is not exposed by the recipe: kubelogin needs an explicit `--oidc-redirect-url` and a TTY for it.

   One caveat common to both flows: Authentik only issues refresh tokens when the `offline_access` scope is mapped on the provider. Without a refresh token the short-lived ID token expires and every command re-runs the flow — which is what `none` storage forces anyway, and what a keyring avoids.

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

   Also confirm the issuer and client ID are fully resolved in the rendered config, then delete the plaintext output:

   ```sh
   just talos render-config k8s-01
   grep -c -e '{{' -e '<secret-domain>' -e '<client-id>' talos/output/k8s-01.yaml   # must be 0
   rm -rf talos/output
   ```

3. **OIDC kubeconfig generation succeeds**:

   ```sh
   just bootstrap kubeconfig-oidc
   ```

   Should print the path and exit 0. On a host without a browser use `just bootstrap kubeconfig-oidc headless` instead.

4. **OIDC login works** (browser opens, Authentik challenges, returns token):

   ```sh
   KUBECONFIG=kubeconfig-oidc kubectl get nodes
   ```

   First invocation opens a browser to `auth.${SECRET_DOMAIN}/...`, you log in, kubelogin captures the redirect, kubectl returns the 6 nodes.

5. **Identity and group claims are correct** (check both an admin and, if available, a non-admin Authentik user):

   ```sh
   KUBECONFIG=kubeconfig-oidc kubectl auth whoami -o yaml
   ```

   `kubectl auth whoami` is included in the repository's pinned kubectl v1.37.1. An admin's output should have an `oidc:`-prefixed username and include `oidc:kubernetes-admins` and `system:authenticated` once. A non-admin may authenticate but must not receive the admin group.

6. **Verify RBAC**, not just authentication. An admin should be able to list secrets. If testing with a non-admin user, the same operation should return 403. The `oidc-required-claim` flag is not needed for this RBAC check.

### Rollback

Each phase is independently reversible:

- **Phase 4** (justfile recipe): delete the recipe. Nothing checked in.
- **Phase 3** (RBAC): `kubectl delete clusterrolebinding kubernetes-admins` or remove the file from Flux.
- **Phase 2** (Talos apiserver flags): remove the `KubeAuthenticationConfig` JWT entry from `talos/control-plane/04-oidc.yaml.tpl` and apply it with `just talos apply-node` to each control plane. The API server restarts without OIDC support. The bootstrap cert path is unaffected throughout.
- **Phase 1** (Authentik provider/application/group): UI deletion only. No cluster state to undo.
- **Phase 0**: no-op.

Before applying Phase 2, save the currently working, per-node Talos machine configs in a protected local location. `talosctl rollback` is an OS-installation rollback, not a configuration rollback; do not use it to restore apiserver flags.

Recovery sequence:

1. Use the Talos management API (or console/maintenance recovery if the API is unavailable) to re-apply the saved known-good config to the affected node with `talosctl apply-config`.
2. Verify that the kube-apiserver is healthy and the control plane has recovered before restoring any other affected nodes, one at a time.
3. Fix the patch, check it with `just talos diff-node <host>`, and retry a per-node `just talos apply-node <host>` only after the diff and recovery path have been checked.

The bootstrap kubeconfig (`KUBECONFIG=./kubeconfig kubectl ...`) remains valid when an apiserver is healthy because the admin client cert is unaffected by OIDC configuration. It cannot help if all apiservers are down.

---

## Critical Files

### Modified

- `talos/control-plane/04-oidc.yaml.tpl` — `KubeAuthenticationConfig` JWT authenticator; the domain comes from the encrypted `data.secretDomain` in `talos/topf.yaml`.
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
- Talos control-plane patches (documents): `talos/control-plane/`
- 1Password as the canonical secret store: every `*App`/`Catalog` value already routed through `ClusterSecretStore: onepassword`.

### Untouched (rescue posture)

- `kubeconfig` at the repo root — the bootstrap client-cert kubeconfig. Stays exactly as-is.
- `talosconfig` at the repo root (`just talos talosconfig`) — talosctl config unchanged.
- `talos/all/04-machine-certsans.yaml` — no new SANs needed (LAN-only).

### Not created (deferred to follow-ups, per scope decisions)

- No `kubeconfig.oidc.sops.yaml` checked in.
- No `cloudflared` route for the kube-apiserver.
- No TLSRoute / TCPRoute / cloudflared-in-cluster.
- No developer / viewer RBAC tiers.
- No separate `SelfSubjectReview` resource; `kubectl auth whoami` uses the API's SelfSubjectReview endpoint.
- No changes to Headlamp's still-commented-out OIDC block — that's a follow-up after Phase 5 verification lands.

---

## Conventions to Honour

- **Domain templating:** Flux substitution variables are not automatically available to local Just recipes or Talos config patches. Read the issuer from the `Chezmoi` 1Password item for the recipe and verify the generated Talos values. The item's `KUBERNETES_OIDC_ISSUER_URL` and `KUBERNETES_OIDC_CLIENT_ID` must stay equal to the rendered `url` and `audiences[0]` values in `talos/control-plane/04-oidc.yaml.tpl`; that patch is what the API server actually validates against, so a drift between the two produces a kubeconfig that authenticates nowhere.
- **Issuer URL must match Authentik discovery metadata** and be reachable from the control planes. The current Authentik HelmRelease uses the `external` gateway; do not configure an internal hostname unless that route and DNS path have been explicitly verified.
- **Flux substitution does not apply to Talos patches.** Resolve any domain or client-ID values before applying the Talos config, and check generated output for placeholders.
- **SOPS-encrypt any checked-in secret-bearing file.** The recipe in Phase 4 reads 1Password at runtime and writes the kubeconfig to `${HOME}` — nothing is committed, so no encryption needed for it.
- **OIDC configuration does not invalidate the existing admin client certificate**, but malformed values can still make kube-apiserver fail to start. Preserve and test the Talos recovery path before rollout.

---

## Placeholders Used in This Document

Some specifics have been abstracted with `<placeholder>` markers. Fill them in from your local repo when implementing:

| Placeholder | What it is | Where to find it |
| --- | --- | --- |
| `<control-plane-node-ip>` | IP of any control-plane node (k8s-01/02/03) | `talos/topf.yaml` `nodes[].ip` where `role: control-plane` |
| `<api-server-vip>` | HA VIP that fronts the kube-apiserver; currently `192.168.30.10` | `talos/topf.yaml` `clusterEndpoint` and `talos/control-plane/08-vip.yaml` |
| `<secret-domain>` | The hostname used in the Authentik issuer URL; confirm it against the discovery document | Authentik provider/application and DNS configuration |
| `<kubernetes>` | OIDC client ID (not secret — just the public identifier) | assigned by Authentik when the provider is created |
