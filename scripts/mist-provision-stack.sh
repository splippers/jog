#!/bin/bash
set -euo pipefail
exec 2>>/tmp/mist_error.log
# Applies post-config automation: signed Ubuntu EFI → tftpboot, dnsmasq render, dnsmasq restart,
# then native FOG (blocking or background via systemd).
#
# Usage:
#   sudo mist-provision-stack.sh                  # wizard / default: FOG installs in background
#   sudo mist-provision-stack.sh --blocking-fog    # Hyper-V unattended: wait for fog-native-install

log() { echo "[mist-provision-stack] $*"; }

[[ "$(id -u)" -eq 0 ]] || {
  echo "Run as root: sudo $0" >&2
  exit 1
}

if [[ -x /usr/local/sbin/mist-copy-signed-ubuntu-efi-to-tftpboot.sh ]]; then
  /usr/local/sbin/mist-copy-signed-ubuntu-efi-to-tftpboot.sh || log "EFI staging failed (optional; retry: sudo mist-copy-signed-ubuntu-efi-to-tftpboot.sh)"
fi
if [[ -x /usr/local/sbin/mist-stage-jos-boot.sh ]]; then
  /usr/local/sbin/mist-stage-jos-boot.sh || log "JOS boot staging failed (retry: sudo mist-stage-jos-boot.sh; needs jos/build/out/initrd.img)"
fi

[[ -f /etc/mist/mist.env ]] || {
  log "missing /etc/mist/mist.env — nothing else to apply"
  exit 0
}
set -a
# shellcheck disable=SC1091
source /etc/mist/mist.env
set +a

if [[ -z "${JOG_USB_IFACE:-}" ]] || [[ "${JOG_USB_IFACE}" =~ REPLACE_ME ]]; then
  log "mist.env has no finalized imaging NIC — skipping dnsmasq/FOG"
  exit 0
fi

if [[ -x /usr/local/sbin/mist-force-imaging-nic-up.sh ]]; then
  /usr/local/sbin/mist-force-imaging-nic-up.sh || log "imaging NIC force-up failed (optional if the link is already configured another way)"
fi
if [[ -x /usr/local/bin/mist-render-dnsmasq.sh ]]; then
  /usr/local/bin/mist-render-dnsmasq.sh || log "dnsmasq render warned"
fi
systemctl restart dnsmasq 2>/dev/null || log "dnsmasq restart warned"

case "${1:-}" in
  --blocking-fog)
    if [[ -x /usr/local/sbin/mist-fog-install-once.sh ]]; then
      /usr/local/sbin/mist-fog-install-once.sh || log "FOG install returned non-zero"
    fi
    ;;
  *)
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable mist-fog-install.service 2>/dev/null || true
    if systemctl start mist-fog-install.service 2>/dev/null; then
      log "native FOG install started in background (journalctl -fu mist-fog-install.service)"
    else
      log "could not start mist-fog-install.service — run: sudo systemctl start mist-fog-install.service"
    fi
    ;;
esac

# If FOG is already installed, apply the corporate profile now. Otherwise
# mist-fog-install-once.sh calls mist-post-fog-setup.sh when the install finishes.
if [[ -f /etc/mist/fog-native.done && -x /usr/local/sbin/mist-post-fog-setup.sh ]]; then
  /usr/local/sbin/mist-post-fog-setup.sh || log "post-FOG corporate setup warned; re-run: sudo mist-post-fog-setup.sh"
elif [[ "${MIST_DRIVER_SHARE_ENABLE:-${JOG_DRIVER_SHARE_ENABLE:-0}}" == "1" || "${MIST_MODEL_API_ENABLE:-${JOG_MODEL_API_ENABLE:-0}}" == "1" || "${MIST_AUTOJOIN_ENABLE:-${JOG_AUTOJOIN_ENABLE:-0}}" == "1" || "${MIST_MULTICAST_TUNE:-${JOG_MULTICAST_TUNE:-0}}" == "1" || "${MIST_PROVISIONING_ENABLE:-${JOG_PROVISIONING_ENABLE:-0}}" == "1" ]]; then
  log "corporate profile queued; it will be applied after FOG install finishes"
fi
