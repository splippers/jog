#!/bin/bash
# Re-assert the JOG imaging NIC address if anything has cleared it.
#
# jog-force-imaging-nic-up.service is a boot-time oneshot, so an address it
# assigned stays gone if something later flushes the interface -- notably
# `netplan apply`, which this host uses to bring up the WiFi uplink and which
# reconfigures every interface netplan knows about. That left dnsmasq logging
# "DHCP packet received on enp2s0 which has no address" and every PXE client
# failing to get a lease until the next reboot.
#
# Idempotent and silent: only calls the canonical script when the address is
# actually missing, so it adds nothing to the journal while healthy.
set -uo pipefail
JOG_ENV="${JOG_ENV:-/etc/jog/jog.env}"
[[ -f "$JOG_ENV" ]] || exit 0
# shellcheck disable=SC1090
source "$JOG_ENV"
: "${JOG_USB_IFACE:?}" "${JOG_IMAGING_IP:?}"

ip link show "$JOG_USB_IFACE" >/dev/null 2>&1 || exit 0
ip -4 addr show dev "$JOG_USB_IFACE" | grep -q "inet ${JOG_IMAGING_IP}/" && exit 0

exec /usr/local/sbin/jog-force-imaging-nic-up.sh
