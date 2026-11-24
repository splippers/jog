#!/bin/bash
set -euo pipefail
exec 2>>/tmp/haar_error.log
# Applies post-config automation: signed Ubuntu EFI → tftpboot, dnsmasq render, dnsmasq restart,
# then native FOG (blocking or background via systemd).
#
# Usage:
#   sudo haar-provision-stack.sh                  # wizard / default: FOG installs in background
#   sudo haar-provision-stack.sh --blocking-fog    # Hyper-V unattended: wait for fog-native-install

log() { echo "[haar-provision-stack] $*"; }

[[ "$(id -u)" -eq 0 ]] || {
  echo "Run as root: sudo $0" >&2
  exit 1
}

if [[ -x /usr/local/sbin/haar-copy-signed-ubuntu-efi-to-tftpboot.sh ]]; then
  /usr/local/sbin/haar-copy-signed-ubuntu-efi-to-tftpboot.sh || log "EFI staging failed (optional; retry: sudo haar-copy-signed-ubuntu-efi-to-tftpboot.sh)"
fi
if [[ -x /usr/local/sbin/haar-stage-jos-boot.sh ]]; then
  /usr/local/sbin/haar-stage-jos-boot.sh || log "JOS boot staging failed (retry: sudo haar-stage-jos-boot.sh; needs jos/build/out/initrd.img)"
fi

[[ -f /etc/haar/haar.env ]] || {
  log "missing /etc/haar/haar.env — nothing else to apply"
  exit 0
}
set -a
# shellcheck disable=SC1091
source /etc/haar/haar.env
set +a

if [[ -z "${JOG_USB_IFACE:-}" ]] || [[ "${JOG_USB_IFACE}" =~ REPLACE_ME ]]; then
  log "haar.env has no finalized imaging NIC — skipping dnsmasq/FOG"
  exit 0
fi

if [[ -x /usr/local/sbin/haar-force-imaging-nic-up.sh ]]; then
  /usr/local/sbin/haar-force-imaging-nic-up.sh || log "imaging NIC force-up failed (optional if the link is already configured another way)"
fi
if [[ -x /usr/local/bin/haar-render-dnsmasq.sh ]]; then
  /usr/local/bin/haar-render-dnsmasq.sh || log "dnsmasq render warned"
fi
systemctl restart dnsmasq 2>/dev/null || log "dnsmasq restart warned"

case "${1:-}" in
  --blocking-fog)
    if [[ -x /usr/local/sbin/haar-fog-install-once.sh ]]; then
      /usr/local/sbin/haar-fog-install-once.sh || log "FOG install returned non-zero"
    fi
    ;;
  *)
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable haar-fog-install.service 2>/dev/null || true
    if systemctl start haar-fog-install.service 2>/dev/null; then
      log "native FOG install started in background (journalctl -fu haar-fog-install.service)"
    else
      log "could not start haar-fog-install.service — run: sudo systemctl start haar-fog-install.service"
    fi
    ;;
esac

# If FOG is already installed, apply the corporate profile now. Otherwise
# haar-fog-install-once.sh calls haar-post-fog-setup.sh when the install finishes.
if [[ -f /etc/haar/fog-native.done && -x /usr/local/sbin/haar-post-fog-setup.sh ]]; then
  /usr/local/sbin/haar-post-fog-setup.sh || log "post-FOG corporate setup warned; re-run: sudo haar-post-fog-setup.sh"
elif [[ "${Brume_DRIVER_SHARE_ENABLE:-${JOG_DRIVER_SHARE_ENABLE:-0}}" == "1" || "${Brume_MODEL_API_ENABLE:-${JOG_MODEL_API_ENABLE:-0}}" == "1" || "${Brume_AUTOJOIN_ENABLE:-${JOG_AUTOJOIN_ENABLE:-0}}" == "1" || "${Brume_MULTICAST_TUNE:-${JOG_MULTICAST_TUNE:-0}}" == "1" || "${Brume_PROVISIONING_ENABLE:-${JOG_PROVISIONING_ENABLE:-0}}" == "1" ]]; then
  log "corporate profile queued; it will be applied after FOG install finishes"
fi
