#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log
# Applies post-config automation: signed Ubuntu EFI → tftpboot, dnsmasq render, dnsmasq restart,
# then native FOG (blocking or background via systemd).
#
# Usage:
#   sudo jog-provision-stack.sh                  # wizard / default: FOG installs in background
#   sudo jog-provision-stack.sh --blocking-fog    # Hyper-V unattended: wait for fog-native-install

log() { echo "[jog-provision-stack] $*"; }

[[ "$(id -u)" -eq 0 ]] || {
  echo "Run as root: sudo $0" >&2
  exit 1
}

if [[ -x /usr/local/sbin/jog-copy-signed-ubuntu-efi-to-tftpboot.sh ]]; then
  /usr/local/sbin/jog-copy-signed-ubuntu-efi-to-tftpboot.sh || log "EFI staging failed (optional; retry: sudo jog-copy-signed-ubuntu-efi-to-tftpboot.sh)"
fi
if [[ -x /usr/local/sbin/jog-stage-jos-boot.sh ]]; then
  /usr/local/sbin/jog-stage-jos-boot.sh || log "JOS boot staging failed (retry: sudo jog-stage-jos-boot.sh; needs jos/build/out/initrd.img)"
fi

[[ -f /etc/jog/jog.env ]] || {
  log "missing /etc/jog/jog.env — nothing else to apply"
  exit 0
}
set -a
# shellcheck disable=SC1091
source /etc/jog/jog.env
set +a

if [[ -z "${JOG_USB_IFACE:-}" ]] || [[ "${JOG_USB_IFACE}" =~ REPLACE_ME ]]; then
  log "jog.env has no finalized imaging NIC — skipping dnsmasq/FOG"
  exit 0
fi

if [[ -x /usr/local/sbin/jog-force-imaging-nic-up.sh ]]; then
  /usr/local/sbin/jog-force-imaging-nic-up.sh || log "imaging NIC force-up failed (optional if the link is already configured another way)"
fi
if [[ -x /usr/local/bin/jog-render-dnsmasq.sh ]]; then
  /usr/local/bin/jog-render-dnsmasq.sh || log "dnsmasq render warned"
fi
systemctl restart dnsmasq 2>/dev/null || log "dnsmasq restart warned"

case "${1:-}" in
  --blocking-fog)
    if [[ -x /usr/local/sbin/jog-fog-install-once.sh ]]; then
      /usr/local/sbin/jog-fog-install-once.sh || log "FOG install returned non-zero"
    fi
    ;;
  *)
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable jog-fog-install.service 2>/dev/null || true
    if systemctl start jog-fog-install.service 2>/dev/null; then
      log "native FOG install started in background (journalctl -fu jog-fog-install.service)"
    else
      log "could not start jog-fog-install.service — run: sudo systemctl start jog-fog-install.service"
    fi
    ;;
esac
