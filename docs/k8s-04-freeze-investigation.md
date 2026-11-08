---
title: k8s-04 Freeze Investigation
description: Why k8s-04 freezes and never recovers, what was put in place to capture evidence of the next freeze, how to read that evidence, and the ordered list of changes to test once it is in.
---

# k8s-04 Freeze Investigation

> **Status (2026-11-08):** The first freeze with Phase 1 in place (2026-11-07 09:32 UTC) is triaged as a **whole-machine hard lock while idle** (§2, "Freeze of 2026-11-07"). It was not the network and not the NVMe.
>
> **Test in progress (since 2026-11-08 02:02 UTC):** C-states C2 and C3 are disabled at runtime (§7 B2). This **does not survive a reboot**: re-apply it after every power-cycle, or the test is void. **Pass condition:** no freeze before 2026-11-22. **Next:** test the watchdog (§6) when convenient.
>
> **Workaround in place:** Home Assistant power-cycles k8s-04's smart outlet when `HomeAssistantPowercycleK8s04Trigger` fires. Leave it as is: the node never recovers by itself.

---

## 1. The node

| | |
|---|---|
| Hardware | Lenovo `11MQ002HUS` (ThinkCentre Tiny class), BIOS `M3JKT44A` (2025-10-29) |
| CPU / GPU | Intel Rocket Lake (family 6, model 167), UHD 750 iGPU (`8086:4c8a`) |
| Memory | 16 GiB, 2/2 slots populated, no ECC |
| Disk | Samsung PM9A1 `MZVL2512HCJQ-00BL7` NVMe, 41% used, 159 media errors (unchanged for 30+ days, so old) |
| NIC | Intel I219-LM (`e1000e`, `eno2`), 1 Gbit |
| Watchdog | `iTCO_wdt` (Intel PCH TCO v6) on `/dev/watchdog0`, 5 min timeout (`talos/node/k8s-04/02-watchdog.yaml`) |
| Schematic | `talos/schematics/worker-intel-gpu.yaml.j2` |

It is the only bare-metal node; the other five are VMware VMs. It runs the media workloads (Plex, Emby, Dispatcharr) because of the iGPU.

Kernel arguments set by the schematic that matter here: `i915.enable_guc=3`, `intel_idle.max_cstate=0`, `intel_iommu=on iommu=pt`, `mitigations=off`. The Talos kernel has `kernel.panic=10` (reboot 10 s after a panic), but no soft-lockup, hard-lockup or hung-task detector and no usable pstore backend, so a hang leaves no trace in the kernel itself.

---

## 2. What is known

### Timeline

| Event (UTC) | Went dark | Back up | Rebooted by |
|---|---|---|---|
| 2026-10-27 | ? | 18:02 | Before the metrics window, unknown |
| 2026-11-03 | 16:40:30 | 16:45:20 | Home Assistant (`HomeAssistantPowercycleK8s04Trigger` fired 16:43:42) |
| 2026-11-06 | 21:25:00 | 21:27:45 | Same freeze; the HA power-cycle was triggered by hand before the cluster alerts fired (`bootstatus=0` afterwards, so not the watchdog) |
| 2026-11-07 | 09:32:24 | 09:43:17 | Home Assistant (`HomeAssistantPowercycleK8s04Trigger` fired 09:41:45, `bootstatus=0`). First freeze with evidence; 12 h after the previous boot |

### What the metrics show before a freeze

- **Everything stops at once.** Every scrape target on the node (node-exporter, kubelet, cAdvisor, Cilium) goes down in the same 30 s window. Nothing degrades beforehand.
- **No resource exhaustion.** About 2 GiB MemAvailable, memory/IO/CPU pressure near zero, no OOM kills, max temperature 60–70 °C (86 °C peaks during busy periods, well under limits).
- **The iGPU was idle** at both freezes, so it was not a transcode in progress.

### What that leaves

Something sudden: either the network path dies while the kernel keeps running (NIC/driver hang), or the whole machine hard-locks (kernel/platform/iGPU/PCIe/NVMe). Before Phase 1 there was no way to tell which, because:

- the kernel ring buffer is lost on a power cycle;
- Talos kernel and service log shipping had never delivered anything: it pointed at `fluent-bit.observability.svc.cluster.local`, which the host resolver (1.1.1.1) cannot resolve;
- VictoriaLogs ran on k8s-04 itself.

### Freeze of 2026-11-07: the evidence

All times UTC. The boot that froze is `20261106T212746Z_dee52a2d`.

| Source | Last record | Content |
|---|---|---|
| Local heartbeat file | 09:32:22 | All healthy: all three pings `ok`, `carrier=1`, no new `tx_err`/`tx_drop`, `nvme0=live`, load 1.4, 8 GiB available, 57 °C, `wdt=active/300s`. The next line (due 09:32:32) was never written |
| Local kmsg file | 09:29:50 | `eth0: renamed from tmpc3c00` (routine pod start). No e1000e, i915/GuC, NVMe, MCE, lockup or oops line in the whole boot |
| VictoriaLogs, Talos kernel log | 09:29:50 | The same line. Nothing after it |
| VictoriaLogs, Talos service logs | 09:32:24.69 | Routine kubelet and apid lines. Nothing after it |
| Prometheus | 09:32:45 | First `up == 0` |
| iGPU / CPU / disk metrics | 09:32:30 | iGPU 0 % on every engine, about 0.5 cores busy, disk idle, 60–66 °C |

Reading it against §5:

- **Not the network.** Local disk writes stopped at the same time as the network, and the last heartbeat shows the link and all pings healthy.
- **Not the NVMe.** Talos service logs come from memory over UDP and would have kept arriving after a disk dropout, together with an `nvme ... controller is down` line. They stopped within 2 s of the last disk write.
- **So the whole machine hard-locked, at idle**, with no warning in the logs or metrics.

Two more findings:

- **Deep C-states are in use, despite `intel_idle.max_cstate=0`.** The idle driver is `acpi_idle`, using the states the BIOS advertises in `_CST`:

  | Linux state | MWAIT hint | Hardware state | Exit latency | Use in the 16 h after the freeze |
  |---|---|---|---|---|
  | C1 | `0x00` | C1 (halt, core clock off) | 1 µs | about 33 % of cpu0's time |
  | C2 | `0x31` | C7-class (core power-gated, shared cache flushed) | 253 µs | about 48 % of cpu0's time; about 20 M entries per thread |
  | C3 | `0x60` | C10 (deepest package state) | 1,048 µs | 7–10 M entries on each of cpu1–11 (cpu0 only 19 k) |

  That is roughly 700 deep-state entries and exits per thread per second. A rare failure on any one of them (voltage-regulator ramp, microcode, platform coordination with the iGPU, PCIe ASPM or the PCH) would look exactly like this freeze: sudden, at idle, with nothing logged, because the CPU that would log it is the part that stopped. Limiting C-states is the first Phase 2 test (§7 B2).
- **The Home Assistant trigger was about 6 min late.** `kube-state-metrics` ran on k8s-04, so the node-condition metrics behind `KubeNodeNotReadyHomeAssistantTrigger` and `KubeNodeUnreachableHomeAssistantTrigger` disappeared along with the node. They came back only once Kubernetes evicted KSM to k8s-06 (09:39), so the trigger fired at 09:41:45 instead of about 09:36. KSM now has the same `NotIn [k8s-04]` affinity as Prometheus, Alertmanager and VictoriaLogs.

### The node never recovering is itself a clue

With a 5 min hardware watchdog, a real kernel hang should reset the machine after 5 min. It never does. Either Talos keeps feeding the watchdog (the kernel is alive, so the network is what died), or the watchdog does not actually reset this machine.

The second is plausible: `/sys/class/watchdog/watchdog0/timeleft` reads a constant `300s` in every heartbeat (all 4,113 of them in the boot that froze), although Talos feeds it only every 1m40s. A running TCO timer should count down between feeds. §6 tests it.

The 2026-11-07 freeze makes the second explanation more likely, but does not prove it. The machine was dead (no disk writes, no network), so nothing could feed the watchdog, yet it had not reset 9.5 min later, when Home Assistant cut the power. That is well past the 5 min timeout. But on TCO v2 and later, the hardware resets only on the *second* expiry, which could mean up to about 10 min, so §6 still needs to wait past 12 min.

---

## 3. What is implemented (Phase 1)

| Piece | Where | What it does |
|---|---|---|
| `node-forensics` DaemonSet (k8s-04 only) | `kubernetes/apps/observability/node-forensics/` | Copies `/dev/kmsg` and a 10 s heartbeat to the node's NVMe, synced every 10 s |
| Fixed address for the Talos log inputs | `kubernetes/apps/observability/fluent-bit/app/service.yaml` | LoadBalancer `fluent-bit-talos` at `192.168.30.131`, UDP 10001 (service logs) and 10002 (kernel logs) |
| Talos log destinations | `talos/all/11-machine-logging.yaml.tpl` | Service logs → `udp://192.168.30.131:10001/` with `extraTags: node: <host>`; `KmsgLogConfig` → `udp://192.168.30.131:10002/`. Applies to all nodes |
| Node identity for Talos records | `kubernetes/apps/observability/fluent-bit/app/helmrelease.yaml` | `source_address_key` on both UDP inputs, plus a parser filter that extracts `node_ip`. Stream fields: services `node,talos-service`; kernel `node_ip,facility` |
| VictoriaLogs off k8s-04 | `kubernetes/apps/observability/victoria-logs/app/helmrelease.yaml` | Required node affinity `NotIn [k8s-04]`, so the log store survives the freeze |

### node-forensics in detail

Script: `kubernetes/apps/observability/node-forensics/app/resources/node-forensics.sh`. It writes two files per boot to `/var/lib/node-forensics` (the EPHEMERAL partition, which survives a reboot), named `<boot-start>_<boot-id>`:

- `*.kmsg.log`: every kernel record of that boot, formatted `<UTC time> <seq> <facility>.<level> <message>`. After a pod restart it carries on where it left off, using the sequence numbers.
- `*.heartbeat.log`: one line every 10 s:

  ```text
  2026-11-06T22:09:04Z up=2478.45 load=1.81,2.00,1.87 memavail_mb=9331 psi_mem=0.00 psi_io=0.46 temp_max_c=64 if=eno2 oper=up carrier=1 rx_pkts=18284487 tx_pkts=23030486 rx_err=0 tx_err=0 tx_drop=25 ping[192.168.30.1]=ok ping[192.168.30.10]=ok ping[1.1.1.1]=ok nvme0=live wdt=active/300s
  ```

  The pings are to the default gateway, the API VIP and the internet; `wdt` is the watchdog's state/time left.

It also writes to stdout, which fluent-bit ships to VictoriaLogs:

- every kernel line;
- one heartbeat a minute;
- at startup, the last 12 heartbeats and last 100 kernel lines of the **previous** boot, prefixed `previous-boot`.

Files older than 30 days are deleted.

**Netconsole was considered and dropped.** It is built into the kernel, but `e1000e` is a module that loads after netconsole initialises, and `CONFIG_NETCONSOLE_DYNAMIC` is off, so it can never attach to `eno2`.

---

## 4. After the next freeze: collect the evidence

Do this after Home Assistant has power-cycled the node. Nothing is lost by waiting, as long as it is within 30 days.

1. **Note when the node went dark.** In Prometheus, find the first `up{instance="192.168.30.24:9100"} == 0`. In Grafana, the gap in any k8s-04 panel shows the same.
2. **Pull the local files.** The older pair belongs to the boot that froze:

   ```bash
   talosctl -n 192.168.30.24 ls -l /var/lib/node-forensics
   talosctl -n 192.168.30.24 read /var/lib/node-forensics/<prev>.heartbeat.log | tail -100 > /tmp/k8s-04-heartbeat.log
   talosctl -n 192.168.30.24 read /var/lib/node-forensics/<prev>.kmsg.log      | tail -300 > /tmp/k8s-04-kmsg.log
   ```

3. **Pull what made it off the node before it went dark.** In the VictoriaLogs UI, over a window from about 30 min before the freeze to its end:

   ```text
   {facility="kern", node_ip="192.168.30.24"}
   {node="k8s-04"}
   {app="node-forensics"}
   ```

4. **Check whether the watchdog fired:** `talosctl -n 192.168.30.24 read /sys/class/watchdog/watchdog0/bootstatus`. Non-zero means the last reset came from the watchdog. A smart-plug power cycle reads `0`.
5. **Optional, from the switch side:** in unpoller metrics or the UniFi UI, check whether k8s-04's switch port kept link and whether traffic stopped.

---

## 5. Triage: which kind of freeze is it?

| Evidence | Conclusion | Go to |
|---|---|---|
| Local heartbeats **continue** after the node went dark; `ping[...]=FAIL` while `carrier=1`, and/or `tx_err`/`tx_drop` climbing; possibly `e1000e ... Detected Hardware Unit Hang` in the kmsg file | **Network path died, kernel alive** | §7 A |
| Local heartbeats **stop** at the moment it went dark; the remote Talos kernel log shows `nvme ... controller is down` / I/O errors just before | **NVMe dropped out** (local writes die with the disk) | §7 C |
| Local heartbeats **stop** at the moment it went dark, nothing useful anywhere | **Whole machine hard-locked** | §7 B |
| Kernel log ends with an oops, `BUG:`, `Call Trace`, `i915 ... GPU HANG`, `GuC`, or `mce:` lines | That subsystem is the lead | Matching row in §7 |

Any `wdt=` value other than `active/300s` in the last heartbeats is worth noting too.

---

## 6. Test the watchdog (do this once, in a maintenance window)

This settles whether the hardware watchdog can reset k8s-04 at all. **It deliberately crashes the node.**

1. **Pause the Home Assistant power-cycle automation for the duration.** Otherwise it power-cycles the node at about 3.5 min, before the watchdog can show what it does.
2. **Drain the node:**

   ```bash
   kubectl drain k8s-04 --ignore-daemonsets --delete-emptydir-data
   ```

3. **Disable the panic auto-reboot, then crash the kernel.** With `kernel.panic=0` the kernel stays halted after the crash, so only the watchdog can bring it back:

   ```bash
   kubectl -n observability exec ds/node-forensics -- sh -c 'echo 0 > /proc/sys/kernel/panic; echo c > /proc/sysrq-trigger'
   ```

4. **Time it.** Watch the console or ping `192.168.30.24`:
   - **Resets on its own within ~5–10 min:** the watchdog works. A freeze that never recovers then means the kernel was alive and feeding it, which points to §7 A (network).
   - **Stays down past ~12 min:** the watchdog does not reset this machine. Power-cycle it. Look for a BIOS setting covering the TCO/watchdog or Intel AMT/ME; `watchdog1` is `iamt_wdt`, the ME's watchdog, which may be an alternative device. Until it is fixed, Home Assistant stays the only recovery.
5. **Restore:** confirm `bootstatus` (non-zero if the watchdog reset it), then `kubectl uncordon k8s-04` and re-enable the automation. `kernel.panic` returns to 10 on boot.

---

## 7. Phase 2: changes to test

Make **one change at a time**. Leave each one in place for at least twice the usual gap between freezes (currently 3–7 days, so about two weeks) before deciding it helped. Record each change and its date in §9.

How changes are applied:
- **Machine-config documents** (e.g. `EthernetConfig`): add a file under `talos/node/k8s-04/`, run `just talos diff-node k8s-04`, then `just talos apply-node k8s-04`. No reboot needed.
- **Kernel arguments** live in `talos/schematics/worker-intel-gpu.yaml.j2`. They need a new image: run `just talos schematic-ids`, then `just talos upgrade-node k8s-04`, which power-cycles the node. When you next edit the schematic, also remove the broken `talos.logging.kernel=` argument; the `KmsgLogConfig` replaces it. The other schematics have the same argument; remove it from each the next time it is upgraded anyway.

### A. Network path dies (most likely if the watchdog test passes)

The I219-LM / `e1000e` "Hardware Unit Hang" is a known failure on these Lenovo Tiny machines; the usual triggers are segmentation offload and PCIe power saving.

1. **Turn off segmentation and receive offloads** (no reboot). New file `talos/node/k8s-04/03-ethernet.yaml`:

   ```yaml
   ---
   apiVersion: v1alpha1
   kind: EthernetConfig
   name: eno2
   features:
     tx-tcp-segmentation: false
     tx-generic-segmentation: false
     rx-gro: false
   ```

   Check the result with `talosctl -n 192.168.30.24 get ethernetstatus eno2 -o yaml`.
2. **Turn off PCIe ASPM:** add `pcie_aspm=off` to the schematic.
3. **If it still happens:** swap the cable and switch port, then consider a USB 2.5 GbE adapter (Realtek `r8152`, a different driver entirely) as the primary NIC.

### B. Whole machine hard-locks

1. **`i915.enable_guc=2` instead of `=3`.** `=3` forces GuC submission, which is not the i915 default on Rocket Lake. Quick Sync low-power encode only needs HuC loading (`=2`).
2. **Limit C-states to C1. Being tested now, applied at runtime on 2026-11-08 02:02 UTC.** `intel_idle.max_cstate=0` does not limit C-states: it disables `intel_idle`, the kernel falls back to `acpi_idle`, and the BIOS's deep states stay on (§2).

   **At runtime (current test).** This needs no reboot and takes effect at once. It is lost on every reboot, including an HA power-cycle, so re-run it after each one:

   ```bash
   kubectl -n observability exec ds/node-forensics -- sh -c \
     'for c in /sys/devices/system/cpu/cpu[0-9]*; do echo 1 > $c/cpuidle/state2/disable; echo 1 > $c/cpuidle/state3/disable; done'
   ```

   Check it: `disable` reads `1`, and `usage` stops increasing, for `state2` and `state3` on every CPU:

   ```bash
   kubectl -n observability exec ds/node-forensics -- sh -c \
     'for c in /sys/devices/system/cpu/cpu[0-9]*; do echo "$(basename $c) $(cat $c/cpuidle/state2/disable)$(cat $c/cpuidle/state3/disable) $(cat $c/cpuidle/state2/usage) $(cat $c/cpuidle/state3/usage)"; done'
   ```

   Revert: the same loop, writing `0`. Cost: an estimated 5–10 W more at idle (not measured; compare the smart plug's power reading if it has one), and none under load.

   **Permanently (if the test passes).** Add `processor.max_cstate=1` to the schematic (`acpi_idle` honours it; `intel_idle.max_cstate=1` only helps if `intel_idle` drives this CPU, which is unconfirmed for Rocket Lake), then `just talos upgrade-node k8s-04`. After it boots, check that `state2` and `state3` are gone from `/sys/devices/system/cpu/cpu0/cpuidle/`, or that their `usage` stays at 0. If it passes, it can be loosened later one state at a time, to win power back.
3. **NVMe power saving off:** `nvme_core.default_ps_max_latency_us=0` (also row C).
4. **Hardware checks:** run memtest86+ for a full pass, overnight, from USB. Check Lenovo support for a BIOS newer than `M3JKT44A`.

### C. NVMe drops out

1. `nvme_core.default_ps_max_latency_us=0` (disables APST).
2. Watch `smartctl_device_media_errors` / `smartctl_device_num_err_log_entries` (currently 159). If they start rising, replace the drive.

---

## 8. Useful queries

### VictoriaLogs

| What | Query |
|---|---|
| All Talos kernel logs | `{facility="kern"}` |
| k8s-04 kernel logs | `{facility="kern", node_ip="192.168.30.24"}` (may show k8s-04's Cilium 10.42.x.x address instead; list them with `{facility=~".+"} \| stats by (node_ip) count()`) |
| Kernel warnings and errors | `{facility="kern"} priority:in("emerg","alert","crit","err","warning")` |
| Talos service logs for k8s-04 | `{node="k8s-04"}` |
| node-forensics kernel lines | `{app="node-forensics"} -heartbeat -"previous-boot"` |
| Evidence from the last freeze | `{app="node-forensics"} "previous-boot"` |
| Suspects | `{facility="kern"} _msg:~"(?i)e1000e\|unit hang\|i915\|gpu hang\|guc\|nvme\|machine check\|mce\|watchdog\|lockup\|call trace"` |

### Prometheus

| What | Query |
|---|---|
| When it went dark | `up{job="node-exporter",instance="192.168.30.24:9100"} == 0` |
| Boot times | `node_boot_time_seconds{instance="192.168.30.24:9100"}` |
| Power-cycle trigger history | `ALERTS{alertname="HomeAssistantPowercycleK8s04Trigger"}` |
| iGPU activity | `igpu_engines_video_0_busy`, `igpu_engines_render_3d_0_busy` |
| NVMe health | `smartctl_device_media_errors{device="nvme0"}` |

---

## 9. Log of changes and freezes

| Date | Change / event | Result |
|---|---|---|
| 2026-11-03 | Freeze; HA power-cycled | No evidence captured (pre-Phase 1) |
| 2026-11-06 | Freeze (dark 21:25); HA automation triggered by hand about 2.5 min later | No evidence captured (pre-Phase 1) |
| 2026-11-06 | Phase 1 deployed (`node-forensics`, Talos log shipping fixed, VictoriaLogs moved off k8s-04) | Logs and local files confirmed |
| 2026-11-07 | Freeze (dark 09:32:24); HA power-cycled at about 09:42 | Evidence captured: whole-machine hard lock at idle (§2) |
| 2026-11-08 | `kube-state-metrics` kept off k8s-04 | Removes the ~6 min delay in the HA trigger |
| 2026-11-08 02:02 | **§7 B2 at runtime:** `state2` and `state3` disabled on all 12 CPUs (C1 is now the deepest state). Lost on reboot | Testing. Pass = no freeze before 2026-11-22 |

---

## 10. When the cause is found

- Revert any Phase 2 changes that did not help.
- Decide whether `node-forensics` stays. It is cheap (32Mi, 10m CPU). Extending it to other nodes is one line: its node affinity list.
- Keep the Talos log shipping and the VictoriaLogs affinity; they help every node.
- Keep the Home Assistant automation until the node has gone well past its old freeze interval without one.
