---
title: Talos 1.14.0 Upgrade & Justfile + Topf Bootstrap Architecture Plan
description: Phased upgrade plan for Talos 1.14.0 — version bump first on the existing talhelper/v1alpha1 config, followed by a separate Topf + ManagedConfig migration adopting onedr0p's justfile-driven bootstrap workflow, with per-node heterogeneous hardware schematics.
---

# Talos 1.14.0 Upgrade & Justfile + Topf Bootstrap Architecture Plan

> **Workflow Model:** [onedr0p/home-ops](https://github.com/onedr0p/home-ops) justfile stage architecture
> **Engine & Tooling (future state):** [postfinance/topf](https://github.com/postfinance/topf) (`0.6.0+`) executed directly from `justfile` recipes (no straight Jinja concatenation or manual `talosctl patch` loops)
> **Target Talos Upgrade:** `1.13.10` → `1.14.0`
> **Taskfile & Talhelper Status:** Kept for the version-bump PR; retired in a later PR once Topf is validated
> **Fleet Difference:** Unlike onedr0p's 3 identical nodes, our cluster has 6 nodes with heterogeneous hardware (3 control planes, 1 Intel UHD iGPU worker, 1 base worker, 1 NVIDIA GPU worker) with per-node schematic templates
> **Primary Invariant:** The from-scratch bootstrap process must deploy bare-metal nodes and automatically restore the entire cluster state via Flux without manual intervention, at every stage of this migration.

---

## 0. Recommended Path: Upgrade First, Migrate Later

Talos 1.14 is fully backward compatible with v1alpha1 config. None of the ManagedConfig/Topf/justfile work below is required to run 1.14 — it only becomes necessary once you choose to convert. Bundling a version bump with a tooling rewrite and a config-format rewrite makes failures hard to diagnose (which of the three changes broke bootstrap?), so this plan is split into independent, sequentially-shippable PRs:

| PR | Scope | Config format | Tooling | Risk |
| --- | --- | --- | --- | --- |
| **1** | Talos `1.13.10` → `1.14.0` version bump only | v1alpha1 (unchanged) | talhelper + Taskfile (unchanged) | Low — 2 new patches, no SHA changes needed; patches staged behind the OS upgrade |
| **2** | talhelper → Topf | v1alpha1 (unchanged, re-hosted) | Topf | Low — tooling only, output diffed against talhelper |
| **3** | Taskfile → justfile-only, onedr0p-style stages | v1alpha1 (unchanged) | Topf + `just` | Low — orchestration only |
| **4+** | Convert each v1alpha1 field to its ManagedConfig doc, one type per PR | ManagedConfig (incremental) | Topf + `just` | Low per-PR — one doc type at a time, `talosctl validate` gates each |

**PR 1 is the only one required right now.** Section 1 below gives the exact, standalone steps for PR 1; Sections 2–9 describe the target end-state (Topf + justfile + full ManagedConfig) for PRs 2+.

---

## 1. PR 1 — Talos 1.14.0 Version Bump (Do This First)

Scope: bump the Talos version only. No tooling change, no config-format change. Stays on `talhelper` + `Taskfile` + v1alpha1 patches.

### 1.1 Version bumps (3 files)

1. **[.mise.toml](/.mise.toml)** — bump the `talosctl` client:

   ```toml
   "aqua:siderolabs/talos" = "1.14.0"
   ```

2. **[talos/talenv.yaml](/talos/talenv.yaml)** — bump the cluster target:

   ```yaml
   talosVersion: v1.14.0
   ```

3. **[kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml](/kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml)** — mirror for the Tuppr rolling-upgrade controller:

   ```yaml
   spec:
     talos:
       version: v1.14.0
   ```

After editing `.mise.toml`, run `mise install` so your local `talosctl` matches the target version before generating/applying any config.

### 1.2 Add the two required compatibility patches (new files, applied later)

> **Sequencing note:** `mount.secure` on `VolumeConfig` and the `SecurityProfileConfig` document kind are new in Talos 1.14 — they don't exist in the 1.13.x machine config schema the nodes are currently running. Talos decodes each multi-doc config entry by registered `apiVersion`/`kind`; a node still running 1.13 has no decoder for `SecurityProfileConfig` and no `mount` field on its `VolumeConfig` type, so pushing these patches to a node **before** it's upgraded risks the apply being rejected outright (unknown kind) or silently dropped (unknown field) — neither is a state you want to depend on. **These patches are safe to add to the repo now, but must not be applied to any node until that node is already running Talos 1.14.0.** See §1.6 for the exact ordering.

They offset the two Talos 1.14 default changes that affect **freshly provisioned volumes / new clusters only** (already-running clusters keep prior behavior across the OS upgrade itself — see the callout in §1.6):

1. **Create `talos/patches/global/ephemeral-noexec.yaml`**:

   ```yaml
   apiVersion: v1alpha1
   kind: VolumeConfig
   name: EPHEMERAL
   mount:
     secure: false
   ```

2. **Create `talos/patches/global/security-profile.yaml`**:

   ```yaml
   apiVersion: v1alpha1
   kind: SecurityProfileConfig
   workloadIsolation: false
   ```

### 1.3 Register the new patches in `talconfig.yaml` (committed now, not yet applied)

Add both files to the existing global `patches:` list in [talos/talconfig.yaml](/talos/talconfig.yaml), **after** `machine-time.yaml` so they layer last. Registering them here only affects what `task talos:generate-config` *renders* locally — it does not push anything to any node by itself, so this is safe to merge alongside the version bump:

```yaml
# Global patches
patches:
  - "@./patches/global/machine-files.yaml"
  - "@./patches/global/machine-kubelet.yaml"
  - "@./patches/global/machine-logging.yaml"
  - "@./patches/global/machine-network.yaml"
  - "@./patches/global/machine-sysctls.yaml"
  - "@./patches/global/machine-time.yaml"
  - "@./patches/global/ephemeral-noexec.yaml"     # NEW — apply only after node is on 1.14 (§1.6)
  - "@./patches/global/security-profile.yaml"     # NEW — apply only after node is on 1.14 (§1.6)
  # - "@./patches/global/oomconfig.yaml" # https://github.com/siderolabs/talos/issues/12526
```

No changes needed to `controlPlane.patches:` or `worker.patches:` — these two are global (apply to all 6 nodes).

> Because both patches are now registered, running `task talos:generate-config` / `task talos:apply-node` against **any node still on 1.13.x** would render and push them prematurely. Don't run those tasks against the live cluster until §1.6 says the corresponding node has already been upgraded. This is purely a matter of *when you invoke* the apply step, not what's committed to git.

### 1.4 Installer SHAs — no changes needed

The schematic SHA in `talosImageURL: factory.talos.dev/installer/<sha>` is a **content hash of the schematic customization only** (system extensions + kernel args) — it is completely independent of the Talos version. Evidence from this repo:

- [talos/talconfig.yaml](/talos/talconfig.yaml)'s `talosImageURL` values carry **no version tag** at all; talhelper appends `talosVersion` as the image tag separately at render/apply time (`<installer>/<sha>:<talosVersion>`).
- [.renovate/talosFactory.json5](/.renovate/talosFactory.json5)'s custom manager regex (`factory\.talos\.dev\/[^/]+\/[^:]+:(?<currentValue>v\S+)`) only tracks the **version tag** on the rendered image reference — it never touches the SHA, because the SHA isn't a version-tracked value.
- Image Factory builds `factory.talos.dev/installer/<schematic-id>:<any-talos-version>` on demand from the same schematic; the same SHA is valid across Talos versions as long as the extension list and kernel args are unchanged.

Since this PR keeps the same 4 schematics (`control-base`, `worker-base`, `worker-intel-gpu`, `worker-gpu-lts-prop`) with unchanged extension lists, **none of the 6 `talosImageURL` SHAs need to change** for this version bump. Only `talosVersion` in `talenv.yaml` needs to move — talhelper resolves the correct `v1.14.0`-tagged image against the existing SHAs automatically.

### 1.5 Make `--mode=` opt-in in the Taskfile

**[.taskfiles/talos/Taskfile.yaml](/.taskfiles/talos/Taskfile.yaml)** — `talosctl apply-config --mode=reboot` was removed in 1.14; the `apply-node` task must not pass `--mode=` unless explicitly requested:

```yaml
  apply-node:
    desc: Apply Talos config to a node [IP=required]
    dir: '{{.TALOS_DIR}}'
    cmd: talhelper gencommand apply --node {{.IP}}{{if .MODE}} --extra-flags '--mode={{.MODE}}'{{end}} | bash
    vars:
      MODE: '{{.MODE | default ""}}'
    requires:
      vars: [IP]
    preconditions:
      - talosctl --nodes {{.IP}} get machineconfig
      - talosctl config info
      - test -f {{.TALOSCONFIG}}
      - which talhelper talosctl yq
```

Bootstrap itself is unaffected — it never passed `--mode=`.

### 1.6 Apply the changes — OS upgrade first, patches second

> **Why this order is safe:** per the Talos 1.14 changelog, both default changes only affect **newly provisioned** resources: "Talos 1.14 clusters now default the EPHEMERAL volume (`/var`) to `noexec` ... **Existing machines are not affected on upgrades.**" and workload isolation "Clusters upgraded from older versions do not have this document and therefore keep the previous (non-isolated) behavior until it is added — **upgrades change nothing on their own.**" So Tuppr can safely upgrade the OS on all 6 nodes to `v1.14.0` while they're still running their *current* (pre-patch) machine config — Longhorn keeps working exactly as it does today throughout the OS upgrade. The two new patches are needed only to protect against a **future** volume re-provisioning, node reset, or fresh bootstrap, not to survive this upgrade itself.

**Stage A — merge and let Tuppr upgrade the OS (no new patches pushed yet):**

1. Merge PR 1 with the version bumps (§1.1) and the `--mode=` fix (§1.5). The two new patch files and their `talconfig.yaml` registration (§1.2–§1.3) can be included in the same PR — they only affect local rendering, not any node, until you explicitly apply them.
2. Do **not** run `task talos:generate-config` / `task talos:apply-node` yet.
3. Let Tuppr's `TalosUpgrade` resource detect the `v1.14.0` target and roll the OS upgrade across all 6 nodes (control planes first, then workers), gated by its configured health checks (Volsync quiesced, Longhorn volumes non-degraded, CNPG healthy).
4. Confirm every node is running `v1.14.0` before proceeding:

   ```sh
   talosctl -n <ip> version --short
   # repeat for all 6 nodes, or:
   kubectl get nodes -o custom-columns=NAME:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion,OS:.status.nodeInfo.osImage
   ```

**Stage B — push the two compatibility patches, now that every node understands them:**

1. Regenerate all machine configs locally (now rendered by a 1.14-aware `talhelper`/`talosctl`, and every target node also runs 1.14):

   ```sh
   task talos:generate-config
   ```

2. Validate the rendered output before touching any node:

   ```sh
   talosctl validate --config talos/clusterconfig/kubernetes-k8s-01.yaml --mode metal
   # repeat for each of the 6 rendered configs
   ```

3. Apply node-by-node (all 6 nodes are already on 1.14, so order no longer matters for safety, but control-planes-first is still a reasonable default):

   ```sh
   task talos:apply-node IP=192.168.30.21   # k8s-01
   task talos:apply-node IP=192.168.30.22   # k8s-02
   task talos:apply-node IP=192.168.30.23   # k8s-03
   task talos:apply-node IP=192.168.30.24   # k8s-04
   task talos:apply-node IP=192.168.30.25   # k8s-05
   task talos:apply-node IP=192.168.30.26   # k8s-06
   ```

   No reboot is required for these two documents to take effect — `--mode=` defaults to no-reboot in 1.14 (§1.5), and both `VolumeConfig`/`SecurityProfileConfig` are applied live.

4. For a **from-scratch bootstrap** on new hardware, none of this staged ordering applies — a new node boots directly into 1.14 and picks up both patches from its very first `task talos` render, so Longhorn/iSCSI work correctly on first boot with no extra steps.

### 1.7 Verify

After Stage A (OS upgrade, before patches):

- `talosctl -n <any-node> version --short` reports `1.14.0` on all 6 nodes.
- Longhorn `instance-manager` pods are still `Running` and volumes still attached (`kubectl get volumes.longhorn.io -A`) — confirming the upgrade alone didn't regress anything.
- Tuppr's `TalosUpgrade` status shows `v1.14.0` reconciled with no failed health checks.

After Stage B (patches applied):

- `talosctl -n <any-node> get volumeconfigs.storage.talos.dev EPHEMERAL -o yaml` shows `mount.secure: false`.
- `talosctl -n <any-node> get securityprofileconfigs -o yaml` shows `workloadIsolation: false`.
- Longhorn `instance-manager` pods remain `Running` and volumes remain attached after the patch push (no restart-induced regression).
- `kubectl get nodes` shows all 6 `Ready=True`.

Once PR 1 is merged and both stages are verified stable on 1.14.0, proceed to PR 2 (Topf tooling migration) using the plan in Sections 2–9.

---

## 2. Executive Summary & Core Architectural Decisions (Target End-State)

### 2.1 Combining onedr0p's Justfile Workflow with Topf

This plan combines the clean, modular orchestration of **onedr0p's justfile bootstrap** with the power and native Talos 1.14 ManagedConfig support of **Topf**:

1. **Justfile-Only Orchestration**: All cluster tasks, maintenance operations, and the end-to-end bootstrap pipeline are defined in modular `justfile`s (`.justfile`, `talos/mod.just`, `bootstrap/mod.just`, `kubernetes/mod.just`). `Taskfile.yaml` and `.taskfiles/` are fully removed.
2. **Topf as the Talos Engine**: Instead of writing complex raw Jinja templates and calling `talosctl machineconfig patch` directly in bash, `just` calls `topf` commands:
   - `topf render`: Renders full machine configurations from `topf.yaml` and the layered patch directory tree (`all/`, `control-plane/`, `worker/`, `node/<host>/`).
   - `topf apply --auto-bootstrap`: Applies machine configs to bare nodes and triggers cluster etcd bootstrap automatically.
   - `topf kubeconfig`: Pulls the admin kubeconfig.
   - `topf upgrade` & `topf reset`: Manages node lifecycles with drain safety and modern upgrade APIs.
3. **Pure Talos 1.14 ManagedConfig Multi-Documents**: Configs are authored strictly in native Talos 1.14 multi-document YAMLs (`KubeAPIServerConfig`, `KubeletConfig`, `SysctlConfig`, `VolumeConfig`, `SecurityProfileConfig`, etc.), eliminating legacy v1alpha1 mutual-exclusion conflicts.
4. **Local Content-Addressed Schematic Hashing**: Topf natively computes Image Factory schematic IDs locally from `.yaml.tpl` schematic templates without requiring external API roundtrips during config generation.
5. **Integrated SOPS Encryption**: Secrets in `talos/secrets.yaml` are auto-decrypted by Topf using your Age PQ key.

---

## 3. Fleet Architecture & Heterogeneous Hardware Schematics

Our cluster consists of 6 nodes with distinct hardware profiles:

| Node | Role | IP Address | MAC Address | Install Disk | Hardware Profile & Extensions | Schematic Template |
| --- | --- | --- | --- | --- | --- | --- |
| `k8s-01` | `control-plane` | `192.168.30.21` | `00:50:56:9e:c7:a2` | `/dev/sda` | Intel CPU, vmtoolsd, ucode | `talos/schematics/control-base.yaml.tpl` |
| `k8s-02` | `control-plane` | `192.168.30.22` | `00:50:56:9e:b5:c8` | `/dev/sda` | Intel CPU, vmtoolsd, ucode | `talos/schematics/control-base.yaml.tpl` |
| `k8s-03` | `control-plane` | `192.168.30.23` | `00:50:56:9e:89:bb` | `/dev/sda` | Intel CPU, vmtoolsd, ucode | `talos/schematics/control-base.yaml.tpl` |
| `k8s-04` | `worker` | `192.168.30.24` | `84:a9:38:9d:b9:f3` | `/dev/nvme0n1` | Intel UHD 750 iGPU (`i915`, `mei`, `intel-ucode`) | `talos/schematics/worker-intel-gpu.yaml.tpl` |
| `k8s-05` | `worker` | `192.168.30.25` | `00:50:56:9e:7e:65` | `/dev/sda` | Worker Base (`iscsi-tools`, `nfsrahead`, `util-linux-tools`) | `talos/schematics/worker-base.yaml.tpl` |
| `k8s-06` | `worker` | `192.168.30.26` | `00:50:56:9e:e9:f1` | `/dev/sda` | NVIDIA GPU (NVIDIA driver extensions, `iscsi-tools`, `nfsrahead`) | `talos/schematics/worker-gpu-lts-prop.yaml.tpl` |

---

## 4. Topf Architecture & Directory Structure

```text
talos/
├── topf.yaml                      # Replaces talconfig.yaml & talenv.yaml
├── secrets.yaml                   # SOPS-encrypted Talos secrets (was talsecret.sops.yaml)
├── schematics/
│   ├── control-base.yaml.tpl         # Control plane extensions (intel-ucode, vmtoolsd)
│   ├── worker-base.yaml.tpl          # Worker base extensions (iscsi-tools, nfsrahead, util-linux)
│   ├── worker-intel-gpu.yaml.tpl     # Intel iGPU extensions (i915, mei, intel-ucode)
│   └── worker-gpu-lts-prop.yaml.tpl  # NVIDIA proprietary driver extensions
├── all/                           # ManagedConfig patches applied to ALL nodes
│   ├── 00-hostname.yaml.tpl          # HostnameConfig (templated by topf)
│   ├── 01-time.yaml                  # TimeServerConfig (162.159.200.1, 162.159.200.123)
│   ├── 02-sysctl.yaml                # SysctlConfig (inotify, rmem/wmem, ARP thresholds)
│   ├── 03-talos-api-access.yaml      # KubeTalosAPIAccessConfig (system-upgrade namespace, os:admin)
│   ├── 04-cri.yaml                   # CRICustomizationConfig (name: customization)
│   ├── 05-ephemeral-volume.yaml      # VolumeConfig EPHEMERAL with mount.secure: false (Longhorn v1 fix)
│   ├── 06-security-profile.yaml      # SecurityProfileConfig with workloadIsolation: false (iSCSI fix)
│   ├── 07-logging.yaml               # Logging destination (fluent-bit UDP)
│   └── 08-kubelet.yaml               # KubeletConfig (featureGates) & KubeNodeConfig (validSubnets)
├── control-plane/                 # Control plane specific ManagedConfig patches
│   ├── 01-apiserver.yaml             # KubeAPIServerConfig (enable-aggregator-routing, feature-gates)
│   ├── 02-admission.yaml             # KubeAdmissionControlConfig ($patch: delete PodSecurity)
│   ├── 03-controller-manager.yaml    # KubeControllerManagerConfig
│   ├── 04-scheduler.yaml             # KubeSchedulerConfig
│   ├── 05-etcd.yaml                  # EtcdConfig (heartbeats, election, metrics on 2381)
│   ├── 06-disable-components.yaml    # KubeProxyConfig, KubeCoreDNSConfig, KubeFlannelCNIConfig delete
│   ├── 07-discovery.yaml             # DiscoveryServiceConfig & DiscoveryIdentityConfig
│   ├── 08-watchdog.yaml              # WatchdogTimerConfig (/dev/watchdog0)
│   └── 09-vip.yaml                   # Layer2VIPConfig (192.168.30.10)
├── worker/                        # Worker specific ManagedConfig patches
│   ├── 01-labels.yaml                # KubeNodeConfig (descheduler, Longhorn disk labels)
│   ├── 02-kubelet-mounts.yaml        # KubeletConfig extraMounts (/var/lib/longhorn bind)
│   └── 03-volumes.yaml               # VolumeConfig EPHEMERAL disk provisioning + UserVolumeConfig longhorn
├── node/                          # Per-node hardware / interface patches
│   ├── k8s-01/
│   │   └── 01-hardware.yaml.tpl      # UnattendedInstallConfig (/dev/sda) + network interface (MAC match)
│   ├── k8s-02/
│   │   └── 01-hardware.yaml.tpl      # UnattendedInstallConfig (/dev/sda) + network interface (MAC match)
│   ├── k8s-03/
│   │   └── 01-hardware.yaml.tpl      # UnattendedInstallConfig (/dev/sda) + network interface (MAC match)
│   ├── k8s-04/
│   │   ├── 01-hardware.yaml.tpl      # UnattendedInstallConfig (/dev/nvme0n1) + network interface
│   │   ├── 02-watchdog.yaml          # WatchdogTimerConfig
│   │   └── 03-udev.yaml              # UdevRulesConfig (renderD* drm group 44)
│   ├── k8s-05/
│   │   └── 01-hardware.yaml.tpl      # UnattendedInstallConfig (/dev/sda) + network interface
│   └── k8s-06/
│       ├── 01-hardware.yaml.tpl      # UnattendedInstallConfig (/dev/sda) + network interface
│       ├── 02-kernel-modules.yaml    # KernelModuleConfig (nvidia, nvidia_uvm, nvidia_drm, nvidia_modeset)
│       └── 03-sysctl.yaml            # SysctlConfig (net.core.bpf_jit_harden: 1)
└── mod.just                       # Talos management recipes (wraps topf)
```

### 4.1 `talos/topf.yaml`

```yaml
clusterName: kubernetes
clusterEndpoint: https://192.168.30.10:6443
talosVersion: v1.14.0
kubernetesVersion: v1.36.4
additionalApiServerCertSans:
  - "127.0.0.1"
  - "192.168.30.10"
additionalMachineCertSans:
  - "127.0.0.1"
  - "192.168.30.10"
clusterPodNets:
  - "10.42.0.0/16"
clusterSvcNets:
  - "10.43.0.0/16"
nodes:
  - host: k8s-01
    ip: 192.168.30.21
    role: control-plane
    schematicId: "@schematics/control-base.yaml.tpl"
  - host: k8s-02
    ip: 192.168.30.22
    role: control-plane
    schematicId: "@schematics/control-base.yaml.tpl"
  - host: k8s-03
    ip: 192.168.30.23
    role: control-plane
    schematicId: "@schematics/control-base.yaml.tpl"
  - host: k8s-04
    ip: 192.168.30.24
    role: worker
    schematicId: "@schematics/worker-intel-gpu.yaml.tpl"
  - host: k8s-05
    ip: 192.168.30.25
    role: worker
    schematicId: "@schematics/worker-base.yaml.tpl"
  - host: k8s-06
    ip: 192.168.30.26
    role: worker
    schematicId: "@schematics/worker-gpu-lts-prop.yaml.tpl"
```

---

## 5. Talos Management Justfile (`talos/mod.just`)

Instead of bespoke scripts or Taskfiles, `talos/mod.just` wraps `topf`:

```just
set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

talos_dir := source_directory()

[doc('Render Talos machine configurations to output/')]
render-config *args:
    topf render {{ args }}

[confirm('Apply Talos config [y|N] ?')]
[doc('Apply Talos config to cluster or specific node')]
apply *args:
    topf apply {{ args }}

[confirm('Upgrade Talos [y|N] ?')]
[doc('Upgrade Talos version on nodes')]
upgrade *args:
    topf upgrade {{ args }}

[confirm('Reset nodes back to maintenance mode [y|N] ?')]
[doc('Reset cluster nodes')]
reset *args:
    topf reset {{ args }}

[doc('Show live node status')]
nodes:
    topf nodes

[doc('Fetch cluster kubeconfig')]
kubeconfig *args:
    topf kubeconfig {{ args }}
```

---

## 6. Justfile-Only Bootstrap Architecture (`bootstrap/mod.just`)

The entire bootstrap sequence mirrors onedr0p's stage progression, powered under the hood by `topf`:

```sh
just bootstrap cluster
```

### 6.1 Bootstrap Stage Progression (`bootstrap/mod.just`)

```just
set default-list
set default-script
set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

controller := `talosctl config info -o yaml | yq -r -e '.endpoints[0]'`
nodes := `talosctl config info -o yaml | yq -r -e '.nodes | join (" ")'`

[confirm('Bootstrap cluster? [y|N]')]
[doc('Bootstrap a Talos & Kubernetes cluster end-to-end')]
cluster: talos k8s (kubeconfig "node") base apps kubeconfig

[private]
talos:
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    # Generate secrets if not present, then apply config and trigger auto-bootstrap
    [ -f "{{ source_directory() }}/../talos/secrets.yaml" ] || topf secrets --confirm=false | sops --filename-override talos/secrets.yaml --encrypt /dev/stdin > "{{ source_directory() }}/../talos/secrets.yaml"
    topf apply --insecure --auto-bootstrap

[private]
k8s:
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    until op=$(talosctl -n "{{ controller }}" bootstrap 2>&1 || true) && [[ "$op" == *"AlreadyExists"* ]]; do
        just log info "Kubernetes bootstrap in progress. Retrying in 5 seconds..." "stage" "{{ recipe_name() }}"
        sleep 5
    done

[private]
kubeconfig lb="cilium":
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    if ! topf kubeconfig; then
        just log fatal "Failed to fetch kubeconfig" "stage" "{{ recipe_name() }}"
    fi
    if [[ "{{ lb }}" != "cilium" ]]; then
        if ! kubectl config set-cluster main --server "https://{{ controller }}:6443"; then
            just log fatal "Failed to set kubectl cluster server address" "stage" "{{ recipe_name() }}"
        fi
    fi

[private]
api-ready:
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    for n in {{ nodes }}; do
        until [[ "$(curl -ks -o /dev/null -w '%{http_code}' --connect-timeout 2 "https://${n}:6443/readyz")" == "200" ]]; do
            just log info "Waiting for kube-apiserver. Retrying in 5 seconds..." "stage" "{{ recipe_name() }}" "node" "$n"
            sleep 5
        done
    done

[private]
nodes-ready:
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    if ! kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
            just log info "Nodes not available, waiting for nodes to be available. Retrying in 5 seconds..." "stage" "{{ recipe_name() }}"
            sleep 5
        done
    fi

[private]
base: api-ready nodes-ready
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    # Apply namespaces
    find "{{ source_directory() }}/../kubernetes/apps" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | while IFS= read -r ns; do
        kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply --server-side --field-manager flux-client-side-apply -f -
    done
    # Apply SOPS Age PQ & 1Password bootstrap secrets
    just template "{{ source_directory() }}/resources.yaml.j2" | kubectl apply --server-side --field-manager flux-client-side-apply -f -
    # Apply extracted CRDs
    helmfile -f "{{ source_directory() }}/helmfile.d/00-crds.yaml" template -q | yq ea -r -e 'select(.kind == "CustomResourceDefinition")' | kubectl apply --server-side --force-conflicts -f -

[private]
apps:
    just log info "Running stage..." "stage" "{{ recipe_name() }}"
    if ! helmfile -f "{{ source_directory() }}/helmfile.d/01-apps.yaml" sync --hide-notes; then
        just log fatal "Failed to sync helmfile" "stage" "{{ recipe_name() }}"
    fi
```

---

## 7. Bare-Metal Scratch Bootstrap & Automated Flux Restoration

The end-to-end scratch bootstrap executes through `just bootstrap cluster`:

```text
[just bootstrap cluster]
  1. talos:
     - Topf creates SOPS-encrypted talos/secrets.yaml (if absent)
     - Topf renders ManagedConfig documents per node & computes schematic IDs
     - Topf applies machine configs to bare nodes (--insecure) & triggers etcd bootstrap
  2. k8s:
     - Confirms etcd cluster initialization
  3. kubeconfig ("node"):
     - Topf downloads admin kubeconfig (points temporarily to direct controller IP)
  4. base:
     - Waits for apiserver /readyz & node registration (Ready=False)
     - Creates Kubernetes namespaces
     - Injects Age PQ key & 1Password secrets
     - Applies upstream CRDs via Helmfile (00-crds.yaml)
  5. apps:
     - Syncs foundational bootstrap releases (01-apps.yaml):
       * Cilium CNI v1.20.1 (eBPF routing, kube-proxy replacement, BGP / VIP pool)
       * CoreDNS v1.47.1
       * cert-manager v1.21.2
       * external-secrets operator v2.10.0 + 1Password
       * flux-operator & flux-instance v0.60.0
  6. kubeconfig (final):
     - Refreshes kubeconfig to permanent VIP endpoint (https://192.168.30.10:6443)
        │
        ▼
[Flux Automatic Cluster State Restoration]
  1. flux-instance connects to GitHub repo and synchronizes root kustomizations
  2. Storage: Longhorn v1 initializes cleanly (mount.secure: false & workloadIsolation: false)
  3. Databases: CNPG & Dragonfly restore persistent databases
  4. Workloads: All application pods across all namespaces reconcile to Ready=True
```

---

## 8. Migration & Implementation Plan

### Phase 1: Tooling Modernization (`.mise.toml` & Taskfile Retirement)

1. **Update `.mise.toml`**:
   - Add `"aqua:postfinance/topf" = "0.6.0"`.
   - Bump `"aqua:siderolabs/talos"` to `"1.14.0"`.
   - Remove `"aqua:budimanjojo/talhelper"` and `"aqua:go-task/task"`.
2. **Retire Taskfiles**:
   - Delete `Taskfile.yaml`, `.taskfiles/bootstrap/Taskfile.yaml`, and `.taskfiles/talos/Taskfile.yaml`.
3. **Update Root `.justfile`**:
   - Add module imports for `bootstrap`, `kubernetes`, and `talos`.

### Phase 2: Topf Structure & ManagedConfig Patch Authoring

1. Author `talos/topf.yaml` targeting `talosVersion: v1.14.0` and `kubernetesVersion: v1.36.4`.
2. Convert schematic definitions into Go-templates (`talos/schematics/*.yaml.tpl`).
3. Rename `talos/talsecret.sops.yaml` to `talos/secrets.yaml`.
4. Create layered ManagedConfig documents under `talos/all/`, `talos/control-plane/`, `talos/worker/`, and `talos/node/`.
5. Update `talos/mod.just` with topf wrappers.

### Phase 3: Bootstrap Justfile Standardization

1. Standardize `bootstrap/mod.just` to run the complete `cluster` recipe (`talos` -> `k8s` -> `kubeconfig` -> `base` -> `apps` -> `kubeconfig`).
2. Update Tuppr rolling upgrade CR (`kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml`) to `version: v1.14.0`.

### Phase 4: Validation & Execution

1. **Static & Dry-Run Validation**:
   - Run `just talos render-config` and inspect output in `output/`.
   - Validate with `talosctl validate -m metal`.
   - Run `just talos apply --dry-run` on live nodes.
2. **Rolling Upgrade**:
   - Upgrade control plane nodes (`k8s-01` -> `k8s-03`) via `just talos upgrade`.
   - Upgrade worker nodes (`k8s-04` -> `k8s-06`) via `just talos upgrade` / Tuppr.
3. **Scratch Bootstrap Test**:
   - Verify `just bootstrap cluster` completes from scratch and Flux restores all cluster applications.

---

## 9. Upstream Sources & References

- onedr0p/home-ops Reference Repository: <https://github.com/onedr0p/home-ops>
- Topf Repository: <https://github.com/postfinance/topf>
- Topf Migration Guide: <https://postfinance.github.io/topf/main/migration-from-talhelper/>
- Talos 1.14.0 Changelog: <https://github.com/siderolabs/talos/blob/main/CHANGELOG.md>
- Talos 1.14 Documentation: <https://www.talos.dev/v1.14/>
- Image Factory: <https://factory.talos.dev>

