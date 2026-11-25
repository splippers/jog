#!/bin/bash
set -euo pipefail
UPLINK_IFACE=wlp0s20f3
AP_IFACE=$(iw dev | awk -v uplink="$UPLINK_IFACE" '$1 == "Interface" && $2 != uplink { print $2; exit }')
if [[ -z "$AP_IFACE" ]]; then
    echo "jog-jogemetry-prepare: no management Wi-Fi interface found" >&2
    exit 1
fi
printf '%s\n' "$AP_IFACE" > /run/jog-jogemetry-iface
sed "s/^interface=.*/interface=$AP_IFACE/" /etc/jog/jogemetry-hostapd.conf.template > /run/jog-jogemetry-hostapd.conf
sed "s/^interface=.*/interface=$AP_IFACE/" /etc/jog/jogemetry-dnsmasq.conf.template > /run/jog-jogemetry-dnsmasq.conf
ip link set "$AP_IFACE" up
ip addr replace 10.42.0.1/24 dev "$AP_IFACE"

cp -f /run/jog-jogemetry-hostapd.conf /run/jog-jogemetry-hostapd.conf 2>/dev/null || true
cp -f /run/jog-jogemetry-dnsmasq.conf /run/jog-jogemetry-dnsmasq.conf 2>/dev/null || true
ln -sf /run/jog-jogemetry-iface /run/jog-jogemetry-iface 2>/dev/null || true
