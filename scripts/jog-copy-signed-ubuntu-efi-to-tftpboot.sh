#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log
# Stage Canonical-signed UEFI loaders from this Ubuntu install into /tftpboot/ubuntu-signed/
# for PXE/TFTP (Secure Boot friendly first stage). Requires root.
#
# Copies shim + grub signed payloads from shim-signed / grub-efi-amd64-signed.
# Point TFTP clients at these paths if you chain shim instead of FOG's snponly.efi (see /etc/jog/jog.env).

log() { echo "[jog-copy-signed-efi] $*"; }

ensure_pkg() {
  local p="$1"
  if ! dpkg -s "$p" >/dev/null 2>&1; then
    [[ "$(id -u)" -eq 0 ]] || { echo "Run as root to install $p: sudo $0" >&2; exit 1; }
    log "installing package: $p"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$p"
  fi
}

ensure_pkg shim-signed
ensure_pkg grub-efi-amd64-signed

DEST="${JOG_UBUNTU_EFI_STAGE:-/tftpboot/ubuntu-signed}"
install -d "$DEST/EFI/Boot" "$DEST/EFI/ubuntu"

SHIM=""
while IFS= read -r cand; do
  [[ -f "$cand" ]] || continue
  bn="$(basename "$cand")"
  [[ "$bn" == shimx64.efi.dualsigned || "$bn" == shimx64.efi.signed ]] || continue
  SHIM="$cand"
  break
done < <(dpkg -L shim-signed 2>/dev/null)

if [[ -z "$SHIM" ]]; then
  for cand in /usr/lib/shim/shimx64.efi.dualsigned /usr/lib/shim/shimx64.efi.signed; do
    [[ -f "$cand" ]] && SHIM="$cand" && break
  done
fi

GRUB=""
while IFS= read -r cand; do
  [[ -f "$cand" ]] || continue
  [[ "$(basename "$cand")" == grubx64.efi.signed ]] || continue
  GRUB="$cand"
  break
done < <(dpkg -L grub-efi-amd64-signed 2>/dev/null)

NETGRUB=""
while IFS= read -r cand; do
  [[ -f "$cand" ]] || continue
  [[ "$(basename "$cand")" == grubnetx64.efi.signed ]] || continue
  NETGRUB="$cand"
  break
done < <(dpkg -L grub-efi-amd64-signed 2>/dev/null)

[[ -n "$SHIM" ]] || {
  log "could not locate shimx64 from shim-signed"
  exit 1
}
[[ -n "$GRUB" ]] || {
  log "could not locate grubx64.efi.signed"
  exit 1
}

install -m 0644 "$SHIM" "$DEST/shimx64.efi"
# shim loads "grubx64.efi" from the directory it was fetched from. Over the network that must be the
# net-capable build (grubnetx64: prefix is tftp /grub, so it reads grub/grub.cfg from the TFTP root);
# the on-disk grubx64 has no network prefix and would drop to a prompt.
if [[ -n "$NETGRUB" ]]; then
  install -m 0644 "$NETGRUB" "$DEST/grubx64.efi"
  install -m 0644 "$NETGRUB" "$DEST/grubnetx64.efi"
else
  log "grubnetx64.efi.signed not found; PXE GRUB will not find grub.cfg"
  install -m 0644 "$GRUB" "$DEST/grubx64.efi"
fi

install -m 0644 "$SHIM" "$DEST/EFI/Boot/bootx64.efi"
install -m 0644 "$GRUB" "$DEST/EFI/ubuntu/grubx64.efi"

MAN="$DEST/README.txt"
{
  echo "Signed Ubuntu UEFI binaries staged by jog-copy-signed-ubuntu-efi-to-tftpboot.sh"
  echo "Time: $(date -Iseconds)"
  echo ""
  echo "Sources:"
  echo "  shim: $SHIM"
  echo "  grub: $GRUB"
  [[ -n "$NETGRUB" ]] && echo "  grubnet: $NETGRUB"
  echo ""
  echo "grub.cfg and the kernel/initrd/modules.img are staged separately by"
  echo "jog-stage-jos-boot.sh - run that too."
  echo ""
  echo "Flat TFTP paths (relative to tftpboot root): ubuntu-signed/shimx64.efi"
  echo "Optionally set JOG_DHCP_BOOTFILE=ubuntu-signed/shimx64.efi and run jog-render-dnsmasq.sh"
} >"$MAN"

log "staged signed EFI under $DEST"
ls -la "$DEST"
