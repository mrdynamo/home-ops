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

[doc('Generate OIDC kubeconfig at kubeconfig-oidc.yaml in the repo root')]
[script('bash')]
kubeconfig-oidc issuer_ref="op://kubernetes-connect/kubernetes/KUBERNETES_OIDC_ISSUER_URL" client_ref="op://kubernetes-connect/kubernetes/KUBERNETES_OIDC_CLIENT_ID":
    set -euo pipefail
    for bin in op kubectl kubectl-oidc_login; do
        command -v "$bin" >/dev/null || { echo "missing required binary: $bin" >&2; exit 1; }
    done
    src="{{ justfile_dir() }}/kubeconfig"
    out="{{ justfile_dir() }}/kubeconfig-oidc.yaml"
    issuer="$(op read "{{ issuer_ref }}")"
    client_id="$(op read "{{ client_ref }}")"
    server="$(kubectl --kubeconfig "$src" config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
    [[ -n "$issuer" && -n "$client_id" && -n "$server" ]] || { echo "issuer, client ID or server is empty" >&2; exit 1; }
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    kubectl --kubeconfig "$src" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$tmp/ca.crt"
    [[ -s "$tmp/ca.crt" ]] || { echo "no cluster CA found in $src" >&2; exit 1; }
    export KUBECONFIG="$tmp/kubeconfig"
    kubectl config set-cluster main --server "$server" --certificate-authority "$tmp/ca.crt" --embed-certs=true >/dev/null
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
        --exec-arg=--token-cache-storage=keyring >/dev/null
    kubectl config set-context oidc --cluster main --user oidc >/dev/null
    kubectl config use-context oidc >/dev/null
    install -m 600 "$tmp/kubeconfig" "$out"
    echo "Wrote $out (try: KUBECONFIG=$out kubectl auth whoami)"

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
