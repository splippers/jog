#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log
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
  -boot_image any replay

[[ -s "$OUT_ISO" ]] || { log "output ISO missing or empty"; exit 1; }

log "done: ${OUT_ISO}"
ls -lh "$OUT_ISO"
