set positional-arguments := true
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

bootstrap_dir := justfile_dir() + '/bootstrap'
kubernetes_dir := justfile_dir() + '/kubernetes'
topf_config := justfile_dir() + '/talos/topf.yaml'
# Read from topf.yaml, not the talosconfig: on a fresh machine there is no talosconfig yet.
controller := shell('yq -e "[.nodes[] | select(.role == \"control-plane\")][0].ip" "$1"', topf_config)
nodes := shell('yq -e ".nodes[].host" "$1" | xargs', topf_config)

# The bootstrap runs before Authentik exists, so it uses the admin kubeconfig, never kubeconfig-oidc.
export KUBECONFIG := justfile_dir() + '/kubeconfig'

[private]
default: preflight talos k8s (kubeconfig "node") wait namespaces resources crds apps kubeconfig

[private]
preflight:
    for cli in topf talosctl sops yq kubectl helmfile minijinja-cli gum; do \
        command -v "$cli" &>/dev/null || { just log fatal "Missing required CLI" "stage" "$0" "cli" "$cli"; exit 1; }; \
    done
    for f in "{{ justfile_dir() }}/.sops.yaml" "{{ topf_config }}" "${SOPS_AGE_KEY_FILE:-}"; do \
        [[ -f "$f" ]] || { just log fatal "Missing required file" "stage" "$0" "file" "${f:-SOPS_AGE_KEY_FILE unset}"; exit 1; }; \
    done
    [[ -n "${TALOSCONFIG:-}" ]] || { just log fatal "TALOSCONFIG is not set" "stage" "$0"; exit 1; }

[doc('Install Talos')]
talos:
    just log info "Running stage..." "stage" "$0"
    just talos talosconfig
    # topf connects insecurely to nodes in maintenance mode and applies nothing to a node
    # that already runs this config. No node is Ready until Cilium is installed.
    for n in {{ nodes }}; do \
        if ! TOPF_CONFIRM=false just talos apply-node "$n" --allow-not-ready --skip-post-apply-checks; then \
            just log fatal "Failed to apply Talos configuration" "stage" "$0" "node" "$n"; \
            exit 1; \
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
    until talosctl kubeconfig -n "{{ controller }}" -f --force-context-name main {{ justfile_dir() }} &>/dev/null; do \
        just log info "Kubeconfig not available yet. Retrying in 5 seconds..." "stage" "$0"; \
        sleep 5; \
    done
    if [[ "{{ lb }}" != "cilium" ]]; then \
        if ! kubectl config set-cluster "$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')" --server "https://{{ controller }}:6443"; then \
            just log fatal "Failed to set kubectl cluster server address" "stage" "$0"; \
        fi; \
    fi

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
