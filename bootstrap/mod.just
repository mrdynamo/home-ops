set positional-arguments := true
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

bootstrap_dir := justfile_dir() + '/bootstrap'
kubernetes_dir := justfile_dir() + '/kubernetes'
controller := `talosctl config info -o yaml | yq -e '.endpoints[0]'`
nodes := `talosctl config info -o yaml | yq -e '.nodes | join (" ")'`

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
kubeconfig-oidc issuer_ref="op://kubernetes-connect/kubernetes/KUBERNETES_OIDC_ISSUER_URL" client_ref="op://kubernetes-connect/kubernetes/KUBERNETES_OIDC_CLIENT_ID":
    # `[script('bash')]` runs the recipe as `bash <file>` — a fresh non-interactive
    # bash that does NOT source .bashrc. On WSL that breaks `op` because the
    # mrdynamo/dotfiles alias `op='op.exe'` (and the desktop-bridge auth context
    # it implies) only appears in interactive/login shells. `exec` replaces this
    # outer non-interactive bash with a login-interactive bash that sources the
    # same rc files the user's terminal does, leaving the dotfiles repo as the
    # single source of truth for what `op` resolves to.
    just log info "Generating OIDC kubeconfig..."
    exec bash -lic '
    set -euo pipefail
    out="{{ justfile_dir() }}/kubeconfig-oidc"
    issuer="$(op read "{{ issuer_ref }}")"
    client_id="$(op read "{{ client_ref }}")"
    server="$(yq -e ".endpoint" "{{ justfile_dir() }}/talos/talconfig.yaml")"
    [[ -n "$issuer" && -n "$client_id" && -n "$server" ]] || { echo "issuer, client ID or server is empty" >&2; exit 1; }
    tmp="$(mktemp -d)"; trap "rm -rf \"$tmp\"" EXIT
    # Public Kubernetes CA certificate only; the CA key in the same file is never read.
    sops -d --extract "[\"certs\"][\"k8s\"][\"crt\"]" "{{ justfile_dir() }}/talos/talsecret.sops.yaml" | base64 -d > "$tmp/ca.crt"
    [[ -s "$tmp/ca.crt" ]] || { echo "could not read the cluster CA from talsecret.sops.yaml" >&2; exit 1; }
    export KUBECONFIG="$tmp/kubeconfig"
    kubectl config set-cluster kubernetes --server "$server" --certificate-authority "$tmp/ca.crt" --embed-certs=true >/dev/null
    # kubelogin token cache: macOS uses the native Keychain via the keyring
    # backend. WSL needs gnome-keyring (freedesktop Secret Service) running —
    # which the mrdynamo/dotfiles repo starts in its bashrc — so the same
    # keyring backend works on both platforms. Linux without that daemon
    # falls back to a plain file cache.
    if [ "$(uname -s)" = Linux ] && [ -z "${GNOME_KEYRING_CONTROL:-}" ]; then
        token_cache_storage=disk
    else
        token_cache_storage=keyring
    fi
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
        --exec-arg="--token-cache-storage=$token_cache_storage" >/dev/null
    kubectl config set-context oidc@kubernetes --cluster kubernetes --user oidc --namespace default >/dev/null
    kubectl config use-context oidc@kubernetes >/dev/null
    install -m 600 "$tmp/kubeconfig" "$out"
    just log info "Wrote $out (try: kubectl auth whoami)"
    '

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
