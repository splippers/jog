#!/bin/bash
# Verify the Secure Boot PXE chain staged on this JOG: bootfile -> shim -> grub -> signed kernel -> JOS initrd.
# Exit 0 only if every check passes. Safe to run any time; changes nothing.
TFTP="${JOG_TFTP_ROOT:-/tftpboot}"
[[ -f /etc/jog/jog.env ]] && source /etc/jog/jog.env
BOOTFILE="${JOG_DHCP_BOOTFILE:-ubuntu-signed/shimx64.efi}"
rc=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; rc=1; }
signed() { sbverify --list "$1" 2>&1 | grep -q 'signature 1'; }

echo "JOG doctor (tftp root: $TFTP)"
if [[ ! -f "$TFTP/$BOOTFILE" ]]; then bad "bootfile $BOOTFILE missing"
elif signed "$TFTP/$BOOTFILE"; then ok "bootfile $BOOTFILE is signed"
else bad "bootfile $BOOTFILE is UNSIGNED — Secure Boot machines will refuse it (set JOG_DHCP_BOOTFILE=ubuntu-signed/shimx64.efi)"; fi

D="$(dirname "$TFTP/$BOOTFILE")"
if [[ -f "$D/grubx64.efi" ]] && signed "$D/grubx64.efi"; then ok "grubx64.efi next to shim is signed"; else bad "signed grubx64.efi missing next to shim"; fi
if [[ -f "$D/grubx64.efi" ]] && [[ -f "$D/grubnetx64.efi" ]] && cmp -s "$D/grubx64.efi" "$D/grubnetx64.efi"; then ok "grubx64.efi is the network build"; else bad "grubx64.efi is not grubnetx64 (PXE GRUB would not find grub.cfg)"; fi
[[ -f "$TFTP/grub/grub.cfg" ]] && ok "grub/grub.cfg present" || bad "grub/grub.cfg missing (run jog-stage-jos-boot.sh)"
if [[ -f "$TFTP/jos/vmlinuz" ]] && signed "$TFTP/jos/vmlinuz"; then ok "jos/vmlinuz is signed"; else bad "jos/vmlinuz missing or unsigned"; fi
[[ -s "$TFTP/jos/initrd.img" ]] && ok "jos/initrd.img present" || bad "jos/initrd.img missing"
[[ -s "$TFTP/jos/modules.img" ]] && ok "jos/modules.img present" || bad "jos/modules.img missing"
if [[ -f "$TFTP/jos/kver" ]]; then
  if [[ -d "/lib/modules/$(cat "$TFTP/jos/kver")" ]]; then ok "staged kernel $(cat "$TFTP/jos/kver") still installed"
  else bad "staged kernel $(cat "$TFTP/jos/kver") no longer installed locally (restage after upgrades)"; fi
fi
exit $rc
