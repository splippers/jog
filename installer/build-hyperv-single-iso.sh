#!/bin/bash
set -euo pipefail
ERROR_LOG="${JOG_ERROR_LOG:-${TMPDIR:-/tmp}/jog-build-${UID}.log}"
exec 2>>"$ERROR_LOG"
# Build one Ubuntu Server Live ISO with embedded nocloud + autoinstall kernel args for Hyper-V Gen2 (UEFI).
# Attach only this ISO to a new VM; installer runs unattended, then first-boot configures JOG without the wizard.
#
# Requires: xorriso, openssl, sed (run ./fetch-ubuntu-live-server-iso.sh first if you lack the GA ISO).
#
# Usage:
#   ./installer/fetch-ubuntu-live-server-iso.sh
#   ./installer/build-hyperv-single-iso.sh ['initial-jogadmin-password']
#
# Env:
#   SRC_ISO — override source ISO path (default: installer/ubuntu-<UBUNTU_RELEASE>-live-server-amd64.iso)
#   OUT_ISO — output path (default: installer/ubuntu-<release>-live-server-jog-hyperv-amd64.iso)
#   JOG_ERROR_LOG — override the per-user build log location
#   JOG_UNATTEND_IFACE, JOG_UNATTEND_IMAGING_IP, JOG_UNATTEND_PREFIX,
#   JOG_UNATTEND_DHCP_START, JOG_UNATTEND_DHCP_END, JOG_UNATTEND_ROUTER,
#   JOG_UNATTEND_NEXT_SERVER — imaging network settings baked into the ISO.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/installer"
AUTO="${INSTALLER}/autoinstall"
REL="$(tr -d '[:space:]' <"${INSTALLER}/UBUNTU_RELEASE")"

PW="${1:-jog-change-me-now}"
SRC_ISO="${SRC_ISO:-${INSTALLER}/ubuntu-${REL}-live-server-amd64.iso}"
OUT_ISO="${OUT_ISO:-${INSTALLER}/ubuntu-${REL}-live-server-jog-hyperv-amd64.iso}"
WORKDIR="${WORKDIR:-${INSTALLER}/build/hyperv-remaster-work}"

log() { echo "[build-hyperv-single-iso] $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { log "missing required command: $1"; exit 1; }; }

need xorriso
need openssl
need sed
need python3

JOG_UNATTEND_IMAGING_IP="${JOG_UNATTEND_IMAGING_IP:-10.99.0.1}"
JOG_UNATTEND_PREFIX="${JOG_UNATTEND_PREFIX:-24}"
JOG_UNATTEND_DHCP_START="${JOG_UNATTEND_DHCP_START:-10.99.0.100}"
JOG_UNATTEND_DHCP_END="${JOG_UNATTEND_DHCP_END:-10.99.0.250}"
JOG_UNATTEND_ROUTER="${JOG_UNATTEND_ROUTER:-$JOG_UNATTEND_IMAGING_IP}"
JOG_UNATTEND_NEXT_SERVER="${JOG_UNATTEND_NEXT_SERVER:-$JOG_UNATTEND_IMAGING_IP}"
JOG_UNATTEND_DHCP_BOOTFILE="${JOG_UNATTEND_DHCP_BOOTFILE:-ubuntu-signed/shimx64.efi}"
JOG_UNATTEND_IFACE="${JOG_UNATTEND_IFACE:-}"
if [[ -n "$JOG_UNATTEND_IFACE" && ! "$JOG_UNATTEND_IFACE" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]]; then
  log "invalid JOG_UNATTEND_IFACE: $JOG_UNATTEND_IFACE"
  exit 1
fi
if ! JOG_UNATTEND_NETMASK="$(python3 - "$JOG_UNATTEND_IMAGING_IP" "$JOG_UNATTEND_PREFIX" "$JOG_UNATTEND_DHCP_START" "$JOG_UNATTEND_DHCP_END" "$JOG_UNATTEND_ROUTER" "$JOG_UNATTEND_NEXT_SERVER" "${JOG_UNATTEND_NETMASK:-}" 2>&1 <<'PY'
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
        raise ValueError("JOG imaging IP must be a usable host address")
    pool_start = ipaddress.IPv4Address(start)
    pool_end = ipaddress.IPv4Address(end)
    if (pool_start not in network or pool_end not in network or pool_start > pool_end
            or pool_start in (network.network_address, network.broadcast_address)
            or pool_end in (network.network_address, network.broadcast_address)):
        raise ValueError("DHCP pool must be an ascending range inside the imaging subnet")
    if pool_start <= interface.ip <= pool_end:
        raise ValueError("DHCP pool must not include the JOG imaging IP")
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
  log "$JOG_UNATTEND_NETMASK"
  exit 1
fi

[[ -f "$SRC_ISO" ]] || {
  log "source ISO not found: $SRC_ISO"
  log "run: ${INSTALLER}/fetch-ubuntu-live-server-iso.sh"
  exit 1
}

mkdir -p "$WORKDIR"

log "rendering Hyper-V user-data"
( cd "$AUTO" && bash ./render-user-data.sh hyperv "$PW" )

[[ -f "${AUTO}/user-data.hyperv" ]] || { log "missing ${AUTO}/user-data.hyperv"; exit 1; }

META="${WORKDIR}/meta-data"
cat >"$META" <<'META'
instance-id: jog-hyperv-nocloud-1
local-hostname: jog-hyperv
META

EXTRA="${WORKDIR}/installer-extra"
mkdir -p "$EXTRA"
install -m 0755 "${ROOT}/scripts/jog-first-boot-unattended.sh" "${EXTRA}/jog-first-boot-unattended.sh"
install -m 0644 "${ROOT}/systemd/jog-first-boot-unattended.service" "${EXTRA}/jog-first-boot-unattended.service"
{
  printf 'JOG_UNATTEND_IFACE=%q\n' "$JOG_UNATTEND_IFACE"
  printf 'JOG_UNATTEND_IMAGING_IP=%q\n' "$JOG_UNATTEND_IMAGING_IP"
  printf 'JOG_UNATTEND_PREFIX=%q\n' "$JOG_UNATTEND_PREFIX"
  printf 'JOG_UNATTEND_DHCP_START=%q\n' "$JOG_UNATTEND_DHCP_START"
  printf 'JOG_UNATTEND_DHCP_END=%q\n' "$JOG_UNATTEND_DHCP_END"
  printf 'JOG_UNATTEND_NETMASK=%q\n' "$JOG_UNATTEND_NETMASK"
  printf 'JOG_UNATTEND_ROUTER=%q\n' "$JOG_UNATTEND_ROUTER"
  printf 'JOG_UNATTEND_NEXT_SERVER=%q\n' "$JOG_UNATTEND_NEXT_SERVER"
  printf 'JOG_UNATTEND_DHCP_BOOTFILE=%q\n' "$JOG_UNATTEND_DHCP_BOOTFILE"
} >"${EXTRA}/jog-unattended-network.env"
chmod 0600 "${EXTRA}/jog-unattended-network.env"

GRUB_PATCH="${WORKDIR}/grub.cfg"
LOOP_PATCH="${WORKDIR}/loopback.cfg"

patch_boot_files() {
  xorriso -osirrox on -indev "$SRC_ISO" -extract /boot/grub/grub.cfg "$GRUB_PATCH"
  xorriso -osirrox on -indev "$SRC_ISO" -extract /boot/grub/loopback.cfg "$LOOP_PATCH"

  local same='s|linux  /casper/vmlinuz  ---|linux  /casper/vmlinuz autoinstall ds=nocloud\\;s=/cdrom/nocloud/ ---|'
  sed -i "$same" "$GRUB_PATCH"
  sed -i 's|^set timeout=.*|set timeout=0|' "$GRUB_PATCH"

  # Trailing whitespace after --- matches official 26.04 ISO layout.
  sed -i \
    's|linux  /casper/vmlinuz  iso-scan/filename=${iso_path} ---[[:space:]]*|linux  /casper/vmlinuz autoinstall ds=nocloud\\;s=/cdrom/nocloud/ iso-scan/filename=${iso_path} --- |' \
    "$LOOP_PATCH"
  if ! grep -q 'autoinstall' "$LOOP_PATCH"; then
    log "WARNING: loopback.cfg was not patched; UEFI-from-ISO may miss autoinstall — check ISO layout."
  fi
}

patch_boot_files

rm -f "$OUT_ISO"
log "cloning ISO (xorriso map) -> ${OUT_ISO}"
# -boot_image any keep breaks hybrid ISO boot: El Torito + GPT appended EFI partition
# stay at old LBAs while mapped files shift the image, so UEFI loaders (Hyper-V Gen2)
# see a corrupt GPT / wrong EFI img size ("could not find a valid bootloader").
# replay re-applies the source ISO's boot layout after our -map changes (see xorriso(1)).
xorriso \
  -indev "$SRC_ISO" \
  -outdev "$OUT_ISO" \
  -map "$GRUB_PATCH" /boot/grub/grub.cfg \
  -map "$LOOP_PATCH" /boot/grub/loopback.cfg \
  -map "${AUTO}/user-data.hyperv" /nocloud/user-data \
  -map "$META" /nocloud/meta-data \
  -map "${EXTRA}/jog-first-boot-unattended.sh" /installer-extra/jog-first-boot-unattended.sh \
  -map "${EXTRA}/jog-first-boot-unattended.service" /installer-extra/jog-first-boot-unattended.service \
  -map "${EXTRA}/jog-unattended-network.env" /installer-extra/jog-unattended-network.env \
  -boot_image any replay

[[ -s "$OUT_ISO" ]] || { log "output ISO missing or empty"; exit 1; }

log "done: ${OUT_ISO}"
log "imaging network: ${JOG_UNATTEND_IMAGING_IP}/${JOG_UNATTEND_PREFIX}, DHCP ${JOG_UNATTEND_DHCP_START}-${JOG_UNATTEND_DHCP_END}, iface ${JOG_UNATTEND_IFACE:-first detected Ethernet}"
ls -lh "$OUT_ISO"
