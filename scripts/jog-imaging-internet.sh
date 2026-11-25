#!/bin/bash
set -euo pipefail
JOG_ENV="${JOG_ENV:-/etc/jog/jog.env}"
[[ -f "$JOG_ENV" ]] || JOG_ENV=/etc/jog/jog.env
[[ -f "$JOG_ENV" ]] && source "$JOG_ENV"
UPLINK_IFACE="${JOG_UPLINK_IFACE:-${JOG_UPLINK_IFACE:-}}"
IMAGING_NET="${JOG_IMAGING_NET:-${JOG_IMAGING_NET:-10.99.0.0/24}}"
AP_NET="${JOG_AP_NET:-${JOG_AP_NET:-10.42.0.0/24}}"

detect_uplink() {
  ip route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}
if [[ -z "$UPLINK_IFACE" ]]; then UPLINK_IFACE=$(detect_uplink || true); fi
[[ -n "$UPLINK_IFACE" ]] || exit 0

sysctl -w net.ipv4.ip_forward=1 >/dev/null

nat_add() {
  local net="$1"
  [[ -n "$net" ]] || return 0
  while iptables -t nat -C POSTROUTING -s "$net" -o "$UPLINK_IFACE" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -s "$net" -o "$UPLINK_IFACE" -j MASQUERADE || break
  done
  iptables -t nat -A POSTROUTING -s "$net" -o "$UPLINK_IFACE" -j MASQUERADE
}
nat_add "$IMAGING_NET"
nat_add "$AP_NET"
