#!/bin/bash
set -euo pipefail
exec 2>>/tmp/haar_error.log
# One-shot first boot for Hyper-V / lab: configure first Ethernet as imaging NIC, Brume env, netplan,
# full stack (EFI → tftpboot, dnsmasq, blocking native FOG). Skips interactive haar-install-wizard.

log() { echo "[Brume-UNATTENDED] $*"; }

[[ -f /etc/haar/unattended.active ]] || exit 0
[[ -f /etc/haar/wizard.done ]] && exit 0

# Install packages that used to be autoinstall `packages:` here — after DHCP still works and before we
# replace netplan with the isolated imaging subnet (no default route to Ubuntu mirrors).
if command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || log "WARNING: apt-get update failed (offline or no DNS?)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y dialog dnsmasq git curl openssl xorriso python3 || \
    log "WARNING: apt install of Brume prerequisites failed — check outbound HTTPS/DNS before static netplan"
fi

REPO="${Brume_REPO:-${JOG_REPO:-/opt/Brume}}"
if [[ ! -x "${REPO}/install/haar-install.sh" ]]; then
  log "Brume checkout missing — cloning into ${REPO}"
  install -d "$(dirname "$REPO")"
  rm -rf "$REPO"
  git clone --depth 1 https://github.com/splippers/Brume.git "$REPO" || \
    { log "ERROR: git clone failed — need outbound HTTPS for github.com"; exit 1; }
fi

NETWORK_ENV="${Brume_UNATTEND_NETWORK_ENV:-${JOG_UNATTEND_NETWORK_ENV:-/etc/haar/unattended-network.env}}"
if [[ -r "$NETWORK_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$NETWORK_ENV"
fi

IFACE="${JOG_UNATTEND_IFACE:-}"
if [[ -n "$IFACE" && ! "$IFACE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]]; then
  log "invalid configured imaging interface name: $IFACE"
  exit 1
fi
if [[ -n "$IFACE" ]] && ! ip link show dev "$IFACE" >/dev/null 2>&1; then
  log "configured imaging interface does not exist: $IFACE"
  exit 1
fi
while read -r _dev _st _; do
  [[ -z "$IFACE" ]] || break
  case "$_dev" in lo) continue ;; esac
  IFACE="$_dev"
  break
done < <(ip -br link show type ether | awk 'NR>1{print $1, $2}')

[[ -n "$IFACE" ]] || { log "no ethernet iface; leaving unattended flag for manual fix"; exit 0; }

IMAGING_IP="${Brume_UNATTEND_IMAGING_IP:-${JOG_UNATTEND_IMAGING_IP:-10.99.0.1}}"
PREFIX="${Brume_UNATTEND_PREFIX:-${JOG_UNATTEND_PREFIX:-24}}"
DHCP_START="${Brume_UNATTEND_DHCP_START:-${JOG_UNATTEND_DHCP_START:-10.99.0.100}}"
DHCP_END="${Brume_UNATTEND_DHCP_END:-${JOG_UNATTEND_DHCP_END:-10.99.0.250}}"
ROUTER="${Brume_UNATTEND_ROUTER:-${JOG_UNATTEND_ROUTER:-$IMAGING_IP}}"
NEXT_SERVER="${Brume_UNATTEND_NEXT_SERVER:-${JOG_UNATTEND_NEXT_SERVER:-$IMAGING_IP}}"
FOG_BOOTFILE="${Brume_UNATTEND_DHCP_BOOTFILE:-${JOG_UNATTEND_DHCP_BOOTFILE:-ubuntu-signed/shimx64.efi}}"
NETMASK="${JOG_UNATTEND_NETMASK:-}"
if ! NETMASK="$(python3 - "$IMAGING_IP" "$PREFIX" "$DHCP_START" "$DHCP_END" "$ROUTER" "$NEXT_SERVER" "$NETMASK" 2>&1 <<'PY'
import ipaddress
import sys

try:
    address, prefix, start, end, router, next_server, configured_mask = sys.argv[1:]
    prefix = int(prefix)
    if not 1 <= prefix <= 30:
        raise ValueError("CIDR prefix must be between 1 and 30")
    interface = ipaddress.IPv4Interface(f"{address}/{prefix}")
    network = interface.network
    if interface.ip in (network.network_address, network.broadcast_address):
        raise ValueError("Brume imaging IP must be a usable host address")
    pool_start = ipaddress.IPv4Address(start)
    pool_end = ipaddress.IPv4Address(end)
    if (pool_start not in network or pool_end not in network or pool_start > pool_end
            or pool_start in (network.network_address, network.broadcast_address)
            or pool_end in (network.network_address, network.broadcast_address)):
        raise ValueError("DHCP pool must be an ascending range inside the imaging subnet")
    if pool_start <= interface.ip <= pool_end:
        raise ValueError("DHCP pool must not include the Brume imaging IP")
    gateway = ipaddress.IPv4Address(router)
    tftp = ipaddress.IPv4Address(next_server)
    if (gateway not in network or tftp not in network
            or gateway in (network.network_address, network.broadcast_address)
            or tftp in (network.network_address, network.broadcast_address)):
        raise ValueError("DHCP router and TFTP server must be usable addresses inside the imaging subnet")
    if pool_start <= gateway <= pool_end or pool_start <= tftp <= pool_end:
        raise ValueError("DHCP pool must not include the router or TFTP server")
    if configured_mask and ipaddress.IPv4Address(configured_mask) != network.netmask:
        raise ValueError("configured netmask does not match the CIDR prefix")
    print(network.netmask)
except (ValueError, ipaddress.AddressValueError) as error:
    print(f"Invalid imaging network configuration: {error}", file=sys.stderr)
    sys.exit(1)
PY
)"; then
  log "$NETMASK"
  exit 1
fi

install -d /etc/haar
cat >/etc/haar/haar.env <<EOF
JOG_USB_IFACE=${IFACE}
JOG_IMAGING_IP=${IMAGING_IP}
JOG_IMAGING_PREFIX=${PREFIX}
JOG_DHCP_START=${DHCP_START}
JOG_DHCP_END=${DHCP_END}
JOG_DHCP_NETMASK=${NETMASK}
JOG_DHCP_LEASE_HOURS=12
JOG_DHCP_ROUTER=${ROUTER}
JOG_NEXT_SERVER=${NEXT_SERVER}
JOG_DHCP_BOOTFILE=${FOG_BOOTFILE}
JOG_FOG_URL=http://localhost/fog/management/
JOG_FOG_TASKS_URL=
JOG_STATUS_URL=http://127.0.0.1:8088/haar/status/index.html
EOF
chmod 0644 /etc/haar/haar.env

cat >/etc/netplan/90-haar-unattended.yaml <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      addresses:
        - ${IMAGING_IP}/${PREFIX}
      dhcp4: false
      optional: true
EOF
chmod 0600 /etc/netplan/90-haar-unattended.yaml

if command -v netplan >/dev/null 2>&1; then
  netplan generate
  netplan apply || log "netplan apply warned (non-fatal)"
fi

if [[ -x "${REPO}/install/haar-install.sh" ]]; then
  env JOG_SKIP_SYSTEMD=0 bash "${REPO}/install/haar-install.sh" || true
fi

systemctl daemon-reload || true
systemctl enable haar-render-dnsmasq.service 2>/dev/null || true
systemctl enable --now haar-refresh-status.timer 2>/dev/null || true

if [[ -x /usr/local/sbin/haar-provision-stack.sh ]]; then
  /usr/local/sbin/haar-provision-stack.sh --blocking-fog || log "provision-stack warned"
fi

touch /etc/haar/wizard.done
rm -f /etc/haar/unattended.active
systemctl disable haar-first-boot-unattended.service 2>/dev/null || true
log "unattended Brume bootstrap complete (iface=${IFACE} imaging=${IMAGING_IP})."
exit 0
