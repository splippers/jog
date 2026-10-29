#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log
# Bring the imaging NIC administratively up with its static IP, regardless of
# carrier. For a dedicated USB adapter this rarely matters - it is plugged in
# only when imaging. For an onboard NIC used intermittently (cable unplugged
# between sessions, as on a shared workstation), it matters a lot: without
# this, dnsmasq has nothing to bind to until the cable happens to be plugged
# in before boot, and the usual network stack (NetworkManager/netplan) will
# not apply a static config to a carrier-less link at all - see
# 99-jog-unmanaged.conf, which takes the interface out of NetworkManager's
# hands so this script's state isn't fought or cleared on link-state changes.
#
# Idempotent: safe to re-run (e.g. from a udev rule on link-up) as well as at boot.
# Env: JOG_ENV (/etc/jog/jog.env)

log() { echo "[jog-force-imaging-nic-up] $*"; }

[[ "$(id -u)" -eq 0 ]] || {
  echo "Run as root: sudo $0" >&2
  exit 1
}

JOG_ENV="${JOG_ENV:-/etc/jog/jog.env}"
[[ -f "$JOG_ENV" ]] || { log "missing $JOG_ENV - nothing to apply"; exit 1; }
# shellcheck disable=SC1090
source "$JOG_ENV"

: "${JOG_USB_IFACE:?Set JOG_USB_IFACE in $JOG_ENV}"
: "${JOG_IMAGING_IP:?}"
: "${JOG_IMAGING_PREFIX:?}"

IFACE="$JOG_USB_IFACE"
CIDR="${JOG_IMAGING_IP}/${JOG_IMAGING_PREFIX}"

ip link show "$IFACE" >/dev/null 2>&1 || { log "no such interface: $IFACE"; exit 1; }

ip link set "$IFACE" up
if ! ip -4 addr show dev "$IFACE" | grep -q "inet ${JOG_IMAGING_IP}/"; then
  ip addr add "$CIDR" dev "$IFACE"
  log "assigned $CIDR to $IFACE"
else
  log "$CIDR already assigned to $IFACE"
fi
