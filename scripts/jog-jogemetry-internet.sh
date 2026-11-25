#!/bin/bash
set -euo pipefail
UPLINK_IFACE=wlp0s20f3
AP_NET=10.42.0.0/24
if [[ -r /run/jog-jogemetry-iface ]]; then
    AP_IFACE=$(cat /run/jog-jogemetry-iface)
else
    AP_IFACE=$(iw dev | awk -v uplink="$UPLINK_IFACE" '$1 == "Interface" && $2 != uplink { print $2; exit }')
fi
if [[ -z "$AP_IFACE" ]]; then
    echo "jog-jogemetry-internet: no management Wi-Fi interface found" >&2
    exit 1
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null
while iptables -C FORWARD -i "$AP_IFACE" -o "$UPLINK_IFACE" -j ACCEPT 2>/dev/null; do iptables -D FORWARD -i "$AP_IFACE" -o "$UPLINK_IFACE" -j ACCEPT; done
while iptables -C FORWARD -i "$UPLINK_IFACE" -o "$AP_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do iptables -D FORWARD -i "$UPLINK_IFACE" -o "$AP_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; done
while iptables -C FORWARD -i "$AP_IFACE" ! -o "$UPLINK_IFACE" -j DROP 2>/dev/null; do iptables -D FORWARD -i "$AP_IFACE" ! -o "$UPLINK_IFACE" -j DROP; done
iptables -A FORWARD -i "$AP_IFACE" -o "$UPLINK_IFACE" -j ACCEPT
iptables -A FORWARD -i "$UPLINK_IFACE" -o "$AP_IFACE" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i "$AP_IFACE" ! -o "$UPLINK_IFACE" -j DROP
while iptables -t nat -C POSTROUTING -s "$AP_NET" -o "$UPLINK_IFACE" -j MASQUERADE 2>/dev/null; do iptables -t nat -D POSTROUTING -s "$AP_NET" -o "$UPLINK_IFACE" -j MASQUERADE; done
iptables -t nat -A POSTROUTING -s "$AP_NET" -o "$UPLINK_IFACE" -j MASQUERADE
