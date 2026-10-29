#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log

# Interactive setup for JOG (hostname, imaging network, DHCP, admin user, optional EFI staging).
# Requires: dialog, root. Idempotent-ish: re-run to overwrite generated configs.

: "${DIALOG:=dialog}"

log() { echo "JOG-WIZARD: $*"; }
die() { echo "JOG-WIZARD-ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo jog-install-wizard)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$SCRIPT_DIR" == "/usr/local/sbin" || "$SCRIPT_DIR" == "/usr/local/bin" ]]; then
  REPO_ROOT="${JOG_REPO:-/opt/JOG}"
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
[[ -x "${REPO_ROOT}/install/fog-native-install.sh" ]] || die "JOG repo not found at ${REPO_ROOT} (set JOG_REPO=...)"

if ! command -v dialog >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dialog
fi

# --- Defaults (sensible isolated imaging subnet) ---
DEF_HOSTNAME="jog"
DEF_IMAGING_IP="10.99.0.1"
DEF_PREFIX="24"
DEF_DHCP_START="10.99.0.100"
DEF_DHCP_END="10.99.0.250"
# No DEF_ROUTER/DEF_NEXT: both dialogs below default to whatever imaging IP
# was just entered, not a separate static default - that's the sensible
# behaviour and it already happens via ${IMAGING_IP}. (Two unused vars with
# this exact name used to shadow that fact; removed.)

# --- Welcome ---
$DIALOG --title "JOG setup" --msgbox \
"Welcome to JOG (Jonathan's Opensource Ghost).

This wizard will ask for:
  • system hostname
  • imaging network (USB NIC IP + DHCP range)
  • admin Linux account (username + password)

FOG runs natively under /opt/fog (official installer — not Docker).

Corporate LAN safety: DHCP is rendered ONLY on the imaging interface you select.

Strong recommendation: use a USB Gigabit Ethernet adapter for imaging. On Ubuntu those
often appear as names starting with \"enx\" — not onboard eno/enp ports — which reduces
accidentally plugging imaging into corporate Ethernet. You may still choose onboard if
you confirm when prompted.

Press OK to continue." 22 70 || exit 0

# --- Hostname ---
HOSTNAME="$($DIALOG --stdout --title "Hostname" --inputbox "Short hostname for this JOG laptop (DNS / UI):" 10 60 "${DEF_HOSTNAME}" || true)"
[[ -n "${HOSTNAME// }" ]] || HOSTNAME="$DEF_HOSTNAME"

# --- Imaging NIC menu (USB recommended; onboard allowed with confirmation) ---
mapfile -t IFACES < <(ip -br link show | awk '$1!="lo"{print $1}' | grep -v '^lo$' || true)
[[ "${#IFACES[@]}" -gt 0 ]] || die "No non-loopback interfaces found."

IFACE_ITEMS=()
for i in "${!IFACES[@]}"; do
  nic="${IFACES[$i]}"
  if [[ "$nic" =~ ^enx ]]; then
    IFACE_ITEMS+=("$i" "$nic  — USB-style (recommended)")
  else
    IFACE_ITEMS+=("$i" "$nic  — likely onboard/built-in (confirm if intended)")
  fi
done

while true; do
  IDX="$($DIALOG --stdout --title "Imaging NIC (USB preferred)" --menu \
"Choose the Ethernet interface used ONLY for PXE/imaging traffic.

Prefer a USB adapter (names usually start with enx). Avoid using onboard Ethernet
that might carry a corporate LAN unless you understand the risk.

WiFi must NOT be used as the imaging NIC." 22 72 12 \
"${IFACE_ITEMS[@]}" 2>&1)" || exit 0
  JOG_USB_IFACE="${IFACES[$IDX]}"
  if [[ "$JOG_USB_IFACE" =~ ^enx ]]; then
    break
  fi
  $DIALOG --title "Confirm non-USB-style NIC" --yesno \
"You selected ${JOG_USB_IFACE}. JOG recommends a USB Gigabit adapter (typically enx…)
for imaging so you are less likely to bridge imaging traffic onto a corporate LAN.

Use ${JOG_USB_IFACE} anyway?" 14 72 && break
done

# --- Imaging IP / DHCP ---
IMAGING_IP="$($DIALOG --stdout --title "Imaging IP" --inputbox "Static IP on the USB imaging link (laptop side):" 10 60 "${DEF_IMAGING_IP}" || true)"
PREFIX="$($DIALOG --stdout --title "Prefix" --inputbox "CIDR prefix length (usually 24):" 10 60 "${DEF_PREFIX}" || true)"
DHCP_START="$($DIALOG --stdout --title "DHCP start" --inputbox "DHCP pool first address:" 10 60 "${DEF_DHCP_START}" || true)"
DHCP_END="$($DIALOG --stdout --title "DHCP end" --inputbox "DHCP pool last address:" 10 60 "${DEF_DHCP_END}" || true)"
ROUTER="$($DIALOG --stdout --title "Default gateway for PXE clients" --inputbox "Usually the same as the JOG IP on this cable:" 10 60 "${IMAGING_IP}" || true)"
NEXT_SERVER="$($DIALOG --stdout --title "NEXT SERVER (TFTP/PXE)" --inputbox "Must match siaddr / tftp-server for clients (usually this laptop on USB):" 10 60 "${IMAGING_IP}" || true)"

NETMASK="255.255.255.0"
if [[ "$PREFIX" == "24" ]]; then NETMASK="255.255.255.0"; fi

# --- Cluster (optional) ---
CLUSTER_MODE="$($DIALOG --stdout --title "Cluster mode" --menu \
"Multiple JOG units on one busy network: choose how this node participates." 18 70 4 \
standalone "Single JOG (default)" \
edge "Edge node: sync images from primary + optional split DHCP" \
primary "Mark as primary (hint file for edge nodes)" \
2>&1)" || CLUSTER_MODE="standalone"

PRIMARY_SSH=""
if [[ "$CLUSTER_MODE" == "edge" ]]; then
  PRIMARY_SSH="$($DIALOG --stdout --title "Primary SSH" --inputbox "Primary JOG sync source (user@host), e.g. jogadmin@10.99.0.1:" 10 60 "" || true)"
fi

# --- Admin user ---
ADMIN_USER="$($DIALOG --stdout --title "Admin username" --inputbox "Linux account for kiosk login + sudo (lowercase, no spaces):" 10 60 "jogadmin" || true)"
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid username"

PASS1="$($DIALOG --stdout --title "Password" --passwordbox "Password for ${ADMIN_USER}:" 10 60 || true)"
PASS2="$($DIALOG --stdout --title "Password" --passwordbox "Confirm password:" 10 60 || true)"
[[ -n "$PASS1" && "$PASS1" == "$PASS2" ]] || die "Passwords missing or mismatch"

# --- Summary ---
SUMMARY="hostname=$HOSTNAME
USB_IFACE=$JOG_USB_IFACE
imaging=${IMAGING_IP}/${PREFIX}
dhcp=${DHCP_START}-${DHCP_END}
router=$ROUTER next_server=$NEXT_SERVER
cluster=$CLUSTER_MODE
primary_ssh=$PRIMARY_SSH
admin=$ADMIN_USER"

$DIALOG --title "Confirm" --yesno "$SUMMARY

Write configuration and apply hostname?" 20 70 || exit 0

# --- Apply ---
install -d /etc/jog /etc/jog/cluster

hostnamectl set-hostname "$HOSTNAME"

# Linux user
if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$ADMIN_USER" 2>/dev/null || useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
fi
echo "${ADMIN_USER}:${PASS1}" | chpasswd

cat >/etc/jog/jog.env <<EOF
JOG_USB_IFACE=${JOG_USB_IFACE}
JOG_IMAGING_IP=${IMAGING_IP}
JOG_IMAGING_PREFIX=${PREFIX}
JOG_DHCP_START=${DHCP_START}
JOG_DHCP_END=${DHCP_END}
JOG_DHCP_NETMASK=${NETMASK}
JOG_DHCP_LEASE_HOURS=12
JOG_DHCP_ROUTER=${ROUTER}
JOG_NEXT_SERVER=${NEXT_SERVER}
JOG_DHCP_BOOTFILE=ubuntu-signed/shimx64.efi
JOG_FOG_URL=http://localhost/fog/management/
JOG_FOG_TASKS_URL=
JOG_STATUS_URL=file:///var/lib/jog/status/index.html
EOF

cat >/etc/jog/cluster.env <<EOF
JOG_CLUSTER_MODE=${CLUSTER_MODE}
JOG_PRIMARY_SSH=${PRIMARY_SSH}
EOF

# Netplan for USB static (WiFi unchanged — user should manage WiFi separately)
cat >/etc/netplan/90-jog-wizard.yaml <<EOF
network:
  version: 2
  ethernets:
    ${JOG_USB_IFACE}:
      addresses:
        - ${IMAGING_IP}/${PREFIX}
      dhcp4: false
      optional: true
EOF
chmod 0600 /etc/netplan/90-jog-wizard.yaml

if command -v netplan >/dev/null 2>&1; then
  netplan generate
  netplan apply || log "netplan apply returned non-zero; check conflicts with other netplan files"
fi

if [[ -x "${REPO_ROOT}/install/jog-install.sh" ]]; then
  bash "${REPO_ROOT}/install/jog-install.sh"
fi

if [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload || true
  systemctl enable jog-render-dnsmasq.service 2>/dev/null || true
  systemctl enable --now jog-refresh-status.timer 2>/dev/null || true
fi

if [[ -x /usr/local/sbin/jog-provision-stack.sh ]]; then
  /usr/local/sbin/jog-provision-stack.sh || log "jog-provision-stack returned non-zero"
fi

touch /etc/jog/wizard.done

$DIALOG --title "Done" --msgbox \
"JOG wizard finished.

Automated for you:
  • Signed Ubuntu EFI binaries → /tftpboot/ubuntu-signed/ (if apt could reach the mirror)
  • dnsmasq config rendered and service restarted
  • Native FOG install started in the background (long; needs Internet)

Watch progress: journalctl -fu jog-fog-install.service

Next steps:
  1) Review /etc/netplan/ — add WiFi with low route-metric if not already configured.
  2) Reboot if you changed hostname or netplan (FOG keeps running after reboot).

Cluster: read docs/CLUSTER.md and run scripts/jog-sync-images-from-primary.sh on edge nodes." 24 72
