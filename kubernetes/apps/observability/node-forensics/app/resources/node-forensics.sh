#!/bin/sh
# node-forensics: keep evidence of a node freeze on the node's own disk, where it
# survives the power cycle that the network-based log shipping cannot.
#
#   <DIR>/<boot-start>_<boot-id>.kmsg.log       every /dev/kmsg record of that boot
#   <DIR>/<boot-start>_<boot-id>.heartbeat.log  one line every HEARTBEAT_INTERVAL seconds
#
# Both files are fsync'd every HEARTBEAT_INTERVAL seconds, so a hard freeze loses at most
# that much. Read them after the reboot with:
#   talosctl -n <node-ip> ls /var/lib/node-forensics
#   talosctl -n <node-ip> read /var/lib/node-forensics/<file>
#
# The heartbeat answers the key question: if heartbeats keep coming after the node dropped
# off the network, the kernel was alive and the NIC/network died; if they stop at the same
# moment, the whole machine froze.
set -u

DIR="${FORENSICS_DIR:-/forensics}"
INTERVAL="${HEARTBEAT_INTERVAL:-10}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
PING_TARGETS="${PING_TARGETS:-}"

mkdir -p "$DIR"
find "$DIR" -type f -mtime +"$RETENTION_DAYS" -delete 2>/dev/null

BOOT_ID="$(cut -c1-8 /proc/sys/kernel/random/boot_id)"
UPTIME="$(cut -d' ' -f1 /proc/uptime)"
BOOT_EPOCH=$(( $(date +%s) - ${UPTIME%.*} ))

# Reuse this boot's files when the pod restarts; otherwise start a new pair.
PREFIX="$(ls "$DIR" | grep -m1 "_${BOOT_ID}\.kmsg\.log$" | sed 's/\.kmsg\.log$//')"
[ -n "$PREFIX" ] || PREFIX="$(date -u -d "@$BOOT_EPOCH" +%Y%m%dT%H%M%SZ)_${BOOT_ID}"
KMSG="$DIR/$PREFIX.kmsg.log"
HB="$DIR/$PREFIX.heartbeat.log"
touch "$KMSG" "$HB"

# Ship the tail of the previous boot to stdout (-> fluent-bit -> VictoriaLogs), so the
# evidence of the last freeze shows up remotely without anyone reading the files.
PREV="$(ls -1 "$DIR" | grep '\.kmsg\.log$' | grep -v "^$PREFIX\." | sort | tail -n 1 | sed 's/\.kmsg\.log$//')"
if [ -n "$PREV" ]; then
  echo "previous-boot $PREV last heartbeats:"
  tail -n 12 "$DIR/$PREV.heartbeat.log" 2>/dev/null | sed "s/^/previous-boot $PREV hb /"
  echo "previous-boot $PREV last kernel messages:"
  tail -n 100 "$DIR/$PREV.kmsg.log" 2>/dev/null | sed "s/^/previous-boot $PREV kmsg /"
fi

trap 'trap - TERM INT; kill 0' TERM INT

read_first() { cat "$1" 2>/dev/null | head -n 1 || true; }

psi_some_avg10() { awk '/^some/ { split($2, a, "="); print a[2] }' "$1" 2>/dev/null; }

heartbeat() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) start node=$(hostname) boot_id=$BOOT_ID interval=${INTERVAL}s" >> "$HB"
  every=$(( 60 / INTERVAL )); [ "$every" -ge 1 ] || every=1
  n=0
  while :; do
    route="$(ip -4 route show default 2>/dev/null | head -n 1)"
    gw="$(echo "$route" | awk '{ for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1) }')"
    ifc="$(echo "$route" | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }')"
    net="/sys/class/net/${ifc:-none}"
    st="$net/statistics"

    pings=""
    for t in $gw $PING_TARGETS; do
      if ping -c 1 -W 1 -q "$t" >/dev/null 2>&1; then r=ok; else r=FAIL; fi
      pings="$pings ping[$t]=$r"
    done

    nvme=""
    for c in /sys/class/nvme/nvme*; do
      [ -e "$c/state" ] && nvme="$nvme ${c##*/}=$(read_first "$c/state")"
    done

    temp="$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -n 1)"
    memavail="$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)"

    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) up=$(cut -d' ' -f1 /proc/uptime) load=$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ',')"
    line="$line memavail_mb=$memavail psi_mem=$(psi_some_avg10 /proc/pressure/memory) psi_io=$(psi_some_avg10 /proc/pressure/io)"
    line="$line temp_max_c=$(( ${temp:-0} / 1000 ))"
    line="$line if=${ifc:-none} oper=$(read_first "$net/operstate") carrier=$(read_first "$net/carrier")"
    line="$line rx_pkts=$(read_first "$st/rx_packets") tx_pkts=$(read_first "$st/tx_packets")"
    line="$line rx_err=$(read_first "$st/rx_errors") tx_err=$(read_first "$st/tx_errors") tx_drop=$(read_first "$st/tx_dropped")"
    line="$line$pings$nvme"
    line="$line wdt=$(read_first /sys/class/watchdog/watchdog0/state)/$(read_first /sys/class/watchdog/watchdog0/timeleft)s"

    echo "$line" >> "$HB"
    # Once a minute to stdout too, so the last heartbeat that made it off the node is
    # visible in VictoriaLogs for comparison with the local file.
    [ $(( n % every )) -eq 0 ] && echo "heartbeat $line"
    n=$(( n + 1 ))

    fsync "$KMSG" "$HB" 2>/dev/null || sync
    sleep "$INTERVAL"
  done
}

kmsg() {
  # cat exits with EPIPE when the ring buffer overruns it; restart it, and let awk drop
  # the records it has already written (by sequence number).
  last="$(tail -n 1 "$KMSG" | awk '{ print $2 + 0 }')"
  [ -s "$KMSG" ] || last=-1
  while :; do cat /dev/kmsg; sleep 1; done | awk -v boot="$BOOT_EPOCH" -v last="${last:--1}" -v out="$KMSG" '
    BEGIN {
      split("emerg alert crit err warning notice info debug", lvl, " ")
      split("kern user mail daemon auth syslog lpr news", fac, " ")
    }
    function emit(s) { print s >> out; fflush(out); print s; fflush() }
    # Continuation lines (" SUBSYSTEM=...", " DEVICE=...") belong to the previous record.
    /^ / { if (keep) emit(ts " " cur " " name " " $0); next }
    {
      hdr = $0; sub(/;.*/, "", hdr)
      msg = substr($0, length(hdr) + 2)
      split(hdr, f, ",")
      cur = f[2] + 0
      keep = (cur > last)
      if (!keep) next
      last = cur
      p = f[1] % 8; fc = int(f[1] / 8)
      name = ((fc + 1) in fac ? fac[fc + 1] : "fac" fc) "." lvl[p + 1]
      t = boot + f[3] / 1000000
      ts = strftime("%Y-%m-%dT%H:%M:%S", int(t)) sprintf(".%06dZ", (t - int(t)) * 1000000)
      emit(ts " " cur " " name " " msg)
    }
  '
}

# Both in the background: ash only runs the TERM trap once `wait` returns.
heartbeat &
kmsg &
wait
