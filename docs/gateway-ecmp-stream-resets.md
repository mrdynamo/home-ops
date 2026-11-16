---
title: Gateway Stream Resets (UCG Ultra Fast Path vs BGP ECMP)
description: Why long-lived HTTPS streams through the Cilium Gateways are reset about every 5 minutes, the evidence that pins it on the UniFi gateway's fast path disagreeing with its own ECMP route, and the options to fix it while keeping ECMP.
---

# Gateway Stream Resets (UCG Ultra Fast Path vs BGP ECMP)

> **Status (2026-11-16): Fixed by turning off Hardware Acceleration on the UCG Ultra** (UniFi Network UI setting; ECMP unchanged). Root cause identified with packet captures on the client, the router, and the nodes.
>
> **Verified 2026-11-16 13:41–13:59** with acceleration off and ynoTV back on the Gateway FQDN: ynoTV and two parallel `curl` streams through `.201` all stayed up across four reset marks (13:42, 13:47, 13:52, 13:57). The `curl` streams ran their full 17.6 min (~880 MB each, ended only by `--max-time`); mpv logged no curl failures, rebuffers, or reconnects. Before the change, every one of those marks reset all of them.
>
> **Interim workaround (no longer needed):** ynoTV pointed at the Dispatcharr LoadBalancer IP (`http://192.168.30.112:9191`), verified 13:03–13:30 across five marks.
>
> **Watch:** router CPU and inter-VLAN throughput now that every routed packet takes the kernel path (§6.1 trade-offs). If acceleration gets re-enabled (firmware update, reset, setting change), the resets will return; the pod-based Gateway (§6.2) is the router-independent fix.

---

## 1. Symptom

- Dispatcharr channels played in **ynoTV** (Windows desktop, mpv sidecar) stopped, rebuffered, and restarted repeatedly. TiviMate and AerioTV looked fine.
- Dispatcharr logs showed overlapping client connections from the desktop (shown as `TiviMate/4.6.0` because ynoTV spoofs that user agent), channels being stopped and re-initialised, and client connections that stayed "connected" long after ynoTV had moved on.
- mpv's log showed `[curl] transfer failed: Failure when receiving data from the peer` before most reconnects.

## 2. Root cause (summary)

| | |
|---|---|
| **What breaks** | Every long-lived, high-volume TCP connection through a **Cilium Gateway** (`192.168.30.201`–`.204`) is reset about every 5 minutes (observed at hh:m2:14–19 / hh:m7:14–19 on 2026-11-16). |
| **Why** | The router (UniFi Cloud Gateway Ultra) has three equal-cost BGP paths to each LoadBalancer IP (k8s-04, k8s-05, k8s-06). Its kernel route decision sends a given client's flows to one node, but its **fast path** (Qualcomm ECM/SFE, which forwards established flows without the Linux network stack) periodically sends packets of that flow to a **different** node. |
| **Why that kills the connection** | The Cilium Gateway terminates TCP in the **node-local** `cilium-envoy`. The node that receives the misrouted packets has no socket for the flow, so its kernel answers with RSTs. The original node never learns the client is gone and keeps retransmitting (and keeps the Dispatcharr upstream open) until TCP gives up. |
| **Why other paths survive** | Plain LoadBalancer Services (Dispatcharr's `192.168.30.112`) use **maglev + DSR**: any node picks the same backend pod and the pod replies directly, so a flow that moves between nodes still reaches the same socket. |
| **Why it looked client-specific** | Only long, active streams are hit (a reset needs a packet to arrive during the misrouted window). ynoTV shows every reset as a visible reconnect; other players most likely recover silently. TiviMate uses the direct LB IP and is not affected at all. |

The BGP/FRR configuration is **not** at fault: the route was stable for 2d23h, all three neighbours stayed `REACHABLE`, and no route, nexthop, or neighbour events occurred at any reset (§4.6).

## 3. Topology

| Item | Value |
|---|---|
| Router | UniFi Cloud Gateway Ultra (Qualcomm IPQ5322, 4× Cortex-A53 @ 1.5 GHz), ASN 65100, `192.168.30.1` on the server-VLAN bridge |
| Cluster BGP | Cilium BGP control plane, ASN 65200, peering from worker nodes only (`kubernetes/apps/kube-system/cilium/app/bgp.yaml`); control-plane nodes are listed in the FRR config but never establish |
| ECMP on router | `maximum-paths 3`, `bgp bestpath as-path multipath-relax`; nexthop group `nhid 92` = `.26/.24/.25` |
| Router hashing | `net.ipv4.fib_multipath_hash_policy = 0` (L3: src/dst IP), `net.ipv4.fib_multipath_use_neigh = 0` |
| Cilium LB | `kubeProxyReplacement: true`, `loadBalancer.algorithm: maglev`, `loadBalancer.mode: dsr`, `routingMode: native` |
| Gateways | `gatewayClassName: cilium` — `internal` (`.201`), `external` (`.202`), `external-cf` (`.203`), `external-vps` (`.204`) in `kubernetes/apps/kube-system/cilium/gateway/` |
| Node MACs (server VLAN) | k8s-04 `84:a9:38:9d:b9:f3` (.24), k8s-05 `00:50:56:9e:7e:65` (.25), k8s-06 `00:50:56:9e:e9:f1` (.26) |
| Client | Windows desktop on a separate client VLAN, routed to the server VLAN via the UCG |

## 4. Investigation and evidence

### 4.1 First pass: Dispatcharr and ynoTV settings

Dispatcharr `proxy_settings` at the start: `buffering_timeout: 15`, `channel_shutdown_delay: 0`, `new_client_behind_seconds: 5`, `redis_chunk_ttl: 60`.

- The provider feed has real 10–14 s gaps (`Stream unhealthy ... no data for 13.7s`). With `buffering_timeout: 15` Dispatcharr never failed over for them. **Changed to `10`** (by the user).
- `channel_shutdown_delay: 0` tears the channel down the instant the last client leaves, so every ynoTV reconnect re-initialised the provider stream. **Left at 0 by choice** (only ynoTV was affected).
- These explained some rebuffering but not the reconnect pattern. The 5-minute resets (§4.3) are the main cause.

ynoTV settings applied: stall detection timeout 10 → 30 s, event-based reconnect off, `--network-timeout=30`. Two ynoTV bugs found along the way are in §7.

### 4.2 Ruled out early

| Suspect | Result |
|---|---|
| Router BGP session flaps | All three worker sessions up 70–147 h |
| Router L2 announcements | Not used (`l2announcements.enabled: false`; one stale lease from January) |
| HTTP/2 | The internal Gateway negotiates HTTP/1.1 only |
| Envoy timers / Gateway itself | An in-cluster stream through `.201` (from the Dispatcharr pod, `--resolve` to `.201`) ran 200 s across a reset mark without error |
| VPN / filtering software on the desktop | None active in the traffic path |
| ynoTV / mpv | A plain `curl` from WSL on the same desktop was reset at the same instants (§4.3) |

### 4.3 The 5-minute resets (A/B tests from the desktop)

Streams of the same channel (`/live/.../221.ts`) run in parallel:

| Mark | ynoTV (FQDN) | `curl` via FQDN (`.201`) | `curl` direct LB (`.112:9191`) | `curl` in-cluster via `.201` |
|---|---|---|---|---|
| 12:07:14 | reset | reset at 12:07:14 | survived | – |
| 12:12:14 | reset | reset at 12:12:15 | survived (8 min run, ended by `--max-time`) | – |
| 12:17:14 | reset at 12:17:17 | reset at 12:17:18 | – | survived |
| 12:37:14 | reset at 12:37:18 | 2 streams reset at 12:37:18.9 | – | – |

Earlier ynoTV drops the same day: 11:42:14, 11:47:16, 11:52:23, 11:57:14, 12:02:14 — wall-clock aligned, across two separate mpv processes.

### 4.4 Desktop packet capture (headers only, Npcap/dumpcap)

At 12:22:19 the desktop received a burst of RSTs from `192.168.30.201:443` with **TTL 63** (one hop behind the router) and **IP ID 0** — kernel-generated RSTs answering packets for a connection with no socket. Afterwards the *original* sender kept retransmitting (12:22:20, :22, :25, :32, :45, 12:23:12, exponential backoff), i.e. the owning node never saw the reset.

### 4.5 Node-side socket snapshots

Read from `/proc/net/tcp` in the `cilium-envoy` pods (host network) every ~5 s. Addresses are little-endian hex (e.g. `.201:443` is `C91EA8C0:01BB`); filter on the client's IP encoded the same way.

- All of the desktop's connections to `.201` (streams and idle keep-alives) were on **k8s-06**; its connections to `.202` were on k8s-05. Consistent with the router's L3 hash.
- At **12:37:20** three k8s-06 sockets (one stream with 1.6 MB queued, two light connections) started retransmitting at the same moment: the desktop's ACKs stopped arriving.
- Leftover sockets from earlier resets sat on k8s-06 for many minutes (e.g. 1.2 MB unsent, 10 retransmits), matching the "ghost" clients in Dispatcharr.

### 4.6 Router capture (the decisive data)

Collected on the UCG with `tcpdump` on the server-VLAN bridge, `ip -ts monitor neigh nexthop route`, and `conntrack -E` for 11 minutes (12:34–12:45).

| Finding | Detail |
|---|---|
| No control-plane trigger | No route, nexthop, or neighbour events for `.24/.25/.26` at 12:37 or 12:42 |
| Fast path in use | tcpdump on the server-VLAN bridge saw **4,373 packets in 11 min**; conntrack counted 17–20 k client packets and 58 k server packets (79–86 MB) **per test stream**. Established flows bypass the Linux stack. |
| Kernel path → k8s-06 | Every client→`.201` packet the CPU handled went to k8s-06's MAC |
| **Misrouted packets → k8s-05** | At **12:37:18.9**, **k8s-05** (`00:50:56:9e:7e:65`) sent bursts of RSTs *as `192.168.30.201`* for connections owned by k8s-06 (ports 51562, 51568, 59190, then 59223, 59195 at 12:37:22). k8s-05 can only do that if the router delivered those flows' packets to it — via the fast path, since the kernel path never did. |
| Conntrack | Normal lifecycle (`ESTABLISHED` → `CLOSE` at 12:37:18.93 → `DESTROY`); no `[OFFLOAD]` flag is exposed by this firmware |

Router info at capture time: `nft` not installed, no IPS (Suricata) process visible in the process list.

## 5. Why the direct LB path survives

| | Cilium Gateway (`.201`) | Dispatcharr LB Service (`.112`) |
|---|---|---|
| Where TCP terminates | `cilium-envoy` on the node that receives the packet (host network, BPF/TPROXY redirect to the **local** proxy) | The Dispatcharr pod |
| Packet arrives at another node mid-flow | That node has no socket → kernel RST | maglev picks the same backend pod on every node; packet is forwarded there |
| Return traffic | From the owning node's Envoy | DSR: straight from the pod |
| Result when the router moves a flow | Connection reset | Connection survives |

## 6. Fix options (all keep ECMP)

### 6.1 Router: stop the fast path from re-pathing flows

**UI options (unverified for UCG Ultra):**

- UniFi Network 10.5.x added a **Hardware Acceleration** option, documented for the UDM Beast; a later note says it is validated "only when Smart Queues or QoS are enabled". Check **Settings → Routing** and the gateway's advanced settings for it on the current Network version.
- Indirect: enabling **Smart Queues** (Settings → Internet → WAN) has been reported to disable acceleration (UCG Fiber report). Not confirmed for UCG Ultra or for inter-VLAN traffic.

**Confirm first (runtime only, reverts on reboot).** On the UCG:

```sh
lsmod | grep -iE 'ecm|sfe|nss|flow_table'
ls /sys/kernel/debug/ecm/ 2>/dev/null
# If ECM is present: stop new acceleration and flush accelerated flows
echo 1 > /sys/kernel/debug/ecm/front_end_ipv4_stop
echo 1 > /sys/kernel/debug/ecm/ecm_db/defunct_all
# Revert: echo 0 > /sys/kernel/debug/ecm/front_end_ipv4_stop   (or reboot)
```

Paths follow Qualcomm's `qca-nss-ecm` and may differ on UniFi firmware. With ECM paused, rerun the stream test across two 5-minute marks (§8). No resets = confirmed.

**Trade-offs of disabling acceleration:**

| Area | Impact |
|---|---|
| Router CPU | Every routed packet (WAN and inter-VLAN) takes the full kernel path |
| Throughput | Rated 1 Gbps with IDS/IPS, and that limit reportedly applies to LAN-to-LAN routing; LAN ports are 1 GbE, so likely little change for typical use |
| Latency/jitter | Slightly higher under load; negligible at streaming bitrates |
| Heavy inter-VLAN flows | Media, Longhorn/NFS backups, replication between VLANs now cost router CPU |
| Scope | Global; no per-flow exemption |
| Smart Queues route | Also caps WAN at the configured rate (~90–95% of line) and adds CPU, in exchange for less bufferbloat |
| SSH changes | Unsupported; lost on reboot/firmware/provision — testing only |

**Also:** report to Ubiquiti — "ECMP BGP route with `fib_multipath_hash_policy=0`; fast-path-forwarded flow is sent to a different nexthop than the kernel route decision about every 5 minutes, with no route/neighbour change; TCP-terminating backends reset."

### 6.2 Cluster: pod-based Envoy behind a maglev/DSR LoadBalancer

Make Gateway connections independent of which node the router picks, the same way the Dispatcharr LB Service already is.

**Design:** use a Gateway API implementation that runs Envoy as a Deployment behind a `type: LoadBalancer` Service (e.g. Envoy Gateway). Cilium then load-balances to the Envoy pods with BGP ECMP from all nodes + maglev + DSR. A flow moved by the router still lands on the same Envoy pod.

**Rollout outline:**

1. Add the controller (HelmRelease), a `GatewayClass`, and an `EnvoyProxy` config: Service `type: LoadBalancer` with `lbipam.cilium.io/ips`, `externalTrafficPolicy: Cluster`, 2–3 replicas spread across nodes, PodDisruptionBudget, resources per `home-ops` sizing rules.
2. Pilot: a test Gateway on a free pool IP, a second HTTPRoute for Dispatcharr, rerun the 5-minute test (§8).
3. Migrate one Gateway at a time by changing only `gatewayClassName` (and moving the IP), keeping names and namespaces. The 61 HTTPRoutes reference `kube-system/internal` etc. by name, so they need no edits. Order: `internal`, `external-vps`, `external`, `external-cf`.
4. Verify per Gateway: HTTPRoute timeouts (Dispatcharr uses 12 h), WebSockets (Dispatcharr UI, Grafana), client IPs (DSR preserves source IP; `DISPATCHARR_TRUSTED_PROXIES` already covers `10.42.0.0/16`), external-dns and gatus annotations, certificates.

The current Gateways use plain HTTP/HTTPS listeners with certificate secrets only — no TLSRoute/GRPCRoute or Cilium Envoy config resources — so the migration is mostly mechanical.

**Trade-offs:** one more controller plus Envoy pods to run and keep updated; Envoy Gateway images are on docker.io (check for a ghcr.io mirror first); Hubble loses HTTP-level flow visibility for gateway traffic; rolling Envoy pods drops connections on the replaced pod (same as restarting `cilium-envoy` today; mitigate with connection draining). In return, Gateway connections no longer depend on router behaviour.

### 6.3 Client workaround (in place)

Point streaming clients at the LB IP directly (`http://192.168.30.112:9191`), as TiviMate does. In ynoTV, changing the source URL is not enough: the stored channel URLs must be refreshed by re-syncing the source.

### 6.4 Rejected

- **Single path / `maximum-paths 1`, or local-preference to prefer one node for the Gateway IPs.** Fixes it, but gives up having all nodes accept connections.

## 7. ynoTV findings (separate from the root cause)

- **`--cache*` params are dropped when Time Shift is on.** The frontend passes `--cache=yes`; the backend removes every custom param that *starts with* `--cache` (`packages/app/src-tauri/src/lib.rs`, prefix match without `=`), so `--cache-pause-initial` / `--cache-pause-wait` never reach mpv. Workaround: put them in `%LOCALAPPDATA%\ynoTV\mpv\mpv.conf` (mpv reads it; the filter cannot strip it), or turn Time Shift off.
- **Watchdog fires ~1 s into any rebuffer.** The idle check `(coreIdle || idleActive) && !madeProgress` treats mpv's paused-for-cache state as idle and ignores the stall timeout (`packages/ui/src/hooks/usePlayback.ts`).
- **mpv uses libcurl for HTTP** in this build; its retry path only covers seekable streams, so a dropped live stream becomes EOF. `--stream-lavf-o=reconnect*` has no effect unless `--curl-enabled=no` is set (and repeated `--stream-lavf-o=` lines overwrite each other; use `--stream-lavf-o-append=`).
- Logs: `%LOCALAPPDATA%\com.ynotv.app\logs\ynotv.log`, `%APPDATA%\com.ynotv.app\mpv.log` (rotates to `mpv.1.log` on each mpv start). Settings: `%APPDATA%\com.ynotv.app\.settings.dat`.

## 8. How to rerun the test

From WSL on the desktop, run a stream through the Gateway and one direct, across at least two hh:m2:14 / hh:m7:14 marks:

```sh
URL='https://dispatcharr.${INTERNAL_SECRET_DOMAIN}/live/<user>/<pass>/221.ts'   # fill in
curl -sS -o /dev/null --max-time 660 -w 'exit=%{exitcode} secs=%{time_total} err=%{errormsg}\n' "$URL" &
curl -sS -o /dev/null --max-time 660 -w 'exit=%{exitcode} secs=%{time_total} err=%{errormsg}\n' \
  "$(echo "$URL" | sed -E 's#https://[^/]+#http://192.168.30.112:9191#')" &
wait
```

Pass: both end with `exit=28` (hit `--max-time`). Fail: the Gateway stream ends early with `exit=56 ... Connection reset by peer`.

Router-side evidence collection (read-only, 11 min, headers only):

```sh
D=/tmp/ecmpdiag; rm -rf $D; mkdir -p $D; cd $D
timeout 660 tcpdump -i <server-bridge> -n -s 128 -w gw.pcap 'host <client-ip> and host 192.168.30.201 and tcp port 443' 2>tcpdump.err &
timeout 660 ip -ts monitor neigh nexthop route > monitor.txt 2>&1 &
timeout 660 conntrack -E -p tcp --orig-src <client-ip> --orig-dst 192.168.30.201 -o timestamp > conntrack.txt 2>&1 &
wait; tar czf /tmp/ecmpdiag.tgz -C /tmp ecmpdiag
```

In the pcap, RSTs from `192.168.30.201` whose source MAC is not the node holding the connection are the signature of this problem.

## 9. Open items

- [x] Confirm the fast path is the cause — confirmed by turning Hardware Acceleration off in the UniFi UI (2026-11-16); resets stopped.
- [x] Decide: router acceleration off (done 2026-11-16).
- [ ] Watch UCG CPU / inter-VLAN throughput with acceleration off; re-check after UniFi firmware updates that the setting stays off.
- [ ] Optional: pod-based Gateway (§6.2) as a router-independent fix.
- [ ] Optional: report to Ubiquiti (§6.1) and file the two ynoTV bugs (§7).
- [ ] Optional: verify AerioTV is also reset (stream across a mark and watch Dispatcharr for a reconnect from that client).

## Sources

- [UniFi Network Application 10.5.67 release notes](https://community.ui.com/releases/UniFi-Network-Application-10-5-67/375288b9-a4b4-46f1-a19d-5c787d342c2b)
- [UniFi OS – Cloud Gateways 5.0.12](https://community.ui.com/releases/UniFi-OS-Cloud-Gateways-5-0-12/cc83d900-1a8e-4844-a5c6-cfedc03c988d)
- [UCG Fiber Hardware Acceleration Issue (Ubiquiti Community)](https://community.ui.com/questions/73ae432a-a09b-48eb-8d4b-073818d98c5c)
- [Why Your Ubiquiti EFG Can't Push 25 Gbps Inter-VLAN (gist)](https://gist.github.com/galvesribeiro/89ce0232c8bc1971af84aee84746dc66)
- [UniFi Cloud Gateway Ultra – Tech Specs](https://techspecs.ui.com/unifi/unifi-cloud-gateways/ucg-ultra)
- [UniFi Cloud Gateway Ultra Review: The 1 Gbps Ceiling](https://unifiguide.com/posts/unifi-cloud-gateway-ultra-review/)
- [ynoTV source (tbeezy/ynotv)](https://github.com/tbeezy/ynotv)
- [mpv `stream_curl.c`](https://github.com/mpv-player/mpv/blob/master/stream/stream_curl.c)
