---
title: Talos Configuration with topf
description: How the Talos machine configs are built and applied with topf and just, why the patches look the way they do, and how the talhelper migration was validated.
---

# Talos Configuration with topf

> **Status:** Migrated from talhelper + Taskfile to [topf](https://github.com/postfinance/topf) + `just` on 2026-10-26. Every node runs the config topf generates: `topf apply --dry-run` reports no changes on all six nodes.
>
> **Versions at migration:** Talos `v1.14.5`, Kubernetes `v1.37.1`, topf `0.6.2`.

The earlier version of this document was the upgrade and migration plan. Its plan-only parts (the Talos 1.13 → 1.14 bump, a full conversion to multi-document config, and file names that were never created) are superseded by what is described here.

---

## 1. Layout

```text
talos/
├── topf.yaml               # cluster, versions and nodes; the data: block is SOPS-encrypted
├── secrets.sops.yaml       # Talos secrets bundle (CAs, keys, tokens), SOPS-encrypted
├── schematics/*.yaml.j2    # Image Factory schematics; topf computes the IDs locally
├── all/                    # patches for every node
├── control-plane/          # patches for control planes
├── worker/                 # patches for workers
├── node/<host>/            # patches for one node
└── mod.just                # `just talos ...` recipes
```

topf applies the patch folders in that order (`all/` → role → `node/<host>/`), and the files inside each folder in name order. Patches are strategic merges.

- Files ending in `.yaml.tpl` are Go templates. They can use `.Node.Host`, `.Node.IP`, `.Node.Data.<key>`, `.Data.<key>` and `.KubernetesVersion`.
- Plain `.yaml` files, and the `.yaml.j2` schematics, are not templated.

### 1.1 `topf.yaml`

| Node | IP | Role | Schematic | Install disk |
| --- | --- | --- | --- | --- |
| `k8s-01` | `192.168.30.21` | control-plane | `control-base` | `/dev/sda` |
| `k8s-02` | `192.168.30.22` | control-plane | `control-base` | `/dev/sda` |
| `k8s-03` | `192.168.30.23` | control-plane | `control-base` | `/dev/sda` |
| `k8s-04` | `192.168.30.24` | worker | `worker-intel-gpu` (Intel UHD 750) | `/dev/nvme0n1` |
| `k8s-05` | `192.168.30.25` | worker | `worker-base` | `/dev/sda` |
| `k8s-06` | `192.168.30.26` | worker | `worker-gpu-lts-prop` (NVIDIA) | `/dev/sda` |

- **Per-node data.** Each node's `data:` holds its `mac` (used to pick the network link) and `installDisk`.
- **Encrypted values.** The top-level `data:` holds `secretDomain` (for the OIDC issuer) and `etcdSecretboxSecret`. Only those two keys are encrypted (the `talos/topf\.yaml$` rule in `.sops.yaml`). The rest of the file stays readable, so Renovate can bump the versions.
- **Secrets bundle.** `secretsPath: secrets.sops.yaml` points topf at the existing secrets bundle. topf decrypts it in memory with `SOPS_AGE_KEY_FILE`.
- **Versions.** `talosVersion` and `kubernetesVersion` carry `# renovate:` comments.
- **Installer image.** topf builds the install image as `factory.talos.dev/metal-installer/<schematic-id>:<talosVersion>`.
- **Schematics.** Each `schematicId: '@schematics/<name>.yaml.j2'` is hashed locally. A new or changed schematic has to reach the Image Factory once with `topf --submit-to-factory schematic-ids`.

---

## 2. Why the patches look the way they do

Talos 1.14 generates several multi-document defaults that differ from what the nodes ran under talhelper. The migration kept every running setting, so some patches exist only to undo or replace a generated default:

| Patch | Reason |
| --- | --- |
| `all/00-hostname.yaml.tpl` | topf's `host` is only a label; without `HostnameConfig` every node would be renamed `talos-xxx-xxx`. |
| `all/01-kubelet-v1alpha1.yaml` | Deletes the generated `KubeletConfig` and `KubeNodeConfig`. `KubeletConfig` has no `extraMounts` (the workers need the Longhorn bind mount), and Talos rejects both documents while any `.machine.kubelet`, `.machine.nodeLabels` or `.cluster.allowSchedulingOnControlPlanes` is set. The kubelet and labels therefore stay in the v1alpha1 form. |
| `all/03-cluster-network.yaml` | Replaces `KubeNetworkConfig` outright: list fields merge by appending, which would keep the `10.244.0.0/16` / `10.96.0.0/12` defaults next to `10.42.0.0/16` / `10.43.0.0/16`. Also deletes `KubeFlannelCNIConfig` (Cilium is the CNI). |
| `all/05-ephemeral-volume.yaml` | `mount.secure: false`: 1.14 defaults new `/var` volumes to `noexec`, which Longhorn v1 cannot use. |
| `all/06-security-profile.yaml` | `workloadIsolation: false`: 1.14 enables it for new configs, and iSCSI (Longhorn) needs it off. |
| `all/08-install-disk.yaml.tpl` | topf generates `UnattendedInstallConfig` with `/dev/sda`; k8s-04 installs to NVMe. |
| `control-plane/02-admission-control.yaml` | Deletes the generated `PodSecurity` admission config, as before. |
| `control-plane/03-etcd-encryption.yaml.tpl` | Replaces `KubeEtcdEncryptionConfig`. Existing secrets were encrypted with the secretbox key named `key2`, and the name is stored with every secret; the `identity` provider keeps any secret written before encryption was enabled readable. |
| `control-plane/07-machine-labels.yaml` | Restates `exclude-from-external-load-balancers`, which the deleted `KubeNodeConfig` would otherwise carry. |
| `worker/03-filesystem-trim.yaml` | Deletes the generated `FilesystemTrimConfig`. The workers never ran the weekly fstrim the control planes do; delete this file to opt in. |

Left out on purpose: talhelper's orphaned `node-volumes.yaml` (applying it would re-provision disks), the commented-out `oomconfig`, and the unused intel/nvidia/worker `machine-files.yaml` patches.

---

## 3. Recipes

topf reads `talos/topf.yaml` through `TOPFCONFIG` (set in `.mise.toml`), so it works from any directory. Recipes take the node's host name (`k8s-05`), not its IP.

| Recipe | What it does |
| --- | --- |
| `just talos diff-node <host>` | Dry run: shows the diff between the rendered and the running config. |
| `just talos apply-node <host> [topf flags]` | Applies with a diff and a confirmation prompt. Extra arguments go to `topf apply` (e.g. `--mode=staged`). |
| `just talos render-config [host]` | Renders configs to `talos/output/` (gitignored, plaintext with every secret; delete it after use). |
| `just talos talosconfig` | Writes the talosconfig to `$TALOSCONFIG` (repo-root `talosconfig`). |
| `just talos nodes` / `schematic-ids` | Node state / resolved schematic IDs. |
| `just talos upgrade-node <host>` | `topf upgrade` to `talosVersion`, powercycle reboot. Routine upgrades are done by Tuppr. |
| `just talos upgrade-k8s [version]` | `talosctl upgrade-k8s`, defaulting to `kubernetesVersion`. |
| `just talos reboot-node` / `shutdown-node` / `reset-node <host>` | Single-node lifecycle, each behind a `gum confirm`. |
| `just talos reset [full=true]` | Resets every node to maintenance mode. Destroys the cluster. |
| `just bootstrap` | Builds the cluster from scratch (section 4). |
| `just bootstrap kubeconfig-oidc` | OIDC kubeconfig; see [kubernetes-oidc-authentik.md](kubernetes-oidc-authentik.md). |
| `just kube reconcile` | `flux reconcile ks flux-system --with-source`. |

To change a patch: edit it, run `just talos diff-node <host>` for each affected node, then `just talos apply-node <host>` one node at a time (control planes last, the node holding the VIP last of all). Check that each diff says "without a reboot" before approving.

**`--nodes-filter` is a regular expression**, not a list. A comma-separated value such as `k8s-04,k8s-05` matches no node, and topf exits 0 without checking anything. Use `'^k8s-0[45]$'`. The match is not anchored, so `k8s-0` matches every node.

---

## 4. Bootstrap from scratch

`just bootstrap` runs these stages in order. Each one can also be run alone with `just bootstrap <stage>`:

1. **`preflight`** checks the CLIs, `.sops.yaml`, `topf.yaml`, the age key and `TALOSCONFIG`.
2. **`talos`** writes the talosconfig. On a new cluster with no secrets file, it first generates and SOPS-encrypts the bundle, and it stops if the result is not encrypted. It then runs `just talos apply-node` for each node.
   - topf connects to maintenance-mode nodes without credentials, installs Talos, and changes nothing on a node already running this config.
   - On a configured node whose config differs, it applies the change without asking.
3. **`k8s`** runs `talosctl bootstrap` on the first control plane until etcd reports `AlreadyExists`.
4. **`kubeconfig node`** writes the admin `kubeconfig` (retried until the API answers).
5. **`wait`, `namespaces`, `resources`** create namespaces and the `sops-age-pq-secret` / `onepassword-secret` from 1Password.
6. **`crds`, `apps`** apply the CRDs from `00-crds.yaml`, then `helmfile sync` installs Cilium, CoreDNS, cert-manager, external-secrets, 1Password, flux-operator and flux-instance.
7. **`kubeconfig`** refreshes the admin kubeconfig. Flux then reconciles the rest of the repo.

The bootstrap stages use the admin `kubeconfig`, because OIDC needs Authentik, which isn't running yet. Never run `just bootstrap` against a running cluster: `helmfile sync` would take over releases that Flux manages.

After a bootstrap on new hardware, commit the new `talos/secrets.sops.yaml` after checking it is encrypted (`head -3` shows `ENC[...]`). topf writes the bundle in plaintext if `sops encrypt` fails.

---

## 5. Upgrades and Renovate

- **Tuppr** (`kubernetes/apps/system-upgrade/tuppr/`) runs the Talos and Kubernetes upgrades. It reads and patches the installer image in `UnattendedInstallConfig`.
- **Keep `topf.yaml` in step with Tuppr's targets.** If Tuppr upgrades the nodes and `topf.yaml` still names the old version, the next `topf apply` sets each node's installer image back to that version. That changes only which image the next install or upgrade uses, not the running OS.
- **Renovate keeps them in step.** Each version in `topf.yaml` carries the same `# renovate:` comment as its Tuppr counterpart:
  - `talosVersion` and `TalosUpgrade`: `datasource=custom.talos-factory depName=siderolabs/talos`;
  - `kubernetesVersion` and `KubernetesUpgrade`: `datasource=docker depName=ghcr.io/siderolabs/kubelet`.

  Renovate updates one dependency in every file that uses it in a single PR, so each bump changes both files together. Keep the comments identical when editing either file.

---

## 6. How the migration was validated

1. **Schematic IDs.** topf computed the same four schematic IDs talhelper used.
2. **Full dry run.** `topf apply --dry-run` against all six live nodes made Talos compare the generated config with the running one. Every difference was the same setting moved into the newer document format:
   - `machine.install` → `UnattendedInstallConfig`. The installer path changed from `installer/` to `metal-installer/`, and `grubUseUKICmdline` is forced on by the installer when this document exists.
   - `kubePrism` → `KubePrismConfig`.
   - The cluster ID and secret → `DiscoveryIdentityConfig`.
   - The CA and service-account keys → their own documents.
   - Nameservers → `ResolverConfig`.
   - Document reordering.

   The one real change (weekly trim on the workers) was removed with `worker/03-filesystem-trim.yaml`.
3. **Spot checks.** Workers' `/var` mounted without `noexec`; CA and service-account key hashes identical; service-account issuer unchanged.
4. **Rollout.** Applied one node at a time: workers first, then k8s-01, k8s-02, and k8s-03 (the VIP holder and etcd leader). After each node: health, etcd status, static pods and `readyz`. No reboot, no etcd leader change, and the VIP never moved. A final cluster-wide dry run reported no changes on any node.

---

## 7. Files kept out of git

| File | Why |
| --- | --- |
| `talosconfig`, `kubeconfig`, `kubeconfig-oidc` (repo root) | Credentials, regenerated by recipes. |
| `talos/output/`, `/output/` | Rendered configs in plaintext, with every secret. `/output/` catches a bare `topf render` from the repo root. |
| `talos/*.iso` | Installer images from `just talos download-image`. |

---

## 8. References

- topf: <https://github.com/postfinance/topf> · docs: <https://postfinance.github.io/topf>
- topf migration guide: <https://postfinance.github.io/topf/main/migration-from-talhelper/>
- Talos changelog: <https://github.com/siderolabs/talos/blob/main/CHANGELOG.md>
- Image Factory: <https://factory.talos.dev>
- onedr0p/home-ops (justfile layout): <https://github.com/onedr0p/home-ops>
