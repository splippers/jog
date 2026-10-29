#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log
# One-shot first boot for Hyper-V / lab: configure first Ethernet as imaging NIC, JOG env, netplan,
# full stack (EFI → tftpboot, dnsmasq, blocking native FOG). Skips interactive jog-install-wizard.

log() { echo "[JOG-UNATTENDED] $*"; }

[[ -f /etc/jog/unattended.active ]] || exit 0
[[ -f /etc/jog/wizard.done ]] && exit 0

# Install packages that used to be autoinstall `packages:` here — after DHCP still works and before we
# replace netplan with the isolated imaging subnet (no default route to Ubuntu mirrors).
if command -v apt-get >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || log "WARNING: apt-get update failed (offline or no DNS?)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y dialog dnsmasq git curl openssl xorriso || \
    log "WARNING: apt install of JOG prerequisites failed — check outbound HTTPS/DNS before static netplan"
fi

REPO="${JOG_REPO:-/opt/JOG}"
if [[ ! -x "${REPO}/install/jog-install.sh" ]]; then
  log "JOG checkout missing — cloning into ${REPO}"
  install -d "$(dirname "$REPO")"
  rm -rf "$REPO"
  git clone --depth 1 https://github.com/splippers/JOG.git "$REPO" || \
    { log "ERROR: git clone failed — need outbound HTTPS for github.com"; exit 1; }
fi

IFACE=""
while read -r _dev _st _; do
  case "$_dev" in lo) continue ;; esac
  IFACE="$_dev"
  break
done < <(ip -br link show | awk 'NR>1{print $1, $2}')

[[ -n "$IFACE" ]] || { log "no ethernet iface; leaving unattended flag for manual fix"; exit 0; }

IMAGING_IP="${JOG_UNATTEND_IMAGING_IP:-10.99.0.1}"
PREFIX="${JOG_UNATTEND_PREFIX:-24}"
DHCP_START="${JOG_UNATTEND_DHCP_START:-10.99.0.100}"
DHCP_END="${JOG_UNATTEND_DHCP_END:-10.99.0.250}"
ROUTER="${JOG_UNATTEND_ROUTER:-$IMAGING_IP}"
NEXT_SERVER="${JOG_UNATTEND_NEXT_SERVER:-$IMAGING_IP}"
FOG_BOOTFILE="${JOG_UNATTEND_DHCP_BOOTFILE:-ubuntu-signed/shimx64.efi}"
NETMASK="${JOG_UNATTEND_NETMASK:-255.255.255.0}"

install -d /etc/jog
cat >/etc/jog/jog.env <<EOF
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
JOG_STATUS_URL=file:///var/lib/jog/status/index.html
EOF
chmod 0644 /etc/jog/jog.env

cat >/etc/netplan/90-jog-unattended.yaml <<EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      addresses:
        - ${IMAGING_IP}/${PREFIX}
      dhcp4: false
      optional: true
EOF
chmod 0600 /etc/netplan/90-jog-unattended.yaml

if command -v netplan >/dev/null 2>&1; then
  netplan generate
  netplan apply || log "netplan apply warned (non-fatal)"
fi

if [[ -x "${REPO}/install/jog-install.sh" ]]; then
  env JOG_SKIP_SYSTEMD=0 bash "${REPO}/install/jog-install.sh" || true
fi

systemctl daemon-reload || true
systemctl enable jog-render-dnsmasq.service 2>/dev/null || true
systemctl enable --now jog-refresh-status.timer 2>/dev/null || true

if [[ -x /usr/local/sbin/jog-provision-stack.sh ]]; then
  /usr/local/sbin/jog-provision-stack.sh --blocking-fog || log "provision-stack warned"
fi

touch /etc/jog/wizard.done
rm -f /etc/jog/unattended.active
systemctl disable jog-first-boot-unattended.service 2>/dev/null || true
log "unattended JOG bootstrap complete (iface=${IFACE} imaging=${IMAGING_IP})."
exit 0
