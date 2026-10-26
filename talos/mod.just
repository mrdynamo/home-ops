set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

talos_dir := justfile_dir() + '/talos'
topf_config := talos_dir + '/topf.yaml'
# Read from topf.yaml, not the talosconfig: on a fresh machine there is no talosconfig yet.
controller := shell('yq -e "[.nodes[] | select(.role == \"control-plane\")][0].ip" "$1"', topf_config)

export TOPFCONFIG := topf_config

# Recipes take the node's host name from topf.yaml (k8s-01), not its IP.

[private]
default:
    just -l talos

[doc('Apply Talos config to a node')]
apply-node node *args: secrets
    topf --nodes-filter "^{{ node }}$" apply {{ args }}

[doc('Show the config changes apply-node would make, without applying them')]
diff-node node:
    topf --nodes-filter "^{{ node }}$" apply --dry-run || [[ $? -eq 2 ]]

[doc('Download Talos machine image')]
download-image version schematic:
    gum spin --title "Downloading Talos {{ version }} ..." -- \
    curl -sSLo "{{ talos_dir }}/talos-{{ version }}-{{ replace_regex(schematic, '^(.{8}).*', '$1') }}.iso" \
        --retry 5 --retry-delay 5 \
        "https://factory.talos.dev/image/{{ schematic }}/{{ version }}/metal-amd64.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "{{ schematic }}"

[doc('Show the schematic ID of every node')]
schematic-ids:
    topf schematic-ids

[doc('List nodes and their state')]
nodes:
    topf nodes

[doc('Reboot a node')]
reboot-node node:
    gum confirm "Reboot node {{ node }}?" --default="No" && \
        talosctl -n "$(just talos node-ip {{ node }})" reboot -m powercycle || exit 0

[doc('Render Talos config for a node')]
render-config node: secrets
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; \
    topf --nodes-filter "^{{ node }}$" render --output "$tmp" >/dev/null && cat "$tmp/{{ node }}.yaml"

[doc('Reset a node')]
reset-node node:
    gum confirm "Reset node {{ node }}?" --default="No" && \
        topf --confirm=false --nodes-filter "^{{ node }}$" reset --graceful=false || exit 0

[doc('Shutdown a node')]
shutdown-node node:
    gum confirm "Shutdown node {{ node }}?" --default="No" && \
        talosctl -n "$(just talos node-ip {{ node }})" shutdown --force || exit 0

[doc('Write the talosconfig to $TALOSCONFIG')]
talosconfig: secrets
    mkdir -p "$(dirname "$TALOSCONFIG")"
    topf talosconfig > "$TALOSCONFIG"

[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "{{ controller }}" upgrade-k8s --to {{ version }}

[doc('Upgrade Talos on a node to the talosVersion in topf.yaml')]
upgrade-node node:
    topf --nodes-filter "^{{ node }}$" upgrade --reboot-mode powercycle

[private]
node-ip node:
    yq -e '.nodes[] | select(.host == "{{ node }}") | .ip' "{{ topf_config }}"

# topf generates the secrets bundle on first use and writes it in plaintext when
# `sops encrypt` fails. Never carry on with a bundle that is not encrypted.
[private]
secrets:
    file="{{ talos_dir }}/$(yq '.secretsPath // "secrets.yaml"' "{{ topf_config }}")"; \
    [[ -f "$file" ]] || topf --confirm=false secrets >/dev/null; \
    yq -e 'has("sops")' "$file" &>/dev/null || { just log fatal "Secrets bundle is not SOPS-encrypted" "file" "$file"; exit 1; }
