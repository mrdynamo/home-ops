set positional-arguments := true
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

bootstrap_dir := justfile_dir() + '/bootstrap'
kubernetes_dir := justfile_dir() + '/kubernetes'
controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`
nodes := `talosctl config info -o yaml | yq -e '.nodes | join (" ")'`

# 1Password references for the OIDC kubeconfig. Both are public identifiers
# (issuer URL and public PKCE client ID), not secrets.
oidc_issuer_ref := "op://Chezmoi/kubernetes/KUBERNETES_OIDC_ISSUER_URL"
oidc_client_ref := "op://Chezmoi/kubernetes/KUBERNETES_OIDC_CLIENT_ID"

[private]
default: talos k8s (kubeconfig "node") wait namespaces resources crds apps kubeconfig

[doc('Install Talos')]
talos:
    just log info "Running stage..." "stage" "$0"
    for n in {{ nodes }}; do \
        if ! op=$(just talos apply-node "$n" --insecure 2>&1); then \
            if [[ "$op" == *"certificate required"* ]]; then \
                just log info "Talos already configured, skipping apply of config" "stage" "$0" "node" "$n"; \
                continue; \
            fi; \
            just log fatal "Failed to apply Talos configuration" "stage" "$0" "node" "$n" "output" "$op"; \
        fi; \
    done

[doc('Install Kubernetes')]
k8s:
    just log info "Running stage..." "stage" "$0"
    until op=$(talosctl -n "{{ controller }}" bootstrap 2>&1 || true) && [[ "$op" == *"AlreadyExists"* ]]; do \
        just log info "Kubernetes bootstrap in progress. Retrying in 5 seconds..." "stage" "$0"; \
        sleep 5; \
    done

[doc('Fetch kubeconfig')]
kubeconfig lb="cilium":
    just log info "Running stage..." "stage" "$0"
    if ! talosctl kubeconfig -n "{{ controller }}" -f --force-context-name main {{ justfile_dir() }}; then \
        just log fatal "Failed to fetch kubeconfig" "stage" "$0"; \
    fi
    if [[ "{{ lb }}" != "cilium" ]]; then \
        if ! kubectl config set-cluster main --server "https://{{ controller }}:6443"; then \
            just log fatal "Failed to set kubectl cluster server address" "stage" "$0"; \
        fi; \
    fi

[doc('Generate OIDC kubeconfig at kubeconfig-oidc in the repo root')]
[script('bash')]
kubeconfig-oidc mode="":
    # Two ways to run this recipe, and no other arguments:
    #
    #   just bootstrap kubeconfig-oidc            # the default: the browser
    #       authorization-code flow on a machine that has a browser, and the
    #       device authorization grant (RFC 8628) on one that has not.
    #
    #   just bootstrap kubeconfig-oidc headless   # the device authorization
    #       grant, explicitly. kubelogin prints a URL and a code to complete
    #       on another device. No callback listener, no tunnel, nothing to
    #       open.
    #
    #   just bootstrap kubeconfig-oidc browser    # force the browser flow on
    #       a headless machine, for the ssh -L 8000:127.0.0.1:8000 tunnel
    #       case. Rarely needed: the device grant works everywhere.
    #
    # `[script('bash')]` runs the recipe as `bash <file>` — a fresh non-interactive
    # bash that does NOT source .bashrc. `exec` replaces this outer bash with a
    # login-interactive zsh, so the recipe sees the same environment the
    # terminal does.
    #
    # zsh, not bash, and that matters: the 1Password CLI is selected per machine
    # type by the dotfiles repo (mrdynamo/dotfiles), which chezmoi applies
    # everywhere. On WSL that is the alias `op='op.exe'` (the 1Password desktop
    # app lives on Windows), on native Linux the service-account CLI, on macOS
    # the desktop integration. A zsh alias only applies in a zsh shell, so
    # running the recipe body under bash would silently use the wrong `op` on
    # WSL. Nothing here decides which CLI to call: the dotfiles do.
    #
    # The `kubernetes` item is read from the `Chezmoi` vault, not
    # `kubernetes-connect`: the latter holds the cluster-provisioning secrets
    # (1Password Connect token, SOPS age key) and is out of reach for the
    # headless Linux host, whose 1Password service account only has access to
    # `Chezmoi`. The OIDC issuer URL and client ID are public identifiers, so
    # the vault split costs nothing in confidentiality.
    #
    # No token is ever written to disk in plaintext. The token set goes to the
    # OS keyring (macOS Keychain, gnome-keyring, KWallet) when a Secret
    # Service is reachable, and is not persisted at all otherwise. kubelogin's
    # plaintext `disk` cache is never used.
    set -euo pipefail
    mode={{ quote(mode) }}
    case "$mode" in
        "")
            grant_type="auto"
            ;;
        headless)
            grant_type="device-code"
            ;;
        browser)
            grant_type="authcode"
            ;;
        *)
            echo "unknown mode: $mode (expected 'headless' or 'browser')" >&2
            exit 1
            ;;
    esac
    # The browser flow needs a browser on this host: kubelogin listens on
    # 127.0.0.1:8000 and waits for the callback. On a headless Linux box there
    # is no browser, and the failure is a confusing "could not listen: bind:
    # address already in use" or "no browser to open". So the default mode
    # falls back to the device grant there, which needs neither.
    if [[ "$grant_type" == "auto" ]] && [[ "$(uname -s)" == "Linux" ]] \
        && [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        grant_type="device-code"
        echo "no display on this host: using the device-code sign-in (same as 'just bootstrap kubeconfig-oidc headless')" >&2
    fi
    just log info "Generating OIDC kubeconfig..." "mode" "${mode:-default}" "grant" "$grant_type"
    command -v zsh >/dev/null 2>&1 || { echo "zsh not found: the recipe body runs under zsh so the dotfiles apply" >&2; exit 1; }
    export OIDC_GRANT_TYPE="$grant_type"
    exec zsh -lic "$(cat <<'OIDC_KUBECONFIG_SCRIPT'
    set -euo pipefail
    grant_type="$OIDC_GRANT_TYPE"
    out="{{ justfile_dir() }}/kubeconfig-oidc"
    # `op` is whatever the dotfiles make it: the Windows CLI on WSL, the
    # service-account CLI on native Linux, the desktop integration on macOS.
    # `tr -d "\r"` drops the CRLF the Windows build writes, which would
    # otherwise end up inside the issuer URL.
    issuer="$(op read "{{ oidc_issuer_ref }}" | tr -d "\r")"
    client_id="$(op read "{{ oidc_client_ref }}" | tr -d "\r")"
    server="$(yq -e ".endpoint" "{{ justfile_dir() }}/talos/talconfig.yaml")"
    [[ -n "$issuer" && -n "$client_id" && -n "$server" ]] || { echo "issuer, client ID or server is empty" >&2; exit 1; }
    # The device-code grant completes the sign-in on another device: this host
    # has no browser to open.
    skip_browser=""
    case "$grant_type" in
        device-code) skip_browser="--exec-arg=--skip-open-browser" ;;
    esac
    # Token storage. The plaintext `disk` cache is never used: the file holds a
    # usable refresh token, i.e. cluster-admin for whoever reads it.
    #
    # The keyring is owned by the dotfiles, not by this repo: `oidc-token-cache`
    # prints `keyring` when the OS keyring is available and unlocked, and
    # `none` otherwise. In that case nothing is persisted and every command
    # re-authenticates.
    token_cache_storage="$(oidc-token-cache 2>/dev/null || echo none)"
    case "$token_cache_storage" in
        keyring|none) ;;
        *) token_cache_storage=none ;;
    esac
    if [[ "$token_cache_storage" == "none" ]]; then
        echo "No unlocked OS keyring: no token is written to disk, but every kubectl call re-runs the sign-in." >&2
        echo "Run 'chezmoi update' to unlock the keyring - see docs/kubernetes-oidc-authentik.md." >&2
    fi
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    # Public Kubernetes CA certificate only; the CA key in the same file is never read.
    sops -d --extract "[\"certs\"][\"k8s\"][\"crt\"]" "{{ justfile_dir() }}/talos/talsecret.sops.yaml" | base64 -d > "$tmp/ca.crt"
    [[ -s "$tmp/ca.crt" ]] || { echo "could not read the cluster CA from talsecret.sops.yaml" >&2; exit 1; }
    export KUBECONFIG="$tmp/kubeconfig"
    kubectl config set-cluster kubernetes --server "$server" --certificate-authority "$tmp/ca.crt" --embed-certs=true >/dev/null
    kubectl config set-credentials oidc \
        --exec-api-version=client.authentication.k8s.io/v1 \
        --exec-interactive-mode=IfAvailable \
        --exec-command=kubectl \
        --exec-arg=oidc-login \
        --exec-arg=get-token \
        --exec-arg="--oidc-issuer-url=$issuer" \
        --exec-arg="--oidc-client-id=$client_id" \
        --exec-arg=--oidc-extra-scope=profile \
        --exec-arg=--oidc-extra-scope=email \
        --exec-arg=--oidc-extra-scope=groups \
        --exec-arg=--oidc-extra-scope=offline_access \
        --exec-arg="--token-cache-storage=$token_cache_storage" \
        --exec-arg="--grant-type=$grant_type" \
        ${skip_browser:+"$skip_browser"} >/dev/null
    kubectl config set-context oidc@kubernetes --cluster kubernetes --user oidc --namespace default >/dev/null
    kubectl config use-context oidc@kubernetes >/dev/null
    install -m 600 "$tmp/kubeconfig" "$out"
    just log info "Wrote $out (try: kubectl auth whoami)"
    OIDC_KUBECONFIG_SCRIPT
    )"

[doc('Wait for nodes to be not-ready')]
wait:
    just log info "Running stage..." "stage" "$0"
    if ! kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then \
        until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do \
            just log info "Nodes not available, waiting for nodes to be available. Retrying in 5 seconds..." "stage" "$0"; \
            sleep 5; \
        done \
    fi

[doc('Apply Kubernetes namespaces')]
namespaces:
    just log info "Running stage..." "stage" "$0"
    find "{{ kubernetes_dir }}/apps" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | while IFS= read -r ns; do \
        if ! kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply --server-side --field-manager flux-client-side-apply -f -; then \
            just log fatal "Failed to apply namespace" "stage" "$0" "namespace" "$ns"; \
        fi; \
    done

[doc('Apply Kubernetes resources')]
resources:
    just log info "Running stage..." "stage" "$0"
    if ! just template "{{ bootstrap_dir }}/resources.yaml.j2" | kubectl apply --server-side --field-manager flux-client-side-apply -f -; then \
        just log fatal "Failed to apply resources" "stage" "$0"; \
    fi;

[doc('Apply Helmfile CRDs')]
crds:
    just log info "Running stage..." "stage" "$0"
    if ! helmfile -f "{{ bootstrap_dir }}/helmfile.d/00-crds.yaml" template -q | yq ea -e 'select(.kind == "CustomResourceDefinition")' | kubectl apply --server-side --field-manager bootstrap --force-conflicts -f -; then \
        just log fatal "Failed to apply crds" "stage" "$0"; \
    fi;

[doc('Apply Helmfile Apps')]
apps:
    just log info "Running stage..." "stage" "$0"
    if ! helmfile -f "{{ bootstrap_dir }}/helmfile.d/01-apps.yaml" sync --hide-notes; then \
        just log fatal "Failed to sync helmfile" "stage" "$0"; \
    fi
