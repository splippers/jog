#!/bin/bash
set -euo pipefail
umask 027
exec 2>>/tmp/mist_error.log

JOG_ENV="${MIST_ENV:-${MIST_ENV:-${JOG_ENV:-/etc/mist/mist.env}}}"
PORTAL_NETPLAN=/etc/netplan/90-mist-portal.yaml
BACKHAUL_NETPLAN=/etc/netplan/91-mist-backhaul.yaml
HOTSPOT_HOSTAPD=/etc/hostapd/mist-jogometry.conf
HOTSPOT_DNSMASQ=/etc/dnsmasq-jogometry.conf
HOTSPOT_LEASES=/var/lib/misc/dnsmasq-jogometry.leases
HOTSPOT_UNIT=/etc/systemd/system/mist-mistmetry-hotspot.service
HOTSPOT_DHCP_UNIT=/etc/systemd/system/mist-mistmetry-dnsmasq.service
GUARD=/usr/local/bin/mist-dhcp-guard.py
RENDER=/usr/local/bin/mist-render-dnsmasq.sh
IMAGING_CONF=/etc/dnsmasq.d/99-mist-imaging.conf
VM_IMAGES_DIR=/var/lib/libvirt/images
VM_NETWORK_DIR=/var/lib/libvirt/network

fail() {
  python3 - "$*" <<'PY' || true
import json
import sys

print(json.dumps({"ok": False, "error": sys.argv[1]}))
PY
  echo "mist-portal-network: $*" >&2
  exit 1
}

emit() {
  python3 - "$@" <<'PY'
import json
import sys

data = {}
for item in sys.argv[1:]:
    if "=" in item:
        key, value = item.split("=", 1)
        data[key] = value
print(json.dumps(data, sort_keys=True))
PY
}

yaml_quote() {
  python3 -c 'import sys; value=sys.argv[1].replace(chr(39), chr(39)*2); print(chr(39)+value+chr(39))' "$1"
}

env_get() {
  python3 - "$JOG_ENV" "$1" <<'PY'
import sys

path, key = sys.argv[1:]
try:
    with open(path) as handle:
        for line in handle:
            if "=" in line and line.split("=", 1)[0].strip() == key:
                print(line.split("=", 1)[1].strip().strip('"').strip("'"))
                break
except OSError:
    pass
PY
}

env_set() {
  python3 - "$JOG_ENV" "$@" <<'PY'
import os
import sys

path = sys.argv[1]
items = sys.argv[2:]
values = dict(zip(items[0::2], items[1::2]))
lines = []
seen = set()
if os.path.exists(path):
    with open(path) as handle:
        for line in handle:
            key = line.split("=", 1)[0].strip() if "=" in line else ""
            if key in values:
                if key not in seen:
                    lines.append("%s=%s\n" % (key, values[key]))
                    seen.add(key)
                continue
            lines.append(line)
for key, value in values.items():
    if key not in seen:
        lines.append("%s=%s\n" % (key, value))
tmp = path + ".tmp"
with open(tmp, "w") as handle:
    handle.writelines(lines)
os.replace(tmp, path)
os.chmod(path, 0o644)
PY
}

backup() {
  local path="$1"
  [[ -e "$path" ]] && cp -a "$path" "${path}.bak.$(date +%s)" || true
}

write_stream() {
  local path="$1"
  local mode="$2"
  local tmp="${path}.tmp"
  mkdir -p "$(dirname "$path")"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv "$tmp" "$path"
}

valid_iface() {
  [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,40}$ && -d "/sys/class/net/$1" ]]
}

valid_ip() {
  python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$1" >/dev/null 2>&1
}

valid_prefix() {
  [[ "$1" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]]
}

valid_ssid() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]
}

valid_wpa() {
  [[ "$1" =~ ^[A-Za-z0-9_.@#%+=-]{8,63}$ ]]
}

valid_channel() {
  [[ "$1" =~ ^([1-9]|1[0-4])$ ]]
}

valid_unit() {
  case "$1" in
    dnsmasq|mist-imaging-api|apache2|mariadb|tftpd-hpa|mist-mistmetry-hotspot|mist-mistmetry-dnsmasq) return 0 ;;
    *) return 1 ;;
  esac
}

require_iface() {
  valid_iface "$1" || fail "invalid interface: ${1:-empty}"
}

require_ip() {
  valid_ip "$1" || fail "invalid IPv4 address: ${1:-empty}"
}

require_prefix() {
  valid_prefix "$1" || fail "invalid prefix length: ${1:-empty}"
}

require_wpa() {
  valid_wpa "$1" || fail "WPA passphrase must be 8-63 characters using letters, digits, dot, underscore, @ # % + = or -"
}

is_wireless() {
  local base="/sys/class/net/$1"
  [[ -d "$base/wireless" || -d "$base/phy80211" ]]
}

is_usb() {
  local device
  device=$(readlink -f "/sys/class/net/$1/device" 2>/dev/null || true)
  [[ "$device" == *"/usb"* ]]
}

require_usb_ethernet() {
  require_iface "$1"
  [[ ! -f "$1" ]] || true
  [[ "$(cat "/sys/class/net/$1/type" 2>/dev/null || true)" == "1" ]] || fail "$1 is not Ethernet"
  is_wireless "$1" && fail "$1 is wireless and cannot serve imaging DHCP"
  is_usb "$1" || fail "$1 is not USB-attached"
  [[ -x "$GUARD" ]] || fail "missing $GUARD"
  "$GUARD" validate "$1" >/dev/null || fail "$1 failed the USB Ethernet safety guard"
}

require_usb_wireless() {
  require_iface "$1"
  is_wireless "$1" || fail "$1 is not wireless"
  is_usb "$1" || fail "$1 is not USB-attached"
}

prefix_mask() {
  python3 -c 'import ipaddress,sys; print(str(ipaddress.IPv4Network("0.0.0.0/"+sys.argv[1]).netmask))' "$1"
}

netplan_apply() {
  command -v netplan >/dev/null 2>&1 || fail "netplan is not installed"
  netplan generate || fail "netplan generate failed"
  netplan apply || fail "netplan apply failed"
}

systemctl_maybe() {
  systemctl "$@" >/dev/null 2>&1 || true
}

run_status() {
  local imaging backhaul hotspot
  imaging=$(env_get JOG_USB_IFACE)
  backhaul=$(env_get JOG_BACKHAUL_IFACE)
  hotspot=$(env_get JOG_HOTSPOT_IFACE)
  emit \
    "imaging=$imaging" \
    "backhaul=$backhaul" \
    "hotspot=$hotspot" \
    "portalNetplan=$(test -f "$PORTAL_NETPLAN" && echo present || echo missing)" \
    "hotspotUnit=$(test -f "$HOTSPOT_UNIT" && echo present || echo missing)" \
    "dnsmasq=$(systemctl is-active dnsmasq 2>/dev/null || true)" \
    "imagingApi=$(systemctl is-active mist-imaging-api 2>/dev/null || true)"
}

run_imaging() {
  local iface ip prefix start end netmask router bootfile
  iface="${1:-}"
  ip="${2:-}"
  prefix="${3:-}"
  start="${4:-}"
  end="${5:-}"
  netmask="${6:-}"
  router="${7:-}"
  bootfile="${8:-ubuntu-signed/shimx64.efi}"
  require_usb_ethernet "$iface"
  require_ip "$ip"
  require_prefix "$prefix"
  require_ip "$start"
  require_ip "$end"
  require_ip "$netmask"
  require_ip "$router"
  [[ -n "$bootfile" && "$bootfile" != *..* ]] || fail "invalid boot file"
  env_set \
    JOG_USB_IFACE "$iface" \
    JOG_IMAGING_IP "$ip" \
    JOG_IMAGING_PREFIX "$prefix" \
    JOG_DHCP_START "$start" \
    JOG_DHCP_END "$end" \
    JOG_DHCP_NETMASK "$netmask" \
    JOG_DHCP_ROUTER "$router" \
    JOG_NEXT_SERVER "$ip" \
    JOG_DHCP_BOOTFILE "$bootfile"
  backup "$PORTAL_NETPLAN"
  write_stream "$PORTAL_NETPLAN" 0600 <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      addresses:
        - ${ip}/${prefix}
      dhcp4: false
      dhcp6: false
      optional: true
EOF
  ip link set "$iface" up
  ip addr flush dev "$iface"
  ip addr add "${ip}/${prefix}" dev "$iface"
  [[ -x "$RENDER" ]] || fail "missing $RENDER"
  "$RENDER" || fail "dnsmasq renderer failed"
  if grep -q "^# DHCP disabled" "$IMAGING_CONF" 2>/dev/null; then
    fail "safety guard disabled DHCP on every interface; check $IMAGING_CONF"
  fi
  systemctl_maybe restart dnsmasq
  emit "ok=true" "iface=$iface" "address=${ip}/${prefix}" "dhcp=$start-$end" "bootfile=$bootfile" "netplan=$PORTAL_NETPLAN"
}

run_backhaul() {
  local iface mode address prefix gateway dns ssid password hidden imaging hotspot route_quoted
  iface="${1:-}"
  mode="${2:-dhcp}"
  address="${3:-}"
  prefix="${4:-24}"
  gateway="${5:-}"
  dns="${6:-}"
  ssid="${7:-}"
  password="${8:-}"
  hidden="${9:-0}"
  require_iface "$iface"
  imaging=$(env_get JOG_USB_IFACE)
  hotspot=$(env_get JOG_HOTSPOT_IFACE)
  [[ "$iface" != "$imaging" ]] || fail "imaging NIC cannot be used as backhaul"
  [[ "$iface" != "$hotspot" ]] || fail "MISTMETRY hotspot NIC cannot be used as backhaul"
  case "$mode" in
    dhcp)
      backup "$BACKHAUL_NETPLAN"
      write_stream "$BACKHAUL_NETPLAN" 0600 <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 100
      optional: true
EOF
      ;;
    static)
      require_ip "$address"
      require_prefix "$prefix"
      require_ip "$gateway"
      [[ -z "$dns" ]] || valid_ip "${dns%% *}" || fail "invalid DNS address"
      backup "$BACKHAUL_NETPLAN"
      write_stream "$BACKHAUL_NETPLAN" 0600 <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      addresses:
        - ${address}/${prefix}
      routes:
        - to: 0.0.0.0/0
          via: ${gateway}
          metric: 100
      nameservers:
        addresses: [${dns:-1.1.1.1,8.8.8.8}]
      dhcp4: false
      dhcp6: false
      optional: true
EOF
      ;;
    wifi)
      require_ssid "$ssid"
      require_wpa "$password"
      backup "$BACKHAUL_NETPLAN"
      write_stream "$BACKHAUL_NETPLAN" 0600 <<EOF
network:
  version: 2
  wifis:
    ${iface}:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 100
      optional: true
      access-points:
        "$(yaml_quote "$ssid" | tr -d "'")":
          password: "$(yaml_quote "$password" | tr -d "'")"
          hidden: ${hidden}
EOF
      ;;
    *) fail "unknown backhaul mode: $mode" ;;
  esac
  netplan_apply
  env_set JOG_BACKHAUL_IFACE "$iface"
  emit "ok=true" "iface=$iface" "mode=$mode" "netplan=$BACKHAUL_NETPLAN"
}

run_hotspot() {
  local iface ssid passphrase channel ip prefix start end mask imaging backhaul hostapd dnsmasq
  iface="${1:-}"
  ssid="${2:-MISTMETRY}"
  passphrase="${3:-}"
  channel="${4:-6}"
  ip="${5:-192.168.254.1}"
  prefix="${6:-24}"
  start="${7:-192.168.254.100}"
  end="${8:-192.168.254.200}"
  require_usb_wireless "$iface"
  require_ssid "$ssid"
  require_wpa "$passphrase"
  valid_channel "$channel" || fail "invalid Wi-Fi channel"
  require_ip "$ip"
  require_prefix "$prefix"
  require_ip "$start"
  require_ip "$end"
  imaging=$(env_get JOG_USB_IFACE)
  backhaul=$(env_get JOG_BACKHAUL_IFACE)
  [[ "$iface" != "$imaging" ]] || fail "imaging NIC cannot be the hotspot"
  [[ "$iface" != "$backhaul" ]] || fail "backhaul NIC cannot be the hotspot"
  command -v hostapd >/dev/null 2>&1 || fail "hostapd is not installed"
  command -v hostapd_cli >/dev/null 2>&1 || fail "hostapd_cli is not installed"
  mask=$(prefix_mask "$prefix")
  backup "$HOTSPOT_HOSTAPD"
  write_stream "$HOTSPOT_HOSTAPD" 0600 <<EOF
interface=${iface}
driver=nl80211
ssid=${ssid}
hw_mode=g
channel=${channel}
ignore_broadcast_ssid=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_passphrase=${passphrase}
rsn_pairwise=CCMP
ieee80211n=1
EOF
  backup "$HOTSPOT_DNSMASQ"
  write_stream "$HOTSPOT_DNSMASQ" 0644 <<EOF
interface=${iface}
bind-interfaces
listen-address=${ip}
except-interface=lo
no-resolv
dhcp-range=${start},${end},${mask},12h
dhcp-option=option:router,${ip}
dhcp-option=option:dns-server,${ip}
address=/#/${ip}
dhcp-leasefile=${HOTSPOT_LEASES}
pid-file=/run/mist-jogometry-dnsmasq.pid
EOF
  backup "$HOTSPOT_UNIT"
  write_stream "$HOTSPOT_UNIT" 0644 <<EOF
[Unit]
Description=MISTMETRY hidden hotspot
After=network.target

[Service]
Type=simple
ExecStartPre=/usr/bin/ip link set ${iface} up
ExecStartPre=/usr/bin/ip addr flush dev ${iface}
ExecStartPre=/usr/bin/ip addr add ${ip}/${prefix} dev ${iface}
ExecStart=/usr/sbin/hostapd ${HOTSPOT_HOSTAPD}
ExecStopPost=/usr/bin/ip addr flush dev ${iface}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  backup "$HOTSPOT_DHCP_UNIT"
  write_stream "$HOTSPOT_DHCP_UNIT" 0644 <<EOF
[Unit]
Description=MISTMETRY hotspot DHCP
After=mist-mistmetry-hotspot.service
Requires=mist-mistmetry-hotspot.service

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --conf-file=${HOTSPOT_DNSMASQ} --no-daemon --keep-in-foreground
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  env_set \
    JOG_HOTSPOT_IFACE "$iface" \
    JOG_HOTSPOT_SSID "$ssid" \
    JOG_HOTSPOT_IP "$ip" \
    JOG_HOTSPOT_PREFIX "$prefix" \
    JOG_HOTSPOT_CHANNEL "$channel"
  systemctl daemon-reload
  systemctl_maybe disable mist-mistmetry-hotspot.service
  systemctl_maybe disable mist-mistmetry-dnsmasq.service
  systemctl enable mist-mistmetry-hotspot.service >/dev/null
  systemctl enable mist-mistmetry-dnsmasq.service >/dev/null
  systemctl restart mist-mistmetry-hotspot.service
  systemctl restart mist-mistmetry-dnsmasq.service
  emit "ok=true" "iface=$iface" "ssid=$ssid" "hidden=true" "address=${ip}/${prefix}" "channel=$channel"
}

require_ssid() {
  valid_ssid "$1" || fail "SSID must be 1-32 characters using letters, digits, dot, underscore or dash"
}

run_network_check() {
  local iface ip current
  iface="${1:-}"
  [[ -n "$iface" ]] || iface=$(env_get JOG_USB_IFACE)
  ip="${2:-$(env_get JOG_IMAGING_IP)}"
  require_usb_ethernet "$iface"
  [[ -z "$ip" ]] || require_ip "$ip"
  if [[ -n "$ip" ]]; then
    JOG_IMAGING_IP="$ip" JOG_DHCP_PROBE_SECONDS="${MIST_DHCP_PROBE_SECONDS:-${MIST_DHCP_PROBE_SECONDS:-${JOG_DHCP_PROBE_SECONDS:-2}}}" "$GUARD" check "$iface" "$ip" >/tmp/mist-portal-dhcp-check.txt
  else
    JOG_DHCP_PROBE_SECONDS="${MIST_DHCP_PROBE_SECONDS:-${MIST_DHCP_PROBE_SECONDS:-${JOG_DHCP_PROBE_SECONDS:-2}}}" "$GUARD" check "$iface" >/tmp/mist-portal-dhcp-check.txt
  fi
  current=$(tr '\n' ' ' </tmp/mist-portal-dhcp-check.txt)
  emit "ok=true" "iface=$iface" "detail=$current"
}

run_hotspot_clients() {
  local iface clients leases
  iface="${1:-$(env_get JOG_HOTSPOT_IFACE)}"
  require_iface "$iface"
  clients=$(hostapd_cli -i "$iface" all_sta 2>/dev/null || true)
  leases=$(tail -n 50 "$HOTSPOT_LEASES" 2>/dev/null || true)
  python3 - "$clients" "$leases" <<'PY'
import json
import sys

print(json.dumps({"ok": True, "clients": sys.argv[1][-8000:], "leases": sys.argv[2][-8000:]}))
PY
}

run_service() {
  local name action
  name="${1:-}"
  action="${2:-}"
  valid_unit "$name" || fail "unsupported service: $name"
  case "$action" in
    start|stop|restart) ;;
    *) fail "unsupported service action: $action" ;;
  esac
  systemctl "$action" "$name"
  emit "ok=true" "service=$name" "action=$action" "state=$(systemctl is-active "$name" 2>/dev/null || true)"
}

run_logs() {
  local unit out
  unit="${1:-}"
  valid_unit "$unit" || fail "unsupported log source: $unit"
  out=$(journalctl -u "$unit" -n 200 --no-pager -l 2>/dev/null || true)
  python3 - "$unit" "$out" <<'PY'
import json
import sys

print(json.dumps({"ok": True, "unit": sys.argv[1], "output": sys.argv[2][-30000:]}))
PY
}

run_safety() {
  local iface ip detail conf other ok
  iface="${1:-$(env_get JOG_USB_IFACE)}"
  ip="${2:-$(env_get JOG_IMAGING_IP)}"
  require_usb_ethernet "$iface"
  if [[ -n "$ip" ]]; then
    require_ip "$ip"
    JOG_IMAGING_IP="$ip" "$GUARD" check "$iface" "$ip" >/tmp/mist-portal-safety-check.txt
  else
    "$GUARD" check "$iface" >/tmp/mist-portal-safety-check.txt
  fi
  detail=$(tr '\n' ' ' </tmp/mist-portal-safety-check.txt)
  conf=$(cat "$IMAGING_CONF" 2>/dev/null || true)
  grep -q "^interface=${iface}$" <<<"$conf" || fail "dnsmasq is not bound to $iface"
  grep -q "^dhcp-range=" <<<"$conf" || fail "dnsmasq has no active DHCP range"
  ok=true
  for path in /sys/class/net/*; do
    other="${path##*/}"
    [[ "$other" == "lo" || "$other" == "$iface" ]] && continue
    [[ -e "$path/device" ]] || continue
    grep -q "^no-dhcp-interface=${other}$" <<<"$conf" || ok=false
  done
  [[ "$ok" == "true" ]] || fail "dnsmasq has not disabled DHCP on every non-imaging physical interface"
  emit "ok=true" "iface=$iface" "probe=$detail" "dhcp=enabled-only-on-$iface"
}

run_drivers() {
  local fog tftp smb drivers osres
  fog=$(test -d /opt/fog && echo present || echo missing)
  tftp=$(test -d /tftpboot && echo present || echo missing)
  smb=$(test -f /etc/samba/smb.conf && echo present || echo missing)
  drivers=$(test -d /opt/mist/provisioner/windows/drivers && echo present || echo missing)
  osres=$(test -f /opt/mist/provisioner/windows/Prepare-WindowsImage.ps1 && echo present || echo missing)
  emit "ok=true" "fog=$fog" "tftpboot=$tftp" "sambaConfig=$smb" "driverShare=$drivers" "windowsPayload=$osres"
}

valid_vm_name() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,63}$ ]]
}

valid_snapshot_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]{1,63}$ ]]
}

valid_iso_path() {
  local path="${1:-}"
  [[ -f "$path" && "$path" == /* && "$path" == *.iso ]] || return 1
  python3 - "$path" /var/lib/libvirt/isos /opt/mist/isos /srv/isos /home/mist/mist-iso-staging <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
roots = [os.path.realpath(item) for item in sys.argv[2:]]
sys.exit(0 if any(path == root or path.startswith(root + os.sep) for root in roots) else 1)
PY
}

vm_exists() {
  virsh dominfo "$1" >/dev/null 2>&1
}

vm_isos() {
  mkdir -p /var/lib/libvirt/isos
  python3 - <<'PY'
import glob
import json
import os

paths = []
for directory in ("/var/lib/libvirt/isos", "/opt/mist/isos", "/srv/isos"):
    for pattern in ("*.iso", "*.ISO"):
        paths.extend(glob.glob(os.path.join(directory, pattern)))
rows = []
for path in sorted(set(paths)):
    try:
        size = os.path.getsize(path)
    except OSError:
        size = 0
    rows.append({"path": path, "name": os.path.basename(path), "size": size})
print(json.dumps({"ok": True, "isos": rows}))
PY
}

vm_list() {
  python3 - <<'PY'
import json
import subprocess

result = subprocess.run(["virsh", "list", "--all"], capture_output=True, text=True, check=True)
rows = []
for line in result.stdout.splitlines()[2:]:
    parts = line.split(None, 2)
    if len(parts) >= 3:
        rows.append({"id": parts[0], "name": parts[1], "state": " ".join(parts[2].split())})
print(json.dumps({"ok": True, "vms": rows}))
PY
}

vm_active_disk() {
  local name="$1"
  python3 - "$name" <<'PY'
import subprocess
import sys
import xml.etree.ElementTree as ET

name = sys.argv[1]
try:
    text = subprocess.run(["virsh", "dumpxml", "--domain", name], capture_output=True, text=True, timeout=15).stdout
except (OSError, subprocess.SubprocessError):
    text = ""
try:
    root = ET.fromstring(text)
except ET.ParseError:
    sys.exit(0)
for disk in root.findall("./devices/disk"):
    if disk.get("device") not in (None, "disk"):
        continue
    source = disk.find("source")
    path = source.get("file") if source is not None else None
    if path and path.startswith("/"):
        print(path)
        break
PY
}

vm_owned_disks() {
  local name="$1"
  python3 - "$name" <<'PY'
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

name = sys.argv[1]
allowed = "/var/lib/libvirt/images"
try:
    text = subprocess.run(["virsh", "dumpxml", "--domain", name], capture_output=True, text=True, timeout=15).stdout
except (OSError, subprocess.SubprocessError):
    text = ""
try:
    root = ET.fromstring(text)
except ET.ParseError:
    sys.exit(0)

def owned(path):
    if not path or not path.startswith("/"):
        return False
    real = os.path.realpath(path)
    return real.startswith(allowed + os.sep) and os.path.basename(real).startswith(name + ".")

seen = set()
for disk in root.findall("./devices/disk"):
    if disk.get("device") not in (None, "disk"):
        continue
    source = disk.find("source")
    path = source.get("file") if source is not None else None
    while path:
        if owned(path) and path not in seen:
            seen.add(path)
            print(path)
        node = disk.find("backingStore")
        while node is not None:
            source = node.find("source")
            candidate = source.get("file") if source is not None else None
            if owned(candidate) and candidate not in seen:
                seen.add(candidate)
                print(candidate)
            node = node.find("backingStore")
        path = None
PY
}

vm_cdrom_targets() {
  local name="$1" with_media="$2"
  python3 - "$name" "$with_media" <<'PY'
import subprocess
import sys
import xml.etree.ElementTree as ET

name, mode = sys.argv[1:]
with_media = mode == "media"
empty_only = mode == "empty"
try:
    text = subprocess.run(["virsh", "dumpxml", "--domain", name], capture_output=True, text=True, timeout=15).stdout
except (OSError, subprocess.SubprocessError):
    text = ""
try:
    root = ET.fromstring(text)
except ET.ParseError:
    sys.exit(0)
for disk in root.findall("./devices/disk"):
    if disk.get("device") != "cdrom":
        continue
    target = disk.find("target")
    dev = target.get("dev") if target is not None else ""
    if not dev:
        continue
    source = disk.find("source")
    has_source = source is not None and bool(source.get("file"))
    if with_media and not has_source:
        continue
    if empty_only and has_source:
        continue
    print(dev)
PY
}

vm_detail() {
  local name="${1:-}"
  valid_vm_name "$name" || fail "invalid VM name"
  vm_exists "$name" || fail "domain not found: $name"
  python3 - "$name" <<'PY'
import json
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

name = sys.argv[1]

def run(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return ""

def as_int(value, default=0):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default

info = {}
for line in run(["virsh", "dominfo", "--domain", name]).splitlines():
    if ":" in line:
        key, value = line.split(":", 1)
        info[key.strip()] = value.strip()

def kib_mib(key):
    text = info.get(key, "")
    match = re.search(r"(\d+)", text)
    return as_int(match.group(1)) // 1024 if match else 0

os_type = ""
os_info = ""
disk_path = None
disk_size = None
iso_path = None
try:
    root = ET.fromstring(run(["virsh", "dumpxml", "--domain", name]))
    node = root.find("./os/type")
    if node is not None:
        os_type = node.text or ""
        arch = node.get("arch")
        if arch:
            os_type = os_type + " (" + arch + ")"
    ns = {"libosinfo": "http://libosinfo.org/xmlns/libvirt/domain/1.0"}
    node = root.find(".//libosinfo:os", ns)
    if node is not None:
        os_info = node.get("id", "")
    for disk in root.findall("./devices/disk"):
        source = disk.find("source")
        if source is None:
            continue
        path = source.get("file")
        if not path:
            continue
        if disk.get("device") in (None, "disk") and not disk_path:
            disk_path = path
        elif disk.get("device") == "cdrom" and not iso_path:
            iso_path = path
except ET.ParseError:
    pass

if disk_path and os.path.isfile(disk_path):
    try:
        result = subprocess.run(["qemu-img", "info", "-U", "--output=json", disk_path], capture_output=True, text=True, timeout=15)
        disk_size = json.loads(result.stdout).get("virtual-size") if result.returncode == 0 else None
    except (OSError, ValueError, subprocess.SubprocessError):
        disk_size = None

display = run(["virsh", "domdisplay", "--domain", name]).strip()
vnc_port = None
if display:
    address = display.split("://", 1)[-1].split("/")[0].strip("[]")
    number = address.rsplit(":", 1)[-1] if ":" in address else address
    if number.isdigit():
        value = int(number)
        vnc_port = 5900 + value if value < 100 else value

ips = []
for args in (["virsh", "domifaddr", "--domain", name, "--source", "agent"],
             ["virsh", "domifaddr", "--domain", name],
             ["virsh", "domaddr", "--domain", name]):
    for line in run(args).splitlines():
        for match in re.finditer(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", line):
            candidate = match.group(0)
            if candidate not in ips and not candidate.startswith(("0.", "127.", "169.254.")):
                ips.append(candidate)
    if ips:
        break

snapshots = []
table = run(["virsh", "snapshot-list", "--domain", name])
for line in table.splitlines()[2:]:
    match = re.match(r"^(\S+)\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\s+\S+)?)\s+(.+)$", line.strip())
    if match:
        snapshots.append({"name": match.group(1), "created": match.group(2).strip(), "state": match.group(3).strip()})
        continue
    parts = line.split(None, 2)
    if len(parts) >= 3:
        snapshots.append({"name": parts[0], "created": parts[1], "state": parts[2]})

stats = run(["virsh", "domstats", "--domain", name])
match = re.search(r"\bcpu\.time=(\d+)", stats)
cpu_time_ns = int(match.group(1)) if match else None
memory_used = kib_mib("Used memory")
memory_max = kib_mib("Max memory")

vm = {
    "name": name,
    "state": info.get("State", ""),
    "ramMiB": memory_max,
    "vcpus": as_int(info.get("CPU(s)")),
    "cpuTime": info.get("CPU time", ""),
    "cpuTimeNs": cpu_time_ns,
    "disk": {"path": disk_path, "size": disk_size},
    "diskPath": disk_path,
    "diskSize": disk_size,
    "iso": iso_path,
    "ip": ips[0] if ips else "",
    "ips": ips,
    "autostart": info.get("Autostart", "").lower().startswith("enable"),
    "autostartText": info.get("Autostart", ""),
    "display": display,
    "vncPort": vnc_port,
    "osType": os_type,
    "osInfo": os_info,
    "memory": {"usedMiB": memory_used, "maxMiB": memory_max},
    "memoryUsed": memory_used,
    "memoryMax": memory_max,
    "snapshots": snapshots,
}
print(json.dumps({"ok": True, "vm": vm}))
PY
}

vm_create() {
  local name ram vcpus disk_gb iso virtio_iso disk_bus network secure_boot tpm start network_type disk args
  name="${1:-}"
  ram="${2:-}"
  vcpus="${3:-}"
  disk_gb="${4:-}"
  iso="${5:-}"
  virtio_iso="${6:-}"
  disk_bus="${7:-virtio}"
  network="${8:-fog-capture}"
  secure_boot="${9:-1}"
  tpm="${10:-1}"
  start="${11:-1}"
  network_type="${12:-network}"
  valid_vm_name "$name" || fail "invalid VM name"
  [[ "$ram" =~ ^[0-9]+$ ]] && (( ram >= 2048 && ram <= 65536 )) || fail "RAM must be 2048-65536 MiB"
  [[ "$vcpus" =~ ^[0-9]+$ ]] && (( vcpus >= 1 && vcpus <= 32 )) || fail "vCPUs must be 1-32"
  [[ "$disk_gb" =~ ^[0-9]+$ ]] && (( disk_gb >= 20 && disk_gb <= 4096 )) || fail "disk size must be 20-4096 GiB"
  if [[ -n "$iso" ]]; then
    valid_iso_path "$iso" || fail "Windows ISO not found or outside an allowed ISO directory: $iso"
  fi
  [[ -z "$virtio_iso" ]] || valid_iso_path "$virtio_iso" || fail "VirtIO ISO not found or outside an allowed ISO directory: $virtio_iso"
  case "$disk_bus" in virtio|sata|nvme) ;; *) fail "unsupported disk bus: $disk_bus" ;; esac
  [[ "$network" =~ ^[A-Za-z0-9_.-]{1,40}$ ]] || fail "invalid virtual network"
  [[ "$secure_boot" == 0 || "$secure_boot" == 1 ]] || fail "invalid secure boot value"
  [[ "$tpm" == 0 || "$tpm" == 1 ]] || fail "invalid TPM value"
  [[ "$start" == 0 || "$start" == 1 ]] || fail "invalid start value"
  case "$network_type" in network|bridge) ;; *) fail "invalid NIC source type: $network_type" ;; esac
  if [[ "$network_type" == network ]]; then
    valid_net_name "$network" || fail "invalid virtual network"
    virsh net-info "$network" >/dev/null 2>&1 || fail "virtual network not found: $network"
  else
    valid_bridge_name "$network" || fail "invalid bridge name"
    [[ -d "/sys/class/net/$network/bridge" ]] || fail "host bridge not found: $network"
  fi
  vm_exists "$name" && fail "domain already exists: $name"
  if [[ "$network" == fog-capture ]]; then
    vm_fog_network_ensure "$network" >/dev/null
  fi
  mkdir -p /var/lib/libvirt/images /var/lib/libvirt/isos
  disk="/var/lib/libvirt/images/${name}.qcow2"
  [[ ! -e "$disk" ]] || fail "disk already exists: $disk"
  qemu-img create -f qcow2 "$disk" "${disk_gb}G" >/dev/null
  args=(
    virt-install
    --connect qemu:///system
    --name "$name"
    --memory "$ram"
    --vcpus "$vcpus"
    --cpu host
    --os-variant win11
    --machine q35
    --graphics vnc,listen=127.0.0.1
    --noautoconsole
    --network "${network_type}=${network},model=e1000e"
    --disk "path=${disk},format=qcow2,bus=${disk_bus}"
  )
  if [[ -n "$iso" ]]; then
    args+=(--cdrom "$iso")
  fi
  if [[ -n "$virtio_iso" ]]; then
    args+=(--disk "path=${virtio_iso},device=cdrom")
  fi
  if [[ "$secure_boot" == 1 ]]; then
    args+=(--features smm=on)
    args+=(--boot "loader=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd,loader.type=pflash,nvram_template=/usr/share/OVMF/OVMF_VARS_4M.ms.fd,bootmenu.enable=yes")
  else
    args+=(--boot uefi)
  fi
  if [[ "$tpm" == 1 ]]; then
    args+=(--tpm backend.type=emulator,backend.version=2.0,model=tpm-tis)
  fi
  if [[ "$start" == 1 ]]; then
    "${args[@]}" >/tmp/mist-portal-virt-install.log 2>&1 || {
      tail -n 40 /tmp/mist-portal-virt-install.log >&2
      fail "virt-install failed"
    }
  else
    "${args[@]}" --print-xml >/tmp/mist-portal-vm.xml 2>/tmp/mist-portal-virt-install.log || {
      tail -n 40 /tmp/mist-portal-virt-install.log >&2
      fail "virt-install XML generation failed"
    }
    python3 - /tmp/mist-portal-vm.xml /tmp/mist-portal-vm-first.xml <<'XML' || fail "could not normalize virt-install XML"
import sys
text = open(sys.argv[1], errors="replace").read()
second = text.find("<domain", text.find("<domain") + 1)
open(sys.argv[2], "w").write(text[:second] if second > 0 else text)
XML
    virsh define /tmp/mist-portal-vm-first.xml >/tmp/mist-portal-virsh-define.log 2>&1 || {
      tail -n 40 /tmp/mist-portal-virsh-define.log >&2
      fail "virsh define failed"
    }
  fi
  emit "ok=true" "name=$name" "disk=$disk" "ram=$ram" "vcpus=$vcpus" "diskGiB=$disk_gb" "secureBoot=$secure_boot" "tpm=$tpm" "started=$start"
}

vm_attach_iso() {
  local name="$1" iso="$2" target disk_targets
  valid_iso_path "$iso" || fail "ISO not found or outside an allowed ISO directory: $iso"
  mapfile -t disk_targets < <(vm_cdrom_targets "$name" empty)
  if (( ${#disk_targets[@]} > 0 )); then
    virsh change-media --domain "$name" --path "${disk_targets[0]}" --source "$iso" --insert --current >/dev/null
    return
  fi
  mapfile -t disk_targets < <(vm_cdrom_targets "$name" any)
  if (( ${#disk_targets[@]} > 0 )); then
    virsh change-media --domain "$name" --path "${disk_targets[0]}" --eject --current >/dev/null 2>&1 || true
    virsh change-media --domain "$name" --path "${disk_targets[0]}" --source "$iso" --insert --current >/dev/null
    return
  fi
  target=$(python3 - <<'PY'
import subprocess
import sys

name = sys.argv[1]
try:
    xml = subprocess.run(["virsh", "dumpxml", "--domain", name], capture_output=True, text=True, timeout=15).stdout
except (OSError, subprocess.SubprocessError):
    xml = ""
used = set()
import re
used.update(re.findall(r"<target[^>]*dev=['\"]([^'\"]+)['\"]", xml))
for index in range(26):
    candidate = "sd" + chr(ord("b") + index)
    if candidate not in used:
        print(candidate)
        break
PY
  )
  [[ -n "$target" ]] || fail "no free CD-ROM target for $name"
  virsh attach-disk --domain "$name" --source "$iso" --target "$target" --type cdrom --mode readonly --current >/dev/null
}

vm_detach_iso() {
  local name="$1" target ejected=0
  local -a targets=()
  mapfile -t targets < <(vm_cdrom_targets "$name" media)
  for target in "${targets[@]}"; do
    virsh change-media --domain "$name" --path "$target" --eject --current >/dev/null 2>&1 && ejected=$((ejected + 1))
  done
  echo "ejected=$ejected"
}

vm_clone() {
  local source="$1" clone="$2" source_disk new_disk xml_tmp
  valid_vm_name "$clone" || fail "invalid clone name"
  vm_exists "$clone" && fail "domain already exists: $clone"
  [[ ! -e "/var/lib/libvirt/images/${clone}.qcow2" ]] || fail "clone disk already exists"
  if command -v virt-clone >/dev/null 2>&1; then
    virt-clone --original "$source" --name "$clone" --auto-clone >/tmp/mist-portal-virt-clone.log 2>&1 || {
      tail -n 30 /tmp/mist-portal-virt-clone.log >&2
      fail "virt-clone failed"
    }
    return
  fi
  source_disk=$(vm_active_disk "$source")
  [[ -n "$source_disk" && -f "$source_disk" ]] || fail "source VM has no file-backed disk"
  new_disk="/var/lib/libvirt/images/${clone}.qcow2"
  qemu-img create -f qcow2 -F qcow2 -b "$source_disk" "$new_disk" >/dev/null || fail "could not create clone disk"
  xml_tmp=$(mktemp)
  if ! python3 - "$source" "$clone" "$new_disk" >"$xml_tmp" <<'PY'
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET

source, name, disk = sys.argv[1:]
xml = subprocess.run(["virsh", "dumpxml", "--domain", source], capture_output=True, text=True, check=True, timeout=15).stdout
root = ET.fromstring(xml)
root.find("name").text = name
root.find("uuid").text = str(uuid.uuid4())
for item in root.findall("./devices/disk"):
    if item.get("device") in (None, "disk"):
        source = item.find("source")
        if source is not None:
            source.set("file", disk)
        for backing in item.findall("backingStore"):
            item.remove(backing)
        break
for interface in root.findall("./devices/interface"):
    mac = interface.find("mac")
    if mac is not None:
        interface.remove(mac)
print(ET.tostring(root, encoding="unicode"))
PY
  then
    rm -f "$xml_tmp" "$new_disk"
    fail "could not render clone XML"
  fi
  virsh define "$xml_tmp" >/dev/null || {
    rm -f "$xml_tmp" "$new_disk"
    fail "virsh define failed for clone"
  }
  rm -f "$xml_tmp"
}

vm_delete() {
  local name="$1" disk
  local -a disks=()
  mapfile -t disks < <(vm_owned_disks "$name")
  virsh destroy "$name" >/dev/null 2>&1 || true
  virsh undefine "$name" --nvram --snapshots-metadata >/dev/null
  for disk in "${disks[@]}"; do
    [[ -n "$disk" ]] && rm -f -- "$disk"
  done
  echo "deletedDisks=${#disks[@]}"
}

vm_action() {
  local name="${1:-}" action="${2:-}" extra="${3:-}" detail
  valid_vm_name "$name" || fail "invalid VM name"
  vm_exists "$name" || fail "domain not found: $name"
  case "$action" in
    start) virsh start "$name" >/dev/null ;;
    shutdown) virsh shutdown "$name" >/dev/null ;;
    force-off|forceoff|destroy) virsh destroy "$name" >/dev/null ;;
    reboot) virsh reboot "$name" >/dev/null ;;
    pause|suspend) virsh suspend "$name" >/dev/null ;;
    resume) virsh resume "$name" >/dev/null ;;
    autostart-on) virsh autostart "$name" >/dev/null ;;
    autostart-off) virsh autostart --disable "$name" >/dev/null ;;
    display) emit "ok=true" "name=$name" "display=$(virsh domdisplay --domain "$name" 2>/dev/null || true)"; return ;;
    detach-iso) detail=$(vm_detach_iso "$name") ;;
    attach-iso) vm_attach_iso "$name" "$extra" ;;
    clone) vm_clone "$name" "$extra" ;;
    delete) detail=$(vm_delete "$name") ;;
    *) fail "unsupported VM action: $action" ;;
  esac
  emit "ok=true" "name=$name" "action=$action" "state=$(virsh domstate "$name" 2>/dev/null || true)" "${detail:-detail=none}"
}

vm_snapshot() {
  local action="${1:-}" name="${2:-}" snap="${3:-}"
  valid_vm_name "$name" || fail "invalid VM name"
  vm_exists "$name" || fail "domain not found: $name"
  case "$action" in
    list)
      python3 - "$name" <<'PY'
import json
import re
import subprocess
import sys

name = sys.argv[1]
result = subprocess.run(["virsh", "snapshot-list", "--domain", name], capture_output=True, text=True)
snapshots = []
for line in result.stdout.splitlines()[2:]:
    match = re.match(r"^(\S+)\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\s+\S+)?)\s+(.+)$", line.strip())
    if match:
        snapshots.append({"name": match.group(1), "created": match.group(2).strip(), "state": match.group(3).strip()})
    else:
        parts = line.split(None, 2)
        if len(parts) >= 3:
            snapshots.append({"name": parts[0], "created": parts[1], "state": parts[2]})
print(json.dumps({"ok": True, "name": name, "action": "list", "snapshots": snapshots}))
PY
      return
      ;;
    create)
      valid_snapshot_name "$snap" || fail "invalid checkpoint name"
      virsh snapshot-create-as --domain "$name" --name "$snap" --description "MIST portal checkpoint" --disk-only --atomic >/dev/null
      ;;
    revert|restore)
      valid_snapshot_name "$snap" || fail "invalid checkpoint name"
      virsh snapshot-revert --domain "$name" --snapshotname "$snap" --running >/dev/null
      ;;
    delete)
      valid_snapshot_name "$snap" || fail "invalid checkpoint name"
      virsh snapshot-delete --domain "$name" --snapshotname "$snap" --children >/dev/null
      ;;
    *) fail "unsupported checkpoint action: $action" ;;
  esac
  emit "ok=true" "name=$name" "action=$action" "checkpoint=$snap"
}

vm_resources() {
  local name="${1:-}" ram="${2:-}" vcpus="${3:-}" disk_gb="${4:-}" disk_path ram_kib disk_kib state detail=""
  valid_vm_name "$name" || fail "invalid VM name"
  vm_exists "$name" || fail "domain not found: $name"
  [[ "$ram" =~ ^[0-9]+$ ]] && (( ram >= 2048 && ram <= 65536 )) || fail "RAM must be 2048-65536 MiB"
  [[ "$vcpus" =~ ^[0-9]+$ ]] && (( vcpus >= 1 && vcpus <= 32 )) || fail "vCPUs must be 1-32"
  ram_kib=$((ram * 1024))
  virsh setmaxmem --domain "$name" --size "$ram_kib" --config >/dev/null 2>&1 || true
  virsh setmem --domain "$name" --size "$ram_kib" --config >/dev/null
  virsh setvcpus --domain "$name" --count "$vcpus" --maximum --config >/dev/null 2>&1 || true
  virsh setvcpus --domain "$name" --count "$vcpus" --config >/dev/null
  if [[ -n "$disk_gb" ]]; then
    [[ "$disk_gb" =~ ^[0-9]+$ ]] && (( disk_gb >= 20 && disk_gb <= 4096 )) || fail "disk size must be 20-4096 GiB"
    disk_path=$(vm_active_disk "$name")
    [[ -n "$disk_path" && -f "$disk_path" ]] || fail "VM has no file-backed disk to resize"
    disk_kib=$((disk_gb * 1024 * 1024))
    state=$(virsh domstate "$name" 2>&1 || true)
    if [[ "$state" == running ]]; then
      virsh blockresize --domain "$name" --path "$disk_path" --size "$disk_kib" >/dev/null || fail "virsh blockresize failed"
      qemu-img resize "$disk_path" "${disk_gb}G" >/dev/null 2>&1 || detail="guest block resized; qemu-img resize skipped because the image is in use"
    else
      qemu-img resize "$disk_path" "${disk_gb}G" >/dev/null || fail "qemu-img resize failed"
    fi
  fi
  emit "ok=true" "name=$name" "ramMiB=$ram" "vcpus=$vcpus" "diskGiB=${disk_gb:-unchanged}" "detail=${detail:-applied to persistent configuration}"
}

vm_console() {
  local name="${1:-}" display
  valid_vm_name "$name" || fail "invalid VM name"
  vm_exists "$name" || fail "domain not found: $name"
  display=$(virsh domdisplay --domain "$name" 2>/dev/null || true)
  [[ -n "$display" ]] || fail "no VNC display assigned to $name; start the VM first"
  JOG_VNC_HOST="${MIST_VNC_HOST:-${MIST_VNC_HOST:-${JOG_VNC_HOST:-10.42.0.1}}}" python3 - "$name" "$display" <<'PY'
import json
import os
import re
import sys

name, display = sys.argv[1:]
address = display.split("://", 1)[-1].split("/")[0].strip("[]")
number = address.rsplit(":", 1)[-1] if ":" in address else address
if not number.isdigit():
    raise SystemExit("invalid display address: %s" % display)
value = int(number)
port = 5900 + value if value < 100 else value
target_file = "/run/mist-vnc-targets"
lines = []
try:
    with open(target_file) as handle:
        for line in handle:
            if line.strip() and not line.startswith(name + ":"):
                lines.append(line.rstrip("\n"))
except OSError:
    pass
lines.append("%s: 127.0.0.1:%d" % (name, port))
tmp = target_file + ".tmp.%d" % os.getpid()
with open(tmp, "w") as handle:
    handle.write("\n".join(lines) + "\n")
os.chmod(tmp, 0o600)
os.replace(tmp, target_file)
host = os.environ.get("MIST_VNC_HOST", os.environ.get("MIST_VNC_HOST", os.environ.get("JOG_VNC_HOST", "10.42.0.1")))
url = "https://%s:6080/vnc.html?autoconnect=1&reconnect=1&resize=scale&path=websockify%%3Ftoken%%3D%s" % (host, name)
print(json.dumps({"ok": True, "name": name, "display": display, "host": "127.0.0.1", "port": port, "token": name, "url": url, "targets": target_file}))
PY
}

vm_hardware() {
  local name="${1:-}" xml
  valid_vm_name "$name" || fail "invalid VM name"
  vm_exists "$name" || fail "domain not found: $name"
  xml=$(vm_xml_file "$name")
  python3 - "$name" "$xml" <<'PY' || { rm -f "$xml"; fail "could not read hardware for $name"; }
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

name, path = sys.argv[1:]
try:
    root = ET.fromstring(open(path).read())
except (OSError, ET.ParseError):
    raise SystemExit("could not parse domain XML")

def as_mib(node):
    if node is None or not (node.text or "").strip().isdigit():
        return 0
    value = int(node.text.strip())
    return value // 1024 if node.get("unit", "KiB") == "KiB" else value // 1048576

def attr(node, key, default=""):
    return node.get(key, default) if node is not None else default

os_node = root.find("os")
type_node = os_node.find("type") if os_node is not None else None
machine_attr = attr(type_node, "machine")
if "q35" in machine_attr:
    machine_type = "q35"
elif "i440fx" in machine_attr:
    machine_type = "i440fx"
else:
    machine_type = machine_attr or "unknown"
firmware_feature = None
if os_node is not None:
    for feature in os_node.findall("./firmware/feature"):
        if feature.get("name") == "secure-boot" and str(feature.get("enabled", "no")).lower() in ("yes", "on", "1"):
            firmware_feature = True
loader = os_node.find("loader") if os_node is not None else None
secure_node = os_node.find("secureBoot") if os_node is not None else None
firmware = "uefi" if (attr(os_node, "firmware") == "efi" or loader is not None or firmware_feature) else "bios"
secure_boot = bool(firmware_feature or (secure_node is not None and str(secure_node.get("state", "off")).lower() in ("yes", "on", "1")) or (loader is not None and str(loader.get("secure", "no")).lower() in ("yes", "on", "1")))
tpm_node = root.find("./devices/tpm")
tpm_backend = tpm_node.find("backend") if tpm_node is not None else None
tpm = attr(tpm_backend, "version") or "none" if tpm_node is not None else "none"

cpu_node = root.find("cpu")
mode = attr(cpu_node, "mode")
cpu_model_node = cpu_node.find("model") if cpu_node is not None else None
if mode in ("host-model", "host-passthrough"):
    cpu_model = mode
elif cpu_model_node is not None and (cpu_model_node.text or "").strip():
    cpu_model = (cpu_model_node.text or "").strip()
else:
    cpu_model = "qemu64"
topology = cpu_node.find("topology") if cpu_node is not None else None
vcpu_node = root.find("vcpu")
vcpu_count = 0
if vcpu_node is not None and (vcpu_node.text or "").strip().isdigit():
    vcpu_count = int(vcpu_node.text.strip())
cpu_features = []
if cpu_node is not None:
    for feature in cpu_node.findall("feature"):
        cpu_features.append({"name": feature.get("name", ""), "policy": feature.get("policy", "")})

devices = root.find("devices")
memballoon = devices.find("memballoon") if devices is not None else None
balloon_enabled = memballoon is not None and attr(memballoon, "model", "none") not in ("", "none")
video_node = devices.find("video") if devices is not None else None
video_model = video_node.find("model") if video_node is not None else None
acceleration = video_node.find("acceleration") if video_node is not None else None
audio_choices = {"none", "ich9", "ac97", "ich6", "usb", "virtio", "spice"}
sound_node = devices.find("sound") if devices is not None else None
audio_node = devices.find("audio") if devices is not None else None
audio_model = attr(sound_node, "model") or attr(audio_node, "type") or "none"
if audio_model not in audio_choices:
    audio_model = "none"
input_types = set(attr(item, "type") for item in devices.findall("input")) if devices is not None else set()
usb_controllers = [item for item in devices.findall("controller") if item.get("type") == "usb"] if devices is not None else []
graphics_node = devices.find("graphics") if devices is not None else None
graphics_listen = ""
if graphics_node is not None:
    listen_node = graphics_node.find("listen")
    graphics_listen = attr(listen_node, "address") or attr(graphics_node, "listen")
rng_node = devices.find("rng") if devices is not None else None
rng_backend = rng_node.find("backend") if rng_node is not None else None
watchdog_node = devices.find("watchdog") if devices is not None else None

boot_order = [item.get("dev", "") for item in os_node.findall("boot") if item.get("dev")] if os_node is not None else []
ordered = []
if devices is not None:
    for disk in devices.findall("disk"):
        item = disk.find("boot")
        if item is not None and str(item.get("order", "")).isdigit():
            kind = "cdrom" if disk.get("device") == "cdrom" else "hd"
            ordered.append((int(item.get("order")), kind))
    for nic in devices.findall("interface"):
        item = nic.find("boot")
        if item is not None and str(item.get("order", "")).isdigit():
            ordered.append((int(item.get("order")), "network"))
if ordered:
    boot_order = [kind for _, kind in sorted(ordered, key=lambda pair: pair[0])]
bootmenu = os_node.find("bootmenu") if os_node is not None else None
boot_menu = bootmenu is not None and str(bootmenu.get("enable", "no")).lower() in ("yes", "on", "1")

disks = []
nics = []
hostdevs = []
controllers = []
if devices is not None:
    for disk in devices.findall("disk"):
        target = disk.find("target")
        source = disk.find("source")
        driver = disk.find("driver")
        boot = disk.find("boot")
        disks.append({
            "target": attr(target, "dev"),
            "bus": attr(target, "bus"),
            "device": disk.get("device", "disk"),
            "type": disk.get("type", "file"),
            "path": attr(source, "file"),
            "format": attr(driver, "type"),
            "bootOrder": int(boot.get("order")) if boot is not None and str(boot.get("order", "")).isdigit() else None,
            "readonly": disk.find("readonly") is not None,
        })
    for nic in devices.findall("interface"):
        mac = nic.find("mac")
        source = nic.find("source")
        model = nic.find("model")
        target = nic.find("target")
        nics.append({
            "mac": attr(mac, "address"),
            "type": nic.get("type", ""),
            "source": attr(source, "network") or attr(source, "bridge") or attr(source, "dev"),
            "model": attr(model, "type"),
            "target": attr(target, "dev"),
        })
    for item in devices.findall("hostdev"):
        source = item.find("source")
        address = source.find("address") if source is not None else None
        vendor = source.find("vendor") if source is not None else None
        product = source.find("product") if source is not None else None
        hostdevs.append({
            "type": item.get("type", ""),
            "mode": item.get("mode", ""),
            "bus": attr(address, "bus"),
            "device": attr(address, "device"),
            "vendorId": attr(vendor, "id"),
            "productId": attr(product, "id"),
        })
    for item in devices.findall("controller"):
        controllers.append({"type": item.get("type", ""), "index": item.get("index", ""), "model": item.get("model", "")})

if topology is not None:
    sockets = int(attr(topology, "sockets", "0") or 0)
    cores = int(attr(topology, "cores", "0") or 0)
    threads = int(attr(topology, "threads", "0") or 0)
else:
    sockets = 1 if vcpu_count else 0
    cores = vcpu_count
    threads = 1 if vcpu_count else 0
vram_text = attr(video_model, "vram", "0")
vram_mib = int(vram_text) // 1024 if vram_text.isdigit() else 0
heads_text = attr(video_model, "heads", "0")
port_text = attr(graphics_node, "port", "-1")
hardware = {
    "machine": {"type": machine_type, "firmware": firmware, "secureBoot": secure_boot, "tpm": tpm},
    "cpu": {
        "model": cpu_model,
        "customModel": (cpu_model_node.text or "").strip() if cpu_model_node is not None else "",
        "sockets": sockets,
        "cores": cores,
        "threads": threads,
        "features": cpu_features,
    },
    "memory": {
        "ramMiB": as_mib(root.find("memory")),
        "currentMiB": as_mib(root.find("currentMemory")),
        "balloonMiB": as_mib(root.find("currentMemory")) if balloon_enabled else 0,
        "balloonEnabled": balloon_enabled,
    },
    "video": {
        "model": attr(video_model, "type") or "none",
        "vramMiB": vram_mib,
        "heads": int(heads_text) if heads_text.isdigit() else 0,
        "accel3d": str(attr(acceleration, "accel3d", "no")).lower() in ("yes", "on", "1"),
    },
    "audio": {"model": audio_model},
    "input": {"tablet": "tablet" in input_types, "mouse": "mouse" in input_types, "keyboard": "keyboard" in input_types},
    "usbController": {"model": attr(usb_controllers[0], "model", "none") if usb_controllers else "none"},
    "graphics": {
        "type": attr(graphics_node, "type") or "none",
        "listen": graphics_listen,
        "port": int(port_text) if port_text.lstrip("-").isdigit() else -1,
    },
    "rng": {"enabled": rng_node is not None, "model": attr(rng_backend, "model", "none")},
    "watchdog": {
        "enabled": watchdog_node is not None,
        "model": attr(watchdog_node, "model", "none"),
        "action": attr(watchdog_node, "action", "none"),
    },
    "boot": {"order": boot_order, "menu": boot_menu},
    "devices": {"disks": disks, "nics": nics, "hostdevs": hostdevs, "controllers": controllers},
}
print(json.dumps({"ok": True, "name": name, "hardware": hardware}))
PY
  rm -f "$xml"
}

vm_hardware_apply() {
  local name="${1:-}" patch="${2:-}" xml out result detail
  valid_vm_name "$name" || fail "invalid VM name"
  vm_exists "$name" || fail "domain not found: $name"
  [[ -n "$patch" ]] || fail "hardware patch JSON is required"
  xml=$(vm_xml_file "$name")
  out=$(mktemp /tmp/mist-vm-hardware.XXXXXX.xml)
  result=$(python3 - "$name" "$xml" "$out" "$patch" 2>&1 <<'PY'
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")
name, source_path, output_path, raw_patch = sys.argv[1:]
try:
    patch = json.loads(raw_patch)
except ValueError:
    raise SystemExit("hardware patch must be valid JSON")
if not isinstance(patch, dict):
    raise SystemExit("hardware patch must be a JSON object")
allowed = {
    "machine": {"type", "firmware", "secureBoot", "tpm"},
    "cpu": {"model", "customModel", "sockets", "cores", "threads", "features"},
    "memory": {"ramMiB", "currentMiB", "balloonEnabled"},
    "video": {"model", "vramMiB", "heads", "accel3d"},
    "audio": {"model"},
    "input": {"tablet", "mouse", "keyboard"},
    "usbController": {"model"},
    "graphics": {"type", "listen", "port"},
    "rng": {"enabled", "model"},
    "watchdog": {"enabled", "model", "action"},
    "boot": {"order", "menu"},
}
unknown = sorted(set(patch) - set(allowed))
if unknown:
    raise SystemExit("unsupported hardware section: " + ", ".join(unknown))

def need(condition, message):
    if not condition:
        raise SystemExit(message)

def as_bool(value, label):
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if text in ("1", "true", "yes", "on"):
        return True
    if text in ("0", "false", "no", "off"):
        return False
    raise SystemExit(label + " must be true or false")

def as_int(value, low, high, label):
    if isinstance(value, bool):
        raise SystemExit(label + " must be an integer")
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise SystemExit(label + " must be an integer")
    need(low <= number <= high, label + " must be " + str(low) + "-" + str(high))
    return number

def choice(value, options, label):
    text = str(value if value is not None else "").strip()
    need(text in options, "unsupported " + label + ": " + text)
    return text

def group(key):
    value = patch.get(key)
    if value is not None and not isinstance(value, dict):
        raise SystemExit(key + " must be a JSON object")
    return value or {}

for key, value in patch.items():
    extra = sorted(set(value) - allowed[key]) if isinstance(value, dict) else []
    if extra:
        raise SystemExit("unsupported " + key + " field: " + ", ".join(extra))

inactive_keys = {"machine", "cpu", "video", "audio", "input", "usbController", "rng", "watchdog"}
needs_inactive = bool(set(patch) & inactive_keys)
state = ""
try:
    state = subprocess.run(["virsh", "domstate", "--domain", name], capture_output=True, text=True, timeout=15).stdout.strip()
except (OSError, subprocess.SubprocessError):
    pass
if needs_inactive and state.lower() not in ("shut off", "shutoff", "stopped", "inactive"):
    raise SystemExit("shut down VM " + name + " before changing machine, CPU, video, audio, input, USB, RNG or watchdog hardware (state: " + (state or "unknown") + ")")

try:
    original_text = open(source_path).read()
    root = ET.fromstring(original_text)
except (OSError, ET.ParseError):
    raise SystemExit("could not parse domain XML")
devices = root.find("devices")
need(devices is not None, "domain has no devices section")
os_node = root.find("os")
need(os_node is not None, "domain has no os section")
applied = []

def insert_ordered(parent, node, order):
    priority = order.index(node.tag) if node.tag in order else len(order)
    position = len(parent)
    for index, child in enumerate(parent):
        child_priority = order.index(child.tag) if child.tag in order else len(order)
        if child_priority > priority:
            position = index
            break
    parent.insert(position, node)
    return node

OS_ORDER = ["type", "loader", "nvram", "firmware", "bootmenu", "boot", "secureBoot"]
DEV_ORDER = ["emulator", "controller", "disk", "filesystem", "interface", "input", "tpm", "graphics", "audio", "sound", "video", "hostdev", "rng", "watchdog", "memballoon", "channel", "serial", "console", "redirdev"]

def replace_os(tag, attributes, text=None):
    for node in os_node.findall(tag):
        os_node.remove(node)
    node = ET.Element(tag, attributes)
    if text is not None:
        node.text = text
    insert_ordered(os_node, node, OS_ORDER)
    return node

def mib_of(tag):
    node = root.find(tag)
    if node is None or not (node.text or "").strip().isdigit():
        return 0
    value = int(node.text.strip())
    return value // 1024 if node.get("unit", "KiB") == "KiB" else value // 1048576

def machine_name(kind):
    machines = []
    try:
        caps = subprocess.run(["virsh", "domcapabilities"], capture_output=True, text=True, timeout=20).stdout
        cap_root = ET.fromstring(caps)
        prefix = "pc-q35-" if kind == "q35" else "pc-i440fx-"
        for item in cap_root.findall(".//machine"):
            value = item.get("canonical") or (item.text or "").strip()
            if value.startswith(prefix):
                machines.append(value)
    except (ET.ParseError, OSError, subprocess.SubprocessError):
        pass
    machines.sort(key=lambda value: [int(part) for part in re.findall(r"\d+", value)])
    return machines[-1] if machines else (kind if kind == "q35" else "i440fx")

def first_file(paths):
    for path in paths:
        if os.path.isfile(path):
            return path
    return paths[0]

def strip_pci_addresses(node):
    for child in list(node):
        if child.tag == "address" and child.get("type") == "pci":
            node.remove(child)
        else:
            strip_pci_addresses(child)

def rebuild_pci(kind):
    for node in devices.findall("controller"):
        if node.get("type") == "pci":
            devices.remove(node)
    root_model = "pcie-root" if kind == "q35" else "pci-root"
    insert_ordered(devices, ET.Element("controller", type="pci", index="0", model=root_model), DEV_ORDER)
    if kind == "q35":
        for index in range(1, 5):
            port = ET.Element("controller", type="pci", index=str(index), model="pcie-root-port")
            ET.SubElement(port, "model", name="pcie-root-port")
            insert_ordered(devices, port, DEV_ORDER)
    for node in list(devices):
        strip_pci_addresses(node)

if "machine" in patch:
    data = group("machine")
    current_feature = os_node.find("secureBoot")
    current_secure = current_feature is not None and str(current_feature.get("state", "off")).lower() in ("yes", "on", "1")
    requested_secure = as_bool(data["secureBoot"], "secureBoot") if "secureBoot" in data else current_secure
    type_node = os_node.find("type")
    need(type_node is not None, "domain has no os type")
    if "type" in data:
        kind = choice(data["type"], {"q35", "i440fx"}, "machine type")
        current_machine = type_node.get("machine", "")
        current_kind = "q35" if current_machine.startswith("pc-q35") else "i440fx" if current_machine.startswith("pc-i440fx") else ""
        type_node.set("machine", machine_name(kind))
        if current_kind and current_kind != kind:
            rebuild_pci(kind)
        applied.append("machine.type")
    if "firmware" in data:
        firmware = choice(data["firmware"], {"uefi", "bios"}, "firmware")
        if firmware == "uefi":
            os_node.set("firmware", "efi")
            loader = os_node.find("loader")
            if loader is None:
                loader = replace_os("loader", {"readonly": "yes", "type": "pflash"}, first_file([
                    "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd" if requested_secure else "/usr/share/OVMF/OVMF_CODE_4M.fd",
                    "/usr/share/OVMF/OVMF_CODE.secboot.fd" if requested_secure else "/usr/share/OVMF/OVMF_CODE.fd",
                ]))
            loader.set("type", "pflash")
            loader.set("readonly", "yes")
            if requested_secure:
                loader.set("secure", "yes")
            nvram = os_node.find("nvram")
            if nvram is None:
                template = first_file([
                    "/usr/share/OVMF/OVMF_VARS_4M.ms.fd" if requested_secure else "/usr/share/OVMF/OVMF_VARS_4M.fd",
                    "/usr/share/OVMF/OVMF_VARS.ms.fd" if requested_secure else "/usr/share/OVMF/OVMF_VARS.fd",
                ])
                replace_os("nvram", {"template": template})
        else:
            os_node.attrib.pop("firmware", None)
            for tag in ("loader", "nvram", "secureBoot"):
                for node in os_node.findall(tag):
                    os_node.remove(node)
            firmware_node = os_node.find("firmware")
            if firmware_node is not None:
                os_node.remove(firmware_node)
        applied.append("machine.firmware")
    if "secureBoot" in data:
        enabled = as_bool(data["secureBoot"], "secureBoot")
        loader = os_node.find("loader")
        effective_uefi = os_node.get("firmware") == "efi" or loader is not None
        need(not enabled or effective_uefi, "secure boot requires UEFI firmware")
        if enabled:
            features = root.find("features")
            if features is None:
                features = ET.Element("features")
                root.insert(list(root).index(os_node) + 1, features)
            smm = features.find("smm")
            if smm is None:
                smm = ET.SubElement(features, "smm")
            smm.set("state", "on")
            if loader is not None:
                loader.set("secure", "yes")
        replace_os("secureBoot", {"state": "on" if enabled else "off"})
        applied.append("machine.secureBoot")
    if "tpm" in data:
        version = choice(data["tpm"], {"2.0", "1.2", "none"}, "TPM version")
        for node in devices.findall("tpm"):
            devices.remove(node)
        if version != "none":
            tpm = ET.Element("tpm", model="tpm-tis")
            ET.SubElement(tpm, "backend", type="emulator", version=version)
            insert_ordered(devices, tpm, DEV_ORDER)
        applied.append("machine.tpm")

if "cpu" in patch:
    data = group("cpu")
    cpu_node = root.find("cpu")
    if cpu_node is None:
        cpu_node = ET.Element("cpu")
        vcpu = root.find("vcpu")
        root.insert(list(root).index(vcpu) + 1 if vcpu is not None else 0, cpu_node)
    if "model" in data:
        model_kind = choice(data["model"], {"host-model", "host-passthrough", "qemu64", "custom"}, "CPU model")
        for node in cpu_node.findall("model"):
            cpu_node.remove(node)
        if model_kind in ("custom", "qemu64"):
            name_value = str(data.get("customModel", "") or "").strip() if model_kind == "custom" else "qemu64"
            need(re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", name_value) is not None, "customModel must be a valid CPU model name")
            cpu_node.set("mode", "custom")
            cpu_node.set("check", "partial")
            model_node = ET.Element("model", fallback="allow")
            model_node.text = name_value
            cpu_node.insert(0, model_node)
        elif model_kind == "host-passthrough":
            cpu_node.set("mode", "host-passthrough")
            cpu_node.attrib.pop("check", None)
        else:
            cpu_node.set("mode", "host-model")
            cpu_node.set("check", "partial")
        applied.append("cpu.model")
    topology = cpu_node.find("topology")
    topology_values = dict(topology.attrib) if topology is not None else {}
    for key in ("sockets", "cores", "threads"):
        if key in data:
            topology_values[key] = str(as_int(data[key], 1, 64, "CPU " + key))
            applied.append("cpu." + key)
    if topology_values:
        if topology is None:
            topology = ET.Element("topology")
            cpu_node.append(topology)
        topology.attrib.clear()
        topology.attrib.update(topology_values)
    if "features" in data:
        features = data["features"]
        need(isinstance(features, list), "CPU features must be a list")
        for node in cpu_node.findall("feature"):
            cpu_node.remove(node)
        for item in features:
            need(isinstance(item, dict), "each CPU feature must be an object")
            fname = str(item.get("name", "") or "").strip()
            policy = str(item.get("policy", "") or "").strip()
            need(re.fullmatch(r"[A-Za-z0-9_-]{1,64}", fname) is not None, "invalid CPU feature name")
            need(policy in ("force", "require", "optional", "disable", "forbid"), "unsupported CPU feature policy")
            ET.SubElement(cpu_node, "feature", name=fname, policy=policy)
        applied.append("cpu.features")

if "memory" in patch:
    data = group("memory")
    if "ramMiB" in data:
        node = root.find("memory")
        need(node is not None, "domain has no memory setting")
        node.set("unit", "KiB")
        node.text = str(as_int(data["ramMiB"], 256, 262144, "RAM") * 1024)
        applied.append("memory.ramMiB")
    if "currentMiB" in data:
        node = root.find("currentMemory")
        if node is None:
            node = ET.Element("currentMemory", unit="KiB")
            root.insert(list(root).index(root.find("memory")) + 1, node)
        node.set("unit", "KiB")
        node.text = str(as_int(data["currentMiB"], 256, 262144, "current memory") * 1024)
        applied.append("memory.currentMiB")
    need(mib_of("currentMemory") <= mib_of("memory"), "current memory cannot exceed maximum memory")
    if "balloonEnabled" in data:
        enabled = as_bool(data["balloonEnabled"], "balloonEnabled")
        balloon = devices.find("memballoon")
        if balloon is None:
            balloon = insert_ordered(devices, ET.Element("memballoon", model="virtio" if enabled else "none"), DEV_ORDER)
        else:
            balloon.set("model", "virtio" if enabled else "none")
        applied.append("memory.balloonEnabled")

if "video" in patch:
    data = group("video")
    video = devices.find("video")
    if video is None:
        video = insert_ordered(devices, ET.Element("video"), DEV_ORDER)
    model = video.find("model")
    if model is None:
        model = ET.SubElement(video, "model")
    if "model" in data:
        model.set("type", choice(data["model"], {"qxl", "bochs", "virtio", "vmware"}, "video model"))
        applied.append("video.model")
    if "vramMiB" in data:
        model.set("vram", str(as_int(data["vramMiB"], 1, 256, "video VRAM") * 1024))
        applied.append("video.vramMiB")
    if "heads" in data:
        model.set("heads", str(as_int(data["heads"], 1, 4, "video heads")))
        applied.append("video.heads")
    if "accel3d" in data:
        enabled = as_bool(data["accel3d"], "accel3d")
        acceleration = video.find("acceleration")
        if acceleration is None:
            acceleration = ET.Element("acceleration")
            video.insert(0, acceleration)
        acceleration.set("accel3d", "yes" if enabled else "no")
        applied.append("video.accel3d")

if "audio" in patch:
    data = group("audio")
    model = choice(data.get("model", "none"), {"none", "ich9", "ac97", "ich6", "usb", "virtio", "spice"}, "audio model")
    audio_id = 1
    for node in devices.findall("audio"):
        if str(node.get("id", "")).isdigit():
            audio_id = max(audio_id, int(node.get("id")) + 1)
    for tag in ("audio", "sound"):
        for node in devices.findall(tag):
            devices.remove(node)
    if model in ("none", "spice"):
        insert_ordered(devices, ET.Element("audio", id=str(audio_id), type=model), DEV_ORDER)
    else:
        insert_ordered(devices, ET.Element("sound", model=model), DEV_ORDER)
    applied.append("audio.model")

if "input" in patch:
    data = group("input")
    for key in ("tablet", "mouse", "keyboard"):
        if key not in data:
            continue
        enabled = as_bool(data[key], "input." + key)
        existing = [node for node in devices.findall("input") if node.get("type") == key]
        if enabled and not existing:
            insert_ordered(devices, ET.Element("input", type=key, bus="ps2" if key == "keyboard" else "usb"), DEV_ORDER)
        elif not enabled:
            for node in existing:
                devices.remove(node)
        applied.append("input." + key)

if "usbController" in patch:
    data = group("usbController")
    model = choice(data.get("model", "none"), {"xhci", "ehci", "piix3-uhci", "none"}, "USB controller model")
    controllers = [node for node in devices.findall("controller") if node.get("type") == "usb"]
    if model == "none":
        for node in controllers:
            devices.remove(node)
    else:
        target = {"xhci": "qemu-xhci", "ehci": "ehci", "piix3-uhci": "piix3-uhci"}[model]
        if controllers:
            node = controllers[0]
            for extra in controllers[1:]:
                devices.remove(extra)
        else:
            node = insert_ordered(devices, ET.Element("controller", type="usb", index="0"), DEV_ORDER)
        node.set("model", target)
        for child in node.findall("master"):
            node.remove(child)
        if target == "qemu-xhci":
            node.set("ports", node.get("ports", "8"))
        else:
            node.attrib.pop("ports", None)
    applied.append("usbController.model")

if "graphics" in patch:
    data = group("graphics")
    existing = devices.findall("graphics")
    gtype = choice(data.get("type", existing[0].get("type", "vnc") if existing else "vnc"), {"vnc", "spice", "none"}, "graphics type")
    if gtype == "none":
        for node in existing:
            devices.remove(node)
    else:
        node = next((item for item in existing if item.get("type") == gtype), existing[0] if existing else None)
        if node is None:
            node = insert_ordered(devices, ET.Element("graphics", type=gtype), DEV_ORDER)
        node.set("type", gtype)
        if "listen" in data:
            listen = str(data["listen"] or "127.0.0.1").strip()
            need(re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", listen) is not None, "invalid graphics listen address")
            node.set("listen", listen)
            for item in node.findall("listen"):
                node.remove(item)
            ET.SubElement(node, "listen", type="address", address=listen)
        if "port" in data:
            port = as_int(data["port"], 0, 65535, "graphics port")
            if port == 0:
                node.attrib.pop("port", None)
                node.set("autoport", "yes")
            else:
                node.set("port", str(port))
                node.set("autoport", "no")
    applied.append("graphics")

if "rng" in patch:
    data = group("rng")
    enabled = as_bool(data.get("enabled", True), "rng.enabled")
    existing = devices.findall("rng")
    if not enabled:
        for node in existing:
            devices.remove(node)
    else:
        model = choice(data.get("model", "random"), {"random", "hwrng", "virtio"}, "RNG model")
        backend_model = "random" if model == "virtio" else model
        node = existing[0] if existing else insert_ordered(devices, ET.Element("rng", model="virtio"), DEV_ORDER)
        node.set("model", "virtio")
        backend = node.find("backend")
        if backend is None:
            backend = ET.SubElement(node, "backend")
        backend.set("model", backend_model)
    applied.append("rng")

if "watchdog" in patch:
    data = group("watchdog")
    enabled = as_bool(data.get("enabled", True), "watchdog.enabled")
    existing = devices.findall("watchdog")
    if not enabled:
        for node in existing:
            devices.remove(node)
    else:
        model = choice(data.get("model", "i6300esb"), {"i6300esb", "ib700", "diag288", "itco"}, "watchdog model")
        action = choice(data.get("action", "reset"), {"none", "pause", "poweroff", "reset", "shutdown", "halt", "dump"}, "watchdog action")
        node = existing[0] if existing else insert_ordered(devices, ET.Element("watchdog"), DEV_ORDER)
        node.set("model", model)
        node.set("action", action)
    applied.append("watchdog")

if "boot" in patch:
    data = group("boot")
    if "order" in data:
        order = data["order"]
        need(isinstance(order, list) and 1 <= len(order) <= 3, "boot order must be a list of one to three devices")
        devices_order = [choice(item, {"network", "cdrom", "hd"}, "boot device") for item in order]
        need(len(set(devices_order)) == len(devices_order), "boot devices must be unique")
        for node in os_node.findall("boot"):
            os_node.remove(node)
        for item in devices_order:
            insert_ordered(os_node, ET.Element("boot", dev=item), OS_ORDER)
        for item in devices.findall("disk") + devices.findall("interface"):
            boot = item.find("boot")
            if boot is not None:
                item.remove(boot)
        applied.append("boot.order")
    if "menu" in data:
        enabled = as_bool(data["menu"], "boot menu")
        menu = os_node.find("bootmenu")
        if menu is None:
            menu = ET.Element("bootmenu")
            insert_ordered(os_node, menu, OS_ORDER)
        menu.set("enable", "yes" if enabled else "no")
        applied.append("boot.menu")

need(applied, "no hardware changes were provided")
backup_dir = "/var/backups/mist-vm-hardware"
os.makedirs(backup_dir, exist_ok=True)
backup_path = os.path.join(backup_dir, "%s.%s.%d.xml" % (name, time.strftime("%Y%m%d%H%M%S"), os.getpid()))
with open(backup_path, "w") as handle:
    handle.write(original_text)
os.chmod(backup_path, 0o600)
with open(output_path, "w") as handle:
    handle.write(ET.tostring(root, encoding="unicode"))
print(json.dumps({"ok": True, "name": name, "applied": applied, "needsInactive": needs_inactive, "state": state, "backup": backup_path}))
PY
  ) || { rm -f "$xml" "$out"; fail "$result"; }
  rm -f "$xml"
  virsh define "$out" >/dev/null || { rm -f "$out"; fail "virsh define failed for hardware change"; }
  rm -f "$out"
  detail=$(vm_hardware "$name")
  python3 - "$result" "$detail" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
detail = json.loads(sys.argv[2])
result["hardware"] = detail.get("hardware")
print(json.dumps(result, sort_keys=True))
PY
}

vm_fog_network_ensure() {
  local name="${1:-fog-capture}" iface bridge forward_dev source_kind tmp state
  valid_net_name "$name" || fail "invalid FOG capture network name"
  iface=$(env_get JOG_IMAGING_IFACE)
  [[ -n "$iface" ]] || iface=$(env_get JOG_USB_IFACE)
  valid_iface "$iface" || fail "JOG_IMAGING_IFACE or JOG_USB_IFACE is missing or invalid"
  if [[ -d "/sys/class/net/$iface/bridge" ]]; then
    bridge="$iface"
    forward_dev=""
    source_kind="existing-bridge"
  elif [[ -e "/sys/class/net/$iface/brport/bridge" ]]; then
    bridge=$(basename "$(readlink -f "/sys/class/net/$iface/brport/bridge" 2>/dev/null || true)")
    [[ -n "$bridge" && "$bridge" != "." && "$bridge" != "/" ]] || fail "could not resolve the bridge that contains $iface"
    forward_dev=""
    source_kind="enslaved-bridge"
  else
    bridge=""
    forward_dev="$iface"
    source_kind="macvtap"
  fi
  if virsh net-info "$name" >/dev/null 2>&1; then
    tmp=$(mktemp /tmp/mist-fog-net.XXXXXX.xml)
    virsh net-dumpxml "$name" >"$tmp" || { rm -f "$tmp"; fail "could not read network $name"; }
    if ! python3 - "$tmp" "$bridge" "$forward_dev" "$name" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, bridge, forward_dev, name = sys.argv[1:]
try:
    root = ET.fromstring(open(path).read())
except (OSError, ET.ParseError):
    raise SystemExit("could not parse network XML for " + name)
if root.find("ip") is not None or root.find(".//dhcp") is not None:
    raise SystemExit("network " + name + " has an IP or DHCP configuration; FOG supplies DHCP on 10.99.0.1")
forward = root.find("forward")
bridge_node = root.find("bridge")
if forward is None or (forward.get("mode") or "bridge") != "bridge":
    raise SystemExit("network " + name + " is not a bridged network")
if bridge:
    if bridge_node is None or bridge_node.get("name") != bridge:
        raise SystemExit("network " + name + " does not use bridge " + bridge)
elif bridge_node is not None:
    raise SystemExit("network " + name + " uses an unexpected bridge " + bridge_node.get("name", ""))
if forward_dev and forward.get("dev") != forward_dev:
    raise SystemExit("network " + name + " forwards " + (forward.get("dev") or "no device") + " instead of " + forward_dev)
PY
    then
      rm -f "$tmp"
      fail "network $name already exists with a conflicting configuration; review it before capture"
    fi
    rm -f "$tmp"
  else
    tmp=$(mktemp /tmp/mist-fog-net.XXXXXX.xml)
    python3 - "$tmp" "$name" "$bridge" "$forward_dev" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, name, bridge, forward_dev = sys.argv[1:]
root = ET.Element("network")
ET.SubElement(root, "name").text = name
forward = ET.SubElement(root, "forward", mode="bridge")
if forward_dev:
    forward.set("dev", forward_dev)
elif bridge:
    ET.SubElement(root, "bridge", name=bridge)
with open(path, "w") as handle:
    handle.write(ET.tostring(root, encoding="unicode"))
PY
    virsh net-define "$tmp" >/dev/null || { rm -f "$tmp"; fail "virsh net-define failed for $name"; }
    mkdir -p "$VM_NETWORK_DIR"
    cp "$tmp" "$VM_NETWORK_DIR/$name.xml"
    rm -f "$tmp"
  fi
  state=$(virsh net-info "$name" 2>/dev/null | python3 -c 'import sys; print(next((line.split(":",1)[1].strip() for line in sys.stdin if line.strip().startswith("Active:")), ""))' || true)
  if [[ "${state,,}" != yes* ]]; then
    virsh net-start "$name" >/dev/null || fail "could not start FOG capture network $name"
  fi
  virsh net-autostart "$name" >/dev/null 2>&1 || true
  tmp=$(mktemp /tmp/mist-fog-net.XXXXXX.xml)
  virsh net-dumpxml "$name" >"$tmp" || { rm -f "$tmp"; fail "could not read network $name"; }
  python3 - "$tmp" "$name" "$iface" "$bridge" "$forward_dev" "$source_kind" <<'PY'
import json
import subprocess
import sys

path, name, iface, bridge, forward_dev, source_kind = sys.argv[1:]
open(path).read()
info = {}
try:
    lines = subprocess.run(["virsh", "net-info", name], capture_output=True, text=True, timeout=15).stdout.splitlines()
    for line in lines:
        if ":" in line:
            key, value = line.split(":", 1)
            info[key.strip()] = value.strip()
except (OSError, subprocess.SubprocessError):
    pass
print(json.dumps({
    "ok": True,
    "name": name,
    "iface": iface,
    "bridge": bridge,
    "forwardDev": forward_dev,
    "source": source_kind,
    "mode": "bridge",
    "dhcp": False,
    "state": "active" if info.get("Active", "").lower().startswith("yes") else "inactive",
    "autostart": info.get("Autostart", "").lower().startswith("yes"),
    "definition": "/var/lib/libvirt/network/" + name + ".xml",
}))
PY
  rm -f "$tmp"
}

vm_fog_capture() {
  local name="${1:-}" network="${2:-}" start="${3:-}" state xml out result detail
  valid_vm_name "$name" || fail "invalid VM name"
  vm_exists "$name" || fail "domain not found: $name"
  network="${network:-fog-capture}"
  valid_net_name "$network" || fail "invalid FOG capture network name"
  case "$start" in 1|true|yes|on) start=1 ;; *) start=0 ;; esac
  vm_fog_network_ensure "$network" >/dev/null
  state=$(virsh domstate --domain "$name" 2>/dev/null || true)
  if [[ "${state,,}" != shut* && "${state,,}" != stopped* && -n "$state" ]]; then
    fail "VM $name is $state; shut it down before changing the FOG capture NIC source"
  fi
  xml=$(vm_xml_file "$name")
  out=$(mktemp /tmp/mist-vm-fog.XXXXXX.xml)
  result=$(python3 - "$name" "$xml" "$out" "$network" 2>&1 <<'PY'
import glob
import json
import os
import sys
import time
import xml.etree.ElementTree as ET

ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")
name, source_path, output_path, network = sys.argv[1:]
try:
    original_text = open(source_path).read()
    root = ET.fromstring(original_text)
except (OSError, ET.ParseError):
    raise SystemExit("could not parse domain XML")
os_node = root.find("os")
devices = root.find("devices")
if os_node is None or devices is None:
    raise SystemExit("domain XML is missing os or devices")

def domain_identity(tree):
    macs = set()
    disks = set()
    for node in tree.findall("devices/interface/mac"):
        address = (node.get("address") or "").strip().lower()
        if address:
            macs.add(address)
    for node in tree.findall("devices/disk/source"):
        path = (node.get("file") or "").strip()
        if path:
            try:
                disks.add(os.path.realpath(path))
            except OSError:
                disks.add(path)
    return macs, disks

macs, disks = domain_identity(root)
for candidate in glob.glob("/etc/libvirt/qemu/*.xml"):
    try:
        other = ET.parse(candidate).getroot()
    except (OSError, ET.ParseError):
        continue
    other_name = (other.findtext("name") or os.path.basename(candidate)).strip()
    if other_name == name or os.path.abspath(candidate) == os.path.abspath(source_path):
        continue
    other_macs, other_disks = domain_identity(other)
    clash = sorted(macs & other_macs) or sorted(disks & other_disks)
    if clash:
        raise SystemExit("conflicting domain " + other_name + " already uses " + ", ".join(clash[:2]))

interfaces = devices.findall("interface")
if not interfaces:
    raise SystemExit("VM " + name + " has no NIC to attach to " + network)
nic = interfaces[0]
mac = nic.find("mac")
mac_address = mac.get("address", "") if mac is not None else ""
nic.set("type", "network")
old_source = nic.find("source")
if old_source is not None:
    nic.remove(old_source)
source = ET.Element("source")
source.set("network", network)
position = 1 if mac is not None else 0
nic.insert(position, source)
for tag in ("target", "address", "virtualport"):
    node = nic.find(tag)
    if node is not None:
        nic.remove(node)
for node in os_node.findall("boot"):
    os_node.remove(node)
menu = os_node.find("bootmenu")
if menu is None:
    menu = ET.Element("bootmenu")
    os_node.append(menu)
menu.set("enable", "yes")
menu.set("timeout", "5")
for item in devices.findall("disk") + devices.findall("interface"):
    boot = item.find("boot")
    if boot is not None:
        item.remove(boot)
ET.SubElement(nic, "boot", order="1")
order = ["network"]
next_order = 2
for disk in devices.findall("disk"):
    kind = "cdrom" if disk.get("device") == "cdrom" else "hd"
    if kind == "cdrom":
        boot_order = "9"
    else:
        boot_order = str(next_order)
        next_order += 1
    ET.SubElement(disk, "boot", order=boot_order)
    if kind not in order:
        order.append(kind)
backup_dir = "/var/backups/mist-vm-hardware"
os.makedirs(backup_dir, exist_ok=True)
backup_path = os.path.join(backup_dir, "%s.fog-capture.%s.%d.xml" % (name, time.strftime("%Y%m%d%H%M%S"), os.getpid()))
with open(backup_path, "w") as handle:
    handle.write(original_text)
os.chmod(backup_path, 0o600)
with open(output_path, "w") as handle:
    handle.write(ET.tostring(root, encoding="unicode"))
print(json.dumps({"ok": True, "name": name, "network": network, "mac": mac_address, "bootOrder": order, "bootMenu": True, "backup": backup_path}))
PY
  ) || { rm -f "$xml" "$out"; fail "$result"; }
  rm -f "$xml"
  virsh define "$out" >/dev/null || { rm -f "$out"; fail "virsh define failed for FOG capture change"; }
  rm -f "$out"
  if [[ "$start" == 1 ]]; then
    virsh start "$name" >/dev/null || fail "FOG boot configured but virsh start failed for $name"
  fi
  detail=$(vm_hardware "$name")
  python3 - "$result" "$detail" "$start" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
detail = json.loads(sys.argv[2])
result["started"] = sys.argv[3] == "1"
result["hardware"] = detail.get("hardware")
print(json.dumps(result, sort_keys=True))
PY
}

vm_network_create_or_action() {
  local sub="${1:-}" action
  case "$sub" in
    create)
      shift
      vm_network_create "$@"
      ;;
    start|stop|delete)
      action="$sub"
      shift
      [[ $# -ge 1 ]] || fail "virtual switch name required"
      vm_network_action "$1" "$action"
      ;;
    *) fail "unknown virtual switch subcommand: ${sub:-empty}" ;;
  esac
}

vm_usb_or_action() {
  if [[ $# -eq 0 ]]; then
    vm_usb
    return
  fi
  vm_usb_action "$@"
}

valid_net_name() {
  [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,31}$ ]]
}

valid_net_mode() {
  case "$1" in
    isolated|nat|bridge) return 0 ;;
    *) return 1 ;;
  esac
}

valid_cidr() {
  python3 -c 'import ipaddress,sys; ipaddress.IPv4Network(sys.argv[1], strict=True)' "$1" >/dev/null 2>&1
}

valid_bridge_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]
}

valid_mac_address() {
  [[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]
}

valid_nic_model() {
  case "$1" in
    e1000|e1000e|virtio|rtl8139|vmxnet3|ne2k_pci) return 0 ;;
    *) return 1 ;;
  esac
}

valid_nic_identifier() {
  valid_mac_address "$1" || [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,32}$ ]]
}

valid_disk_target() {
  [[ "$1" =~ ^(sd[a-z]{1,2}|vd[a-z]{1,2}|nvme[0-9]+n[0-9]+|xvd[a-z]{1,2})$ ]]
}

valid_disk_bus() {
  case "$1" in
    virtio|sata|ide|scsi|nvme) return 0 ;;
    *) return 1 ;;
  esac
}

valid_disk_format() {
  case "$1" in
    qcow2|raw) return 0 ;;
    *) return 1 ;;
  esac
}

valid_usb_device() {
  [[ "$1" =~ ^usb_[0-9]+(_[0-9]+)+$ ]]
}

valid_image_path() {
  local path="${1:-}"
  [[ "$path" == /* && "$path" != *..* ]] || return 1
  python3 - "$path" "$VM_IMAGES_DIR" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
root = os.path.realpath(sys.argv[2])
sys.exit(0 if os.path.isfile(path) and path.startswith(root + os.sep) else 1)
PY
}

vm_require_vm() {
  local name="$1"
  valid_vm_name "$name" || fail "invalid VM name"
  vm_exists "$name" || fail "domain not found: $name"
}

vm_domain_xml() {
  local name="$1"
  virsh dumpxml --domain "$name" --inactive 2>/dev/null || virsh dumpxml --domain "$name"
}

vm_xml_file() {
  local name="$1" tmp
  tmp=$(mktemp /tmp/mist-vm-xml.XXXXXX)
  if ! vm_domain_xml "$name" >"$tmp"; then
    rm -f "$tmp"
    fail "could not read persistent XML for $name"
  fi
  echo "$tmp"
}

vm_boot() {
  local name="${1:-}" device="${2:-}" menu="${3:-}" flag xml out
  vm_require_vm "$name"
  if [[ -z "$device" ]]; then
    python3 - "$name" <<'PY'
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")
name = sys.argv[1]

def run(args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=15)
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout
    except (OSError, subprocess.SubprocessError):
        pass
    return ""

text = run(["virsh", "dumpxml", "--domain", name, "--inactive"]) or run(["virsh", "dumpxml", "--domain", name])
try:
    root = ET.fromstring(text)
except ET.ParseError:
    raise SystemExit("could not parse domain XML")

order = [item.get("dev", "") for item in root.findall("./os/boot") if item.get("dev")]
menu_node = root.find("./os/bootmenu")
menu = menu_node is not None and str(menu_node.get("enable", "no")).lower() in ("yes", "on", "1")
devices = []
for disk in root.findall("./devices/disk"):
    target = disk.find("target")
    source = disk.find("source")
    boot = disk.find("boot")
    kind = "cdrom" if disk.get("device") == "cdrom" else "hd"
    devices.append({
        "dev": kind,
        "target": target.get("dev", "") if target is not None else "",
        "bus": target.get("bus", "") if target is not None else "",
        "path": source.get("file", "") if source is not None else "",
        "order": int(boot.get("order")) if boot is not None and str(boot.get("order", "")).isdigit() else None,
    })
for nic in root.findall("./devices/interface"):
    target = nic.find("target")
    source = nic.find("source")
    boot = nic.find("boot")
    devices.append({
        "dev": "network",
        "target": target.get("dev", "") if target is not None else "",
        "bus": nic.get("type", ""),
        "path": (source.get("network", "") or source.get("bridge", "")) if source is not None else "",
        "order": int(boot.get("order")) if boot is not None and str(boot.get("order", "")).isdigit() else None,
    })
ordered = [item for item in devices if item["order"]]
if ordered:
    order = [item["dev"] for item in sorted(ordered, key=lambda item: item["order"])]
print(json.dumps({"ok": True, "name": name, "boot": {"order": order, "menu": menu, "devices": devices}}))
PY
    return
  fi
  case "$device" in
    hd|cdrom|network) ;;
    *) fail "boot device must be hd, cdrom or network" ;;
  esac
  case "$menu" in
    0) flag=off ;;
    1) flag=on ;;
    *) fail "boot menu must be 0 or 1" ;;
  esac
  xml=$(vm_xml_file "$name")
  out=$(mktemp /tmp/mist-vm-define.XXXXXX.xml)
  if ! python3 - "$xml" "$out" "$device" "$menu" <<'PY'
import sys
import xml.etree.ElementTree as ET

ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")
source_path, output_path, device, menu = sys.argv[1:]
try:
    root = ET.fromstring(open(source_path).read())
except (OSError, ET.ParseError):
    raise SystemExit("could not parse domain XML")
os_node = root.find("os")
devices = root.find("devices")
if os_node is None or devices is None:
    raise SystemExit("domain XML is missing os or devices section")
for node in os_node.findall("boot"):
    os_node.remove(node)
menu_node = os_node.find("bootmenu")
if menu_node is None:
    menu_node = ET.Element("bootmenu")
    os_node.insert(0, menu_node)
menu_node.set("enable", "yes" if menu == "1" else "no")
menu_node.set("timeout", "5")
for parent in devices:
    for node in parent.findall("boot"):
        parent.remove(node)
interfaces = devices.findall("interface")
disks = [node for node in devices.findall("disk") if node.get("device") != "cdrom"]
cdroms = [node for node in devices.findall("disk") if node.get("device") == "cdrom"]
def set_order(nodes, order):
    for node in nodes:
        ET.SubElement(node, "boot", order=str(order))
if device == "network":
    set_order(interfaces, 1)
    set_order(disks, 2)
    set_order(cdroms, 9)
elif device == "hd":
    set_order(disks[:1], 1)
    set_order(cdroms[:1], 2)
    set_order(disks[1:], 3)
    set_order(interfaces, 9)
else:
    set_order(cdroms[:1], 1)
    set_order(disks, 2)
    set_order(interfaces, 9)
open(output_path, "w").write(ET.tostring(root, encoding="unicode"))
PY
  then
    rm -f "$xml" "$out"
    fail "could not set boot order for $name"
  fi
  rm -f "$xml"
  virsh define "$out" >/dev/null || {
    rm -f "$out"
    fail "could not define boot order for $name"
  }
  rm -f "$out"
  vm_boot "$name"
}

vm_networks() {
  python3 - <<'PY'
import json
import subprocess
import xml.etree.ElementTree as ET

def run(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return ""

names = [line.strip() for line in run(["virsh", "net-list", "--all", "--name"]).splitlines() if line.strip()]
networks = []
for name in sorted(names):
    info = run(["virsh", "net-info", name])
    active = False
    autostart = False
    bridge = ""
    for line in info.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if key == "Active":
            active = value.lower().startswith("yes")
        elif key == "Autostart":
            autostart = value.lower().startswith("yes")
        elif key == "Bridge":
            bridge = value
    text = run(["virsh", "net-dumpxml", name])
    mode = "isolated"
    forward = ""
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        root = None
    if root is not None:
        node = root.find("forward")
        if node is not None:
            mode = node.get("mode") or "isolated"
            forward = node.get("dev") or mode
        node = root.find("bridge")
        if node is not None and node.get("name"):
            bridge = node.get("name")
    dhcp = []
    if root is not None:
        for network_ip in root.findall("ip"):
            for node in network_ip.findall("./dhcp/range"):
                dhcp.append({"start": node.get("start", ""), "end": node.get("end", ""), "netmask": network_ip.get("netmask", "")})
    networks.append({
        "name": name,
        "state": "active" if active else "inactive",
        "autostart": autostart,
        "bridge": bridge,
        "mode": mode,
        "forward": forward,
        "dhcp": dhcp,
    })
print(json.dumps({"ok": True, "networks": networks}))
PY
}

vm_network_create() {
  local name="${1:-}" mode="${2:-}" cidr="${3:-}" start="${4:-}" end="${5:-}" bridge="${6:-}" tmp
  valid_net_name "$name" || fail "invalid virtual switch name"
  valid_net_mode "$mode" || fail "mode must be isolated, nat or bridge"
  if virsh net-info "$name" >/dev/null 2>&1; then
    fail "virtual switch already exists: $name"
  fi
  if [[ "$mode" == bridge ]]; then
    valid_bridge_name "$bridge" || fail "invalid host bridge name"
    [[ -d "/sys/class/net/$bridge/bridge" ]] || fail "host bridge not found: $bridge"
  else
    valid_cidr "$cidr" || fail "CIDR must be a valid IPv4 network (for example 192.168.100.0/24)"
    if [[ -n "$start" || -n "$end" ]]; then
      [[ -n "$start" && -n "$end" ]] || fail "provide both DHCP start and end or leave both blank"
    fi
  fi
  mkdir -p "$VM_NETWORK_DIR"
  tmp=$(mktemp /tmp/mist-vm-net.XXXXXX.xml)
  if ! python3 - "$name" "$mode" "$cidr" "$start" "$end" "$bridge" "$tmp" <<'PY'
import ipaddress
import sys
import xml.etree.ElementTree as ET

name, mode, cidr, start, end, bridge, path = sys.argv[1:]
root = ET.Element("network")
ET.SubElement(root, "name").text = name
if mode == "nat":
    forward = ET.SubElement(root, "forward", mode="nat")
    ET.SubElement(ET.SubElement(forward, "nat"), "port", start="1024", end="65535")
elif mode == "bridge":
    forward = ET.SubElement(root, "forward", mode="bridge")
    forward.set("dev", bridge)
if mode != "bridge":
    network = ipaddress.IPv4Network(cidr, strict=True)
    address = network.network_address + 1 if network.num_addresses > 2 else network.network_address
    ip_node = ET.SubElement(root, "ip", address=str(address), netmask=str(network.netmask))
    if start or end:
        if not start or not end:
            raise SystemExit("provide both DHCP start and end")
        first = ipaddress.IPv4Address(start)
        last = ipaddress.IPv4Address(end)
        if first not in network or last not in network or first > last:
            raise SystemExit("DHCP range must be inside the CIDR and in ascending order")
        ET.SubElement(ET.SubElement(ip_node, "dhcp"), "range", start=start, end=end)
with open(path, "w") as handle:
    handle.write(ET.tostring(root, encoding="unicode"))
PY
  then
    rm -f "$tmp"
    fail "could not render virtual switch XML"
  fi
  virsh net-define "$tmp" >/dev/null || {
    rm -f "$tmp"
    fail "virsh net-define failed for $name"
  }
  cp "$tmp" "$VM_NETWORK_DIR/$name.xml"
  rm -f "$tmp"
  emit "ok=true" "name=$name" "mode=$mode" "definition=$VM_NETWORK_DIR/$name.xml"
}

vm_network_action() {
  local name="${1:-}" action="${2:-}" state
  valid_net_name "$name" || fail "invalid virtual switch name"
  case "$action" in
    start) virsh net-start "$name" >/dev/null ;;
    stop) virsh net-destroy "$name" >/dev/null ;;
    delete)
      virsh net-destroy "$name" >/dev/null 2>&1 || true
      virsh net-undefine "$name" >/dev/null
      ;;
    *) fail "unsupported virtual switch action: $action" ;;
  esac
  if virsh net-info "$name" >/dev/null 2>&1; then
    state=present
  else
    state=undefined
  fi
  emit "ok=true" "name=$name" "action=$action" "state=$state"
}

vm_nics() {
  local name="${1:-}" xml
  vm_require_vm "$name"
  xml=$(vm_xml_file "$name")
  python3 - "$name" "$xml" <<'PY' || { rm -f "$xml"; fail "could not read NICs for $name"; }
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

name, path = sys.argv[1:]
try:
    root = ET.fromstring(open(path).read())
except (OSError, ET.ParseError):
    raise SystemExit("could not parse domain XML")
try:
    state = subprocess.run(["virsh", "domstate", "--domain", name], capture_output=True, text=True, timeout=10).stdout.strip()
except (OSError, subprocess.SubprocessError):
    state = ""
nics = []
for nic in root.findall("./devices/interface"):
    mac = nic.find("mac")
    source = nic.find("source")
    model = nic.find("model")
    target = nic.find("target")
    link = nic.find("link")
    address = nic.find("address")
    source_type = nic.get("type", "")
    source_name = ""
    if source is not None:
        source_name = source.get("network", "") or source.get("bridge", "") or source.get("dev", "")
    nics.append({
        "mac": mac.get("address", "") if mac is not None else "",
        "type": source_type,
        "source": source_name,
        "model": model.get("type", "") if model is not None else "",
        "target": target.get("dev", "") if target is not None else "",
        "state": link.get("state", "") if link is not None else ("up" if "running" in state.lower() else "down"),
        "pci": " ".join("%s=%s" % (key, value) for key, value in sorted(address.attrib.items())) if address is not None else "",
    })
print(json.dumps({"ok": True, "name": name, "nics": nics}))
PY
  rm -f "$xml"
}

vm_nic() {
  local name="${1:-}" action="${2:-}" ident="${3:-}" arg1="${4:-}" arg2="${5:-}" arg3="${6:-}" xml out
  vm_require_vm "$name"
  case "$action" in
    add)
      case "$ident" in network|bridge) ;; *) fail "sourceType must be network or bridge" ;; esac
      [[ -n "$arg1" ]] || fail "NIC source is required"
      if [[ "$ident" == network ]]; then
        valid_net_name "$arg1" || fail "invalid network name"
        virsh net-info "$arg1" >/dev/null 2>&1 || fail "network not found: $arg1"
      else
        valid_bridge_name "$arg1" || fail "invalid bridge name"
        [[ -d "/sys/class/net/$arg1" ]] || fail "bridge not found: $arg1"
      fi
      valid_nic_model "$arg2" || fail "unsupported NIC model"
      if [[ -n "$arg3" ]]; then
        valid_mac_address "$arg3" || fail "invalid MAC address"
      fi
      ;;
    remove)
      valid_nic_identifier "$ident" || fail "invalid NIC identifier"
      ;;
    set-model)
      valid_nic_identifier "$ident" || fail "invalid NIC identifier"
      valid_nic_model "$arg1" || fail "unsupported NIC model"
      ;;
    set-network)
      valid_nic_identifier "$ident" || fail "invalid NIC identifier"
      case "$arg1" in network|bridge) ;; *) fail "sourceType must be network or bridge" ;; esac
      [[ -n "$arg2" ]] || fail "NIC source is required"
      if [[ "$arg1" == network ]]; then
        valid_net_name "$arg2" || fail "invalid network name"
        virsh net-info "$arg2" >/dev/null 2>&1 || fail "network not found: $arg2"
      else
        valid_bridge_name "$arg2" || fail "invalid bridge name"
        [[ -d "/sys/class/net/$arg2" ]] || fail "bridge not found: $arg2"
      fi
      ;;
    set-mac)
      valid_nic_identifier "$ident" || fail "invalid NIC identifier"
      valid_mac_address "$arg1" || fail "invalid MAC address"
      ;;
    *) fail "unsupported NIC action: $action" ;;
  esac
  xml=$(vm_xml_file "$name")
  out=$(mktemp /tmp/mist-vm-define.XXXXXX.xml)
  if ! python3 - "$xml" "$out" "$action" "$ident" "$arg1" "$arg2" "$arg3" <<'PY'
import sys
import xml.etree.ElementTree as ET

ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")
source_path, output_path, action, ident, arg1, arg2, arg3 = sys.argv[1:]
try:
    root = ET.fromstring(open(source_path).read())
except (OSError, ET.ParseError):
    raise SystemExit("could not parse domain XML")
devices = root.find("devices")
if devices is None:
    raise SystemExit("domain has no devices section")

def mac_of(node):
    item = node.find("mac")
    return item.get("address", "").lower() if item is not None else ""

def target_of(node):
    item = node.find("target")
    return item.get("dev", "") if item is not None else ""

existing = devices.findall("interface")
if action == "add":
    source_type, source, model, mac = ident, arg1, arg2, arg3
    if mac and any(mac_of(item) == mac.lower() for item in existing):
        raise SystemExit("MAC address is already used by another NIC")
    nic = ET.Element("interface", type=source_type)
    if mac:
        ET.SubElement(nic, "mac", address=mac.lower())
    ET.SubElement(nic, "source").set(source_type, source)
    if model:
        ET.SubElement(nic, "model", type=model)
    devices.append(nic)
else:
    matches = [item for item in existing if ident.lower() == mac_of(item) or ident == target_of(item)]
    if len(matches) != 1:
        raise SystemExit("NIC not found or ambiguous: %s" % ident)
    nic = matches[0]
    if action == "remove":
        devices.remove(nic)
    elif action == "set-model":
        model_node = nic.find("model")
        if model_node is None:
            model_node = ET.SubElement(nic, "model")
        model_node.set("type", arg1)
        address = nic.find("address")
        if address is not None:
            nic.remove(address)
    elif action == "set-network":
        source_type, source = arg1, arg2
        nic.set("type", source_type)
        old_source = nic.find("source")
        if old_source is not None:
            nic.remove(old_source)
        new_source = ET.Element("source")
        new_source.set(source_type, source)
        index = 1 if nic.find("mac") is not None else 0
        nic.insert(index, new_source)
        for tag in ("target", "address", "virtualport"):
            node = nic.find(tag)
            if node is not None:
                nic.remove(node)
    elif action == "set-mac":
        if any(item is not nic and mac_of(item) == arg1.lower() for item in existing):
            raise SystemExit("MAC address is already used by another NIC")
        mac_node = nic.find("mac")
        if mac_node is None:
            mac_node = ET.Element("mac")
            nic.insert(0, mac_node)
        mac_node.set("address", arg1.lower())
    else:
        raise SystemExit("unsupported NIC action")
with open(output_path, "w") as handle:
    handle.write(ET.tostring(root, encoding="unicode"))
PY
  then
    rm -f "$xml" "$out"
    fail "NIC change failed for $name"
  fi
  rm -f "$xml"
  virsh define "$out" >/dev/null || {
    rm -f "$out"
    fail "virsh define failed for NIC change"
  }
  rm -f "$out"
  vm_nics "$name"
}

vm_disks() {
  local name="${1:-}" xml
  vm_require_vm "$name"
  xml=$(vm_xml_file "$name")
  python3 - "$name" "$xml" <<'PY' || { rm -f "$xml"; fail "could not read disks for $name"; }
import json
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

name, path = sys.argv[1:]
try:
    root = ET.fromstring(open(path).read())
except (OSError, ET.ParseError):
    raise SystemExit("could not parse domain XML")
disks = []
for disk in root.findall("./devices/disk"):
    target = disk.find("target")
    source = disk.find("source")
    driver = disk.find("driver")
    boot = disk.find("boot")
    file_path = source.get("file", "") if source is not None else ""
    virtual_size = None
    actual_size = None
    if file_path and os.path.isfile(file_path):
        try:
            result = subprocess.run(["qemu-img", "info", "-U", "--output=json", file_path], capture_output=True, text=True, timeout=15)
            if result.returncode == 0:
                info = json.loads(result.stdout)
                virtual_size = info.get("virtual-size")
                actual_size = info.get("actual-size")
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        if actual_size is None:
            try:
                actual_size = os.path.getsize(file_path)
            except OSError:
                pass
    disks.append({
        "target": target.get("dev", "") if target is not None else "",
        "bus": target.get("bus", "") if target is not None else "",
        "type": disk.get("type", "file"),
        "device": disk.get("device", "disk"),
        "path": file_path,
        "format": driver.get("type", "") if driver is not None else "",
        "virtualSize": virtual_size,
        "actualSize": actual_size,
        "bootOrder": int(boot.get("order")) if boot is not None and str(boot.get("order", "")).isdigit() else None,
        "readonly": disk.find("readonly") is not None,
    })
print(json.dumps({"ok": True, "name": name, "disks": disks}))
PY
  rm -f "$xml"
}

vm_disk_path() {
  local name="$1" target="$2" allow_cdrom="${3:-0}" xml
  xml=$(vm_xml_file "$name")
  python3 - "$xml" "$target" "$allow_cdrom" <<'PY' || { rm -f "$xml"; return 1; }
import sys
import xml.etree.ElementTree as ET

path, target, allow_cdrom = sys.argv[1:]
try:
    root = ET.fromstring(open(path).read())
except (OSError, ET.ParseError):
    raise SystemExit("could not parse domain XML")
for disk in root.findall("./devices/disk"):
    node = disk.find("target")
    source = disk.find("source")
    if node is None or source is None or node.get("dev", "") != target:
        continue
    if disk.get("device", "disk") != "disk" and allow_cdrom != "1":
        continue
    print(source.get("file", ""))
    break
PY
  rm -f "$xml"
}

vm_disk_target() {
  local name="$1" bus="$2" xml
  xml=$(vm_xml_file "$name")
  python3 - "$xml" "$bus" <<'PY' || { rm -f "$xml"; return 1; }
import sys
import xml.etree.ElementTree as ET

path, bus = sys.argv[1:]
try:
    root = ET.fromstring(open(path).read())
except (OSError, ET.ParseError):
    raise SystemExit("could not parse domain XML")
used = set()
for disk in root.findall("./devices/disk"):
    node = disk.find("target")
    if node is not None and node.get("dev"):
        used.add(node.get("dev"))
def letter(index):
    return chr(ord("a") + index % 26) * (index // 26 + 1)
for index in range(26 * 26):
    if bus == "nvme":
        candidate = "nvme0n%d" % (index + 1)
    elif bus == "virtio":
        candidate = "vd" + letter(index)
    else:
        candidate = "sd" + letter(index)
    if candidate not in used:
        print(candidate)
        break
PY
  rm -f "$xml"
}

vm_disk_referenced() {
  local path="$1" exclude="$2"
  python3 - "$path" "$exclude" <<'PY'
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

path = os.path.realpath(sys.argv[1])
exclude = sys.argv[2]
try:
    names = subprocess.run(["virsh", "list", "--all", "--name"], capture_output=True, text=True, timeout=15).stdout.split()
except (OSError, subprocess.SubprocessError):
    names = []
for name in names:
    if name == exclude:
        continue
    for args in (["virsh", "dumpxml", "--domain", name, "--inactive"], ["virsh", "dumpxml", "--domain", name]):
        try:
            text = subprocess.run(args, capture_output=True, text=True, timeout=15).stdout
            root = ET.fromstring(text)
        except (ET.ParseError, OSError, subprocess.SubprocessError):
            continue
        for disk in root.findall("./devices/disk"):
            source = disk.find("source")
            if source is not None and source.get("file", "") and os.path.realpath(source.get("file")) == path:
                print(name)
                return
PY
}

vm_disk_xml() {
  local name="$1" action="$2" target="$3" path="${4:-}" bus="${5:-}" format="${6:-}" xml out
  xml=$(vm_xml_file "$name")
  out=$(mktemp /tmp/mist-vm-define.XXXXXX.xml)
  if ! python3 - "$xml" "$out" "$action" "$target" "$path" "$bus" "$format" <<'PY'
import sys
import xml.etree.ElementTree as ET

ET.register_namespace("libosinfo", "http://libosinfo.org/xmlns/libvirt/domain/1.0")
source_path, output_path, action, target, file_path, bus, disk_format = sys.argv[1:]
try:
    root = ET.fromstring(open(source_path).read())
except (OSError, ET.ParseError):
    raise SystemExit("could not parse domain XML")
devices = root.find("devices")
if devices is None:
    raise SystemExit("domain has no devices section")
disks = devices.findall("disk")
if action in ("add", "attach"):
    if any(node.get("dev", "") == target for disk in disks for node in [disk.find("target")] if node is not None):
        raise SystemExit("disk target is already in use: %s" % target)
    disk = ET.Element("disk", type="file", device="disk")
    ET.SubElement(disk, "driver", name="qemu", type=disk_format)
    ET.SubElement(disk, "source", file=file_path)
    ET.SubElement(disk, "target", dev=target, bus=bus)
    devices.append(disk)
else:
    disk = None
    if not (action == "set-boot" and target == "none"):
        matches = [disk for disk in disks if disk.find("target") is not None and disk.find("target").get("dev", "") == target]
        if len(matches) != 1:
            raise SystemExit("disk not found or ambiguous: %s" % target)
        disk = matches[0]
    if action in ("remove", "detach"):
        devices.remove(disk)
    elif action == "set-boot":
        for item in disks:
            node = item.find("boot")
            if node is not None:
                item.remove(node)
        os_node = root.find("os")
        if os_node is not None:
            for node in os_node.findall("boot"):
                os_node.remove(node)
        if target != "none":
            ET.SubElement(disk, "boot", order="1")
        elif os_node is not None:
            boot_menu = os_node.find("bootmenu")
            position = list(os_node).index(boot_menu) if boot_menu is not None else len(os_node)
            os_node.insert(position, ET.Element("boot", dev="hd"))
            os_node.insert(position + 1, ET.Element("boot", dev="cdrom"))
    else:
        raise SystemExit("unsupported disk action")
with open(output_path, "w") as handle:
    handle.write(ET.tostring(root, encoding="unicode"))
PY
  then
    rm -f "$xml" "$out"
    fail "disk change failed for $name"
  fi
  rm -f "$xml"
  virsh define "$out" >/dev/null || {
    rm -f "$out"
    fail "virsh define failed for disk change"
  }
  rm -f "$out"
}

vm_disk() {
  local name="${1:-}" action="${2:-}" target="${3:-}" size="${4:-}" bus="${5:-}" format="${6:-}" path delete_file current_bytes new_bytes state detail=""
  vm_require_vm "$name"
  case "$action" in
    add)
      size="${3:-}"
      bus="${4:-}"
      format="${5:-}"
      ;;
    attach)
      path="${3:-}"
      target="${4:-}"
      bus="${5:-}"
      ;;
    resize)
      target="${3:-}"
      size="${4:-}"
      ;;
    remove)
      target="${3:-}"
      delete_file="${4:-0}"
      ;;
    detach|set-boot)
      target="${3:-}"
      ;;
  esac
  case "$action" in
    add)
      [[ "$size" =~ ^[0-9]+$ ]] && (( size >= 1 && size <= 4096 )) || fail "disk size must be 1-4096 GiB"
      valid_disk_bus "$bus" || fail "unsupported disk bus"
      valid_disk_format "$format" || fail "unsupported disk format"
      target=$(vm_disk_target "$name" "$bus") || fail "no free disk target for $name"
      path="$VM_IMAGES_DIR/${name}-disk-${target}.${format}"
      [[ ! -e "$path" ]] || fail "disk file already exists: $path"
      qemu-img create -f "$format" "$path" "${size}G" >/dev/null || fail "qemu-img create failed"
      vm_disk_xml "$name" add "$target" "$path" "$bus" "$format"
      emit "ok=true" "name=$name" "action=$action" "target=$target" "path=$path" "sizeGiB=$size" "bus=$bus" "format=$format"
      return
      ;;
    resize)
      valid_disk_target "$target" || fail "invalid disk target"
      path=$(vm_disk_path "$name" "$target" 0) || fail "disk not found: $target"
      valid_image_path "$path" || fail "disk file is not inside $VM_IMAGES_DIR"
      [[ "$size" =~ ^[0-9]+$ ]] && (( size >= 1 && size <= 4096 )) || fail "disk size must be 1-4096 GiB"
      current_bytes=$(qemu-img info -U --output=json "$path" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual-size", 0))' 2>/dev/null || echo 0)
      new_bytes=$((size * 1024 * 1024 * 1024))
      (( new_bytes > current_bytes )) || fail "new size must be larger than ${target}"
      state=$(virsh domstate --domain "$name" 2>/dev/null || true)
      if [[ "$state" == running ]]; then
        virsh blockresize --domain "$name" --path "$path" --size "$((size * 1024 * 1024))" >/dev/null || fail "virsh blockresize failed"
        qemu-img resize "$path" "${size}G" >/dev/null 2>&1 || detail="guest block resized; qemu-img resize skipped because the image is in use"
      else
        qemu-img resize "$path" "${size}G" >/dev/null || fail "qemu-img resize failed"
      fi
      emit "ok=true" "name=$name" "action=$action" "target=$target" "sizeGiB=$size" "detail=${detail:-applied}"
      return
      ;;
    remove)
      valid_disk_target "$target" || fail "invalid disk target"
      path=$(vm_disk_path "$name" "$target" 1) || fail "disk not found: $target"
      case "$delete_file" in 0|1) ;; *) fail "deleteFile must be 0 or 1" ;; esac
      vm_disk_xml "$name" remove "$target"
      if [[ "$delete_file" == 1 ]]; then
        valid_image_path "$path" || fail "refusing to delete a file outside $VM_IMAGES_DIR"
        referenced=$(vm_disk_referenced "$path" "$name")
        [[ -z "$referenced" ]] || fail "disk file is still used by: $referenced"
        rm -f -- "$path"
      fi
      emit "ok=true" "name=$name" "action=$action" "target=$target" "deletedFile=$( [[ "$delete_file" == 1 ]] && echo true || echo false )"
      return
      ;;
    detach)
      valid_disk_target "$target" || fail "invalid disk target"
      vm_disk_xml "$name" detach "$target"
      emit "ok=true" "name=$name" "action=$action" "target=$target"
      return
      ;;
    attach)
      valid_disk_target "$target" || fail "invalid disk target"
      valid_disk_bus "$bus" || fail "unsupported disk bus"
      valid_image_path "$path" || fail "disk image must exist inside $VM_IMAGES_DIR"
      format=$(qemu-img info -U --output=json "$path" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("format", "qcow2"))' 2>/dev/null || echo qcow2)
      valid_disk_format "$format" || fail "unsupported disk image format"
      vm_disk_xml "$name" attach "$target" "$path" "$bus" "$format"
      emit "ok=true" "name=$name" "action=$action" "target=$target" "path=$path" "bus=$bus" "format=$format"
      return
      ;;
    set-boot)
      if [[ "$target" != none ]]; then
        valid_disk_target "$target" || fail "invalid disk target"
        path=$(vm_disk_path "$name" "$target" 1) || fail "disk not found: $target"
      fi
      vm_disk_xml "$name" set-boot "$target"
      emit "ok=true" "name=$name" "action=$action" "target=$target"
      return
      ;;
    *) fail "unsupported disk action: $action" ;;
  esac
}

vm_usb() {
  python3 - <<'PY'
import json
import subprocess
import xml.etree.ElementTree as ET

def run(args):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return ""

devices = []
for name in [line.strip() for line in run(["virsh", "nodedev-list", "--cap", "usb_device"]).splitlines() if line.strip()]:
    text = run(["virsh", "nodedev-dumpxml", name])
    try:
        root = ET.fromstring(text)
    except ET.ParseError:
        continue
    cap = root.find("capability[@type='usb_device']")
    if cap is None:
        continue
    vendor = cap.find("vendor")
    product = cap.find("product")
    vendor_id = vendor.get("id", "") if vendor is not None else ""
    product_id = product.get("id", "") if product is not None else ""
    description = cap.findtext("description", "") or (product.text or "").strip() if product is not None else ""
    bus = cap.findtext("bus", "")
    port = cap.findtext("device", "")
    attached_to = []
    for domain in [line.strip() for line in run(["virsh", "list", "--all", "--name"]).splitlines() if line.strip()]:
        xml = run(["virsh", "dumpxml", "--domain", domain, "--inactive"])
        try:
            domain_root = ET.fromstring(xml)
        except ET.ParseError:
            continue
        for hostdev in domain_root.findall("./devices/hostdev[@type='usb']"):
            source = hostdev.find("source")
            if source is None:
                continue
            address = source.find("address")
            vendor_node = source.find("vendor")
            product_node = source.find("product")
            match = False
            if address is not None and bus and port:
                match = (int(address.get("bus", "0"), 0) == int(bus, 0) and int(address.get("device", "0"), 0) == int(port, 0))
            elif vendor_node is not None and product_node is not None:
                match = (vendor_node.get("id", "").lower() == vendor_id.lower() and product_node.get("id", "").lower() == product_id.lower())
            if match and domain not in attached_to:
                attached_to.append(domain)
    devices.append({
        "device": name,
        "vendorId": vendor_id,
        "productId": product_id,
        "vendor": (vendor.text or "").strip() if vendor is not None else "",
        "product": (product.text or "").strip() if product is not None else "",
        "bus": bus,
        "port": port,
        "description": description.strip(),
        "attachedTo": attached_to,
    })
print(json.dumps({"ok": True, "devices": devices}))
PY
}

vm_usb_action() {
  local name="${1:-}" action="${2:-}" device="${3:-}" out
  vm_require_vm "$name"
  valid_usb_device "$device" || fail "invalid USB device"
  if ! virsh nodedev-list --cap usb_device 2>/dev/null | grep -Fxq "$device"; then
    fail "USB device not found: $device"
  fi
  out=$(mktemp /tmp/mist-vm-hostdev.XXXXXX.xml)
  if ! python3 - "$device" "$out" <<'PY'
import sys
import xml.etree.ElementTree as ET

device, path = sys.argv[1:]
import subprocess
try:
    text = subprocess.run(["virsh", "nodedev-dumpxml", device], capture_output=True, text=True, timeout=15).stdout
    root = ET.fromstring(text)
except (OSError, subprocess.SubprocessError, ET.ParseError):
    raise SystemExit("could not read USB device XML")
cap = root.find("capability[@type='usb_device']")
if cap is None or not cap.findtext("bus") or not cap.findtext("device"):
    raise SystemExit("USB device has no bus and port")
hostdev = ET.Element("hostdev", mode="subsystem", type="usb")
ET.SubElement(hostdev, "driver", name="qemu")
source = ET.SubElement(hostdev, "source")
ET.SubElement(source, "address", bus=hex(int(cap.findtext("bus"))), device=hex(int(cap.findtext("device"))))
with open(path, "w") as handle:
    handle.write(ET.tostring(hostdev, encoding="unicode"))
PY
  then
    rm -f "$out"
    fail "could not generate hostdev XML for $device"
  fi
  case "$action" in
    attach) virsh attach-device --domain "$name" --file "$out" --config >/dev/null || { rm -f "$out"; fail "could not attach $device to $name"; } ;;
    detach) virsh detach-device --domain "$name" --file "$out" --config >/dev/null || { rm -f "$out"; fail "could not detach $device from $name"; } ;;
    *) rm -f "$out"; fail "unsupported USB action: $action" ;;
  esac
  rm -f "$out"
  emit "ok=true" "name=$name" "action=$action" "device=$device"
}

run_fog_cycle() {
  local kind="${1:-}" host_id="${2:-}" image_id="${3:-}" name="${4:-}" network="${5:-fog-capture}" shutdown="${6:-1}" type_id state result task_id
  case "$kind" in
    deploy) type_id=1 ;;
    capture) type_id=2 ;;
    *) fail "usage: fog-run deploy|capture <hostID> <imageID> <vmName> [network] [shutdown]" ;;
  esac
  [[ "$host_id" =~ ^[0-9]+$ && "$image_id" =~ ^[0-9]+$ ]] || fail "hostID and imageID must be numeric"
  valid_vm_name "$name" || fail "invalid VM name"
  vm_exists "$name" || fail "domain not found: $name"
  valid_net_name "$network" || fail "invalid FOG capture network name"
  case "$shutdown" in 0|false|no|off) shutdown=0 ;; *) shutdown=1 ;; esac
  state=$(virsh domstate --domain "$name" 2>/dev/null || true)
  if [[ "${state,,}" != shut* && "${state,,}" != stopped* && -n "$state" ]]; then
    fail "VM $name is $state; shut it down before a FOG cycle"
  fi
  vm_fog_capture "$name" "$network" 0 >/dev/null || fail "could not prepare $name for FOG capture"
  [[ -r /etc/mist/fog-api.env ]] || fail "missing /etc/mist/fog-api.env"
  result=$(
    (
      set +x
      set -a
      . /etc/mist/fog-api.env
      set +a
      python3 - "$host_id" "$type_id" "$image_id" "$shutdown" <<'PY'
import json
import os
import urllib.error
import urllib.request

base = os.environ.get("MIST_FOG_API_URL", os.environ.get("MIST_FOG_API_URL", os.environ.get("JOG_FOG_API_URL", ""))).rstrip("/")
api = os.environ.get("FOG_API_TOKEN", "")
user = os.environ.get("FOG_USER_TOKEN", "")
host, task_type, image, shutdown = __import__("sys").argv[1:5]
if not base or not api or not user:
    raise SystemExit("FOG API is not configured")
headers = {"fog-api-token": api, "fog-user-token": user, "Accept": "application/json", "Content-Type": "application/json"}
payload = json.dumps({"taskTypeID": int(task_type), "imageID": int(image), "shutdown": shutdown == "1"}).encode()
req = urllib.request.Request(base + "/host/" + host + "/task", data=payload, headers=headers, method="POST")
try:
    with urllib.request.urlopen(req, timeout=20) as response:
        text = response.read().decode("utf-8", "replace")
except urllib.error.HTTPError as error:
    raise SystemExit("FOG task create failed: " + error.read().decode("utf-8", "replace")[:200])
def first_id(value):
    if isinstance(value, dict):
        return value.get("id") or value.get("taskID") or value.get("data")
    if isinstance(value, (int, str)):
        text = str(value).strip()
        return text if text else None
    if isinstance(value, list) and value:
        return first_id(value[0])
    return None

try:
    body = json.loads(text or "{}")
except ValueError:
    body = {"raw": text}
task_id = first_id(body)
if not task_id:
    try:
        with urllib.request.urlopen(urllib.request.Request(base + "/task/list", headers=headers), timeout=20) as response:
            rows = json.loads(response.read().decode("utf-8", "replace")).get("data", [])
        if rows:
            ids = []
            for row in rows:
                candidate = first_id(row)
                if candidate and str(candidate).isdigit():
                    ids.append(int(candidate))
            if ids:
                task_id = max(ids)
    except (OSError, ValueError, urllib.error.URLError):
        pass
print(json.dumps({"ok": True, "taskId": task_id, "response": body}, sort_keys=True))
PY
    )
  ) || fail "could not queue FOG task"
  task_id=$(printf '%s' "$result" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("taskId") or "")
except Exception: print("")')
  /usr/local/sbin/mist-fog-task-default.sh >/dev/null 2>&1 || true
  virsh start "$name" >/dev/null || fail "task queued but virsh start failed for $name"
  python3 - "$result" "$kind" "$name" "$network" "$task_id" <<'PY'
import json
import sys

result = json.loads(sys.argv[1])
result.update({"kind": sys.argv[2], "vm": sys.argv[3], "network": sys.argv[4], "taskId": sys.argv[5], "started": True})
print(json.dumps(result, sort_keys=True))
PY
}

run_fog_task_delete() {
  local id="${1:-}"
  [[ "$id" =~ ^[0-9]+$ ]] || fail "usage: fog-task-delete <taskID>"
  command -v mysql >/dev/null 2>&1 || fail "mysql client is not installed"
  mysql -N fog -e "DELETE FROM taskLog WHERE taskID=$id; DELETE FROM tasks WHERE taskID=$id;" >/dev/null \
    || fail "could not delete FOG task $id"
  /usr/local/sbin/mist-fog-task-default.sh >/dev/null 2>&1 || true
  emit "ok=true" "id=$id"
}

[[ ${EUID} -eq 0 ]] || fail "root privileges required"
[[ $# -ge 1 ]] || fail "usage: mist-portal-network.sh status|network|service|logs|safety|drivers|vm|fog-run|fog-task-default|fog-task-delete|replicate"

case "$1" in
  status)
    run_status
    ;;
  network)
    [[ $# -ge 2 ]] || fail "network subcommand required"
    sub="$2"
    shift 2
    case "$sub" in
      imaging) run_imaging "$@" ;;
      backhaul) run_backhaul "$@" ;;
      hotspot) run_hotspot "$@" ;;
      check) run_network_check "$@" ;;
      hotspot-clients) run_hotspot_clients "$@" ;;
      *) fail "unknown network subcommand: $sub" ;;
    esac
    ;;
  service)
    shift
    run_service "$@"
    ;;
  logs)
    shift
    run_logs "$@"
    ;;
  safety)
    [[ "${2:-}" == "check" ]] || fail "usage: safety check [IFACE] [IP]"
    shift 2
    run_safety "$@"
    ;;
  drivers)
    [[ "${2:-}" == "check" ]] || fail "usage: drivers check"
    run_drivers
    ;;
  fog-run)
    shift
    run_fog_cycle "$@"
    ;;
  fog-task-default)
    /usr/local/sbin/mist-fog-task-default.sh
    ;;
  fog-task-delete)
    shift
    run_fog_task_delete "$@"
    ;;
  replicate)
    shift
    exec /usr/local/sbin/mist-replicate.py "$@"
    ;;
  vm)
    [[ $# -ge 2 ]] || fail "vm subcommand required"
    sub="$2"
    shift 2
    case "$sub" in
      list) vm_list ;;
      detail) vm_detail "$@" ;;
      isos) vm_isos ;;
      create) vm_create "$@" ;;
      action) vm_action "$@" ;;
      snapshot|checkpoint) vm_snapshot "$@" ;;
      resources) vm_resources "$@" ;;
      console) vm_console "$@" ;;
      boot) vm_boot "$@" ;;
      networks) vm_networks ;;
      network) vm_network_create_or_action "$@" ;;
      hardware) vm_hardware "$@" ;;
      hardware-apply) vm_hardware_apply "$@" ;;
      fog-network) [[ "${1:-}" == ensure ]] || fail "usage: vm fog-network ensure [name]"; shift; vm_fog_network_ensure "$@" ;;
      fog-capture) vm_fog_capture "$@" ;;
      nics) vm_nics "$@" ;;
      nic) vm_nic "$@" ;;
      disks) vm_disks "$@" ;;
      disk) vm_disk "$@" ;;
      usb) vm_usb_or_action "$@" ;;
      *) fail "unknown vm subcommand: $sub" ;;
    esac
    ;;
  *)
    fail "unknown command: $1"
    ;;
esac
