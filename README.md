<div align="center">

# 🏠 Home Operations 🏠

🚧 _My homelab Kubernetes cluster managed with GitOps_ 🚧

[![Talos](https://kromgo.dynamiclab.org/badges/talos_version)](https://talos.dev)&nbsp;&nbsp;
[![Kubernetes](https://kromgo.dynamiclab.org/badges/kubernetes_version)](https://kubernetes.io)&nbsp;&nbsp;
[![Flux](https://kromgo.dynamiclab.org/badges/flux_version)](https://fluxcd.io)&nbsp;&nbsp;

</div>

<div align="center">

[![Age](https://kromgo.dynamiclab.org/badges/cluster_birth_age)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Uptime](https://kromgo.dynamiclab.org/badges/cluster_uptime_age)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Nodes](https://kromgo.dynamiclab.org/badges/cluster_node_count)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Pods](https://kromgo.dynamiclab.org/badges/cluster_pod_count)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![CPU](https://kromgo.dynamiclab.org/badges/cluster_cpu_usage)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Memory](https://kromgo.dynamiclab.org/badges/cluster_memory_usage)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Alerts](https://kromgo.dynamiclab.org/badges/cluster_alert_count)](https://github.com/home-operations/kromgo)

</div>

---

## 📖 Overview

This repository contains the infrastructure and applications for my personal homelab cluster. The entire system is managed as code using Infrastructure as Code (IaC) and GitOps principles with [Flux](https://github.com/fluxcd/flux2), [Renovate](https://github.com/renovatebot/renovate), and [GitHub Actions](https://github.com/features/actions).

The cluster is deployed on [Talos Linux](https://www.talos.dev/) and leverages modern cloud-native technologies to provide a declarative, self-healing infrastructure where the desired state is always defined in Git.

## ✨ Core Features

### Kubernetes & Container Orchestration

- **OS**: [Talos Linux](https://www.talos.dev/) - Immutable, minimal Kubernetes OS
- **Networking**: [Cilium](https://github.com/cilium/cilium) - eBPF-based container networking
- **Ingress**: [Gateway API](https://gateway-api.sigs.k8s.io/) with external and internal routing via [Cloudflare Tunnel](https://www.cloudflare.com/en-us/products/tunnel/)

### GitOps & Automation

- **GitOps**: [Flux CD](https://github.com/fluxcd/flux2) - Declarative infrastructure and application deployment
- **Dependency Management**: [Renovate](https://github.com/renovatebot/renovate) - Automated dependency updates with PRs
- **CI/CD**: [GitHub Actions](https://github.com/features/actions) - Workflow automation and testing

### Security & Secrets

- **Certificate Management**: [cert-manager](https://github.com/cert-manager/cert-manager) - Automated SSL/TLS certificates
- **Secrets Management**: [External Secrets](https://github.com/external-secrets/external-secrets) with [1Password](https://1password.com/) integration
- **Secret Encryption**: [SOPS](https://github.com/getsops/sops) - Encrypted secrets in Git

### Storage & Persistence

- **Distributed Storage**: [Longhorn](https://longhorn.io/) - Persistent volume management
- **NFS Storage**: Network-attached storage for media and backups
- **Volume Snapshots**: [Volsync](https://github.com/backube/volsync) - Backup and restore capabilities

### Applications

A wide array of self-hosted applications including media management (Plex, Radarr, Sonarr), productivity tools (Mealie, Paperless), and monitoring solutions.

## 🗂️ Repository Structure

```sh
📁 kubernetes/
├── 📁 apps/           # Applications organized by namespace
├── 📁 components/     # Reusable Kustomize components
└── 📁 flux/           # Flux system configuration
📁 talos/              # Talos Linux configuration
📁 bootstrap/          # Cluster bootstrap resources
📁 scripts/            # Utility scripts
```

## 🔄 GitOps Workflow

[Flux](https://github.com/fluxcd/flux2) automatically watches this repository and applies changes to the cluster based on the Git state. Application deployments are defined declaratively using Kubernetes manifests and Helm releases.

[Renovate](https://github.com/renovatebot/renovate) monitors the repository for dependency updates and automatically creates PRs. When merged, Flux applies the changes to the cluster.

## ⚙️ Hardware

| Device                      | Count | CPU Cores | Memory | Storage         | Purpose                 |
|-----------------------------|-------|-----------|--------|-----------------|-------------------------|
| Unifi UCG Ultra | 1 | - | - | - | Gateway/Router |
| Dell PowerEdge R730XD | 1 | 2x Intel Xeon E5-2690v4 @ 2.60 GHz | 192 GB | 2x 2 TB Enterprise SSD (RAID-1) | vSphere Hypervisor (Primary) |
| Dell PowerEdge R710 | 1 | 2x Intel Xeon E5-2649 @ 2.53 GHz | 96 GB | 1 TB Consumer SSD | vSphere Hypervisor (Secondary) |
| Control Planes (VMs) | 3     | 4 vCPU    | 6 GB   | 24 GB SSD       | Kubernetes control plane |
| Worker Nodes (VMs)                | 2     | 6 vCPU    | 32 GB  | 320 GB SSD      | Kubernetes workers      |
| Lenovo M90q | 1 | Intel i5-11500 | 16 GB | 512 GB NVMe | Kubernetes worker (iGPU)
| TrueNAS Core (VM) | 1 | 4 vCPU | 48 GB | 6x 8 TB HDD (RAID-Z2) | NAS - Bulk storage (NFS, SMB, Backups, etc) |

## 🙏 Acknowledgments

Special thanks to [onedr0p](https://github.com/onedr0p) for the excellent [cluster-template](https://github.com/onedr0p/cluster-template) that this repository is built upon.

Thanks to the [Home Operations](https://discord.gg/home-operations) community for their continuous support, shared knowledge, and inspiring homelab setups.

## 🙌 Related Projects

If this repo is too hot to handle or too cold to hold check out these following projects.

- [ajaykumar4/cluster-template](https://github.com/ajaykumar4/cluster-template) - _A template for deploying a Talos Kubernetes cluster including Argo for GitOps_
- [khuedoan/homelab](https://github.com/khuedoan/homelab) - _Fully automated homelab from empty disk to running services with a single command._
- [mitchross/k3s-argocd-starter](https://github.com/mitchross/k3s-argocd-starter) - starter kit for k3s, argocd
- [ricsanfre/pi-cluster](https://github.com/ricsanfre/pi-cluster) - _Pi Kubernetes Cluster. Homelab kubernetes cluster automated with Ansible and FluxCD_
- [techno-tim/k3s-ansible](https://github.com/techno-tim/k3s-ansible) - _The easiest way to bootstrap a self-hosted High Availability Kubernetes cluster. A fully automated HA k3s etcd install with kube-vip, MetalLB, and more. Build. Destroy. Repeat._

## ⭐ Stargazers

<div align="center">

<a href="https://star-history.com/#omrdynamo/home-ops&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=mrdynamo/home-ops&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=mrdynamo/home-ops&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=mrdynamo/home-ops&type=Date" />
  </picture>
</a>

</div>
