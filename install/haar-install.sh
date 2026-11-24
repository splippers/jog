#!/bin/bash
set -euo pipefail
exec 2>>/tmp/haar_error.log

# Install Brume helpers on the laptop (run with sudo).
# Repo root = directory containing install/, scripts/, config/

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install -d /etc/haar /usr/local/bin /var/lib/haar/status

if [[ ! -f /etc/haar/haar.env ]]; then
  install -m 0644 "${ROOT}/config/haar.env.example" /etc/haar/haar.env
  echo "Created /etc/haar/haar.env — EDIT Brume_USB_IFACE and IPs before starting dnsmasq."
fi

install -m 0755 "${ROOT}/scripts/haar-render-dnsmasq.sh" /usr/local/bin/haar-render-dnsmasq.sh
install -m 0755 "${ROOT}/scripts/haar-portal-network.sh" /usr/local/sbin/haar-portal-network.sh
install -m 0755 "${ROOT}/scripts/haar-fog-task-default.sh" /usr/local/sbin/haar-fog-task-default.sh
install -m 0755 "${ROOT}/scripts/haar-refresh-status.sh" /usr/local/bin/haar-refresh-status.sh
install -m 0755 "${ROOT}/kiosk/chromium-haar.sh" /usr/local/bin/chromium-haar.sh
install -m 0755 "${ROOT}/installer/haar-install-wizard.sh" /usr/local/sbin/haar-install-wizard.sh
install -m 0644 "${ROOT}/installer/motd/haar-remind.sh" /etc/profile.d/haar-remind.sh
install -m 0755 "${ROOT}/scripts/haar-sync-images-from-primary.sh" /usr/local/bin/haar-sync-images-from-primary.sh
install -m 0755 "${ROOT}/install/fog-native-install.sh" /usr/local/sbin/fog-native-install.sh
install -m 0755 "${ROOT}/scripts/haar-copy-signed-ubuntu-efi-to-tftpboot.sh" /usr/local/sbin/haar-copy-signed-ubuntu-efi-to-tftpboot.sh
# The JOS client runtime lives in its own repo (github.com/splippers/jos). Find a checkout: $JOS_DIR, a sibling
# of this repo (the haar-jos layout), a jos/ inside it, or the legacy /opt/Brume/jos.
for d in "${JOS_DIR:-}" "${ROOT}/../jos" "${ROOT}/jos" /opt/haar/jos /opt/Brume/jos; do
  [[ -n "$d" && -f "$d/scripts/jos-stage-boot.sh" ]] && { JOS_DIR="$(cd "$d" && pwd)"; break; }
done
if [[ -f "${JOS_DIR:-}/scripts/jos-stage-boot.sh" ]]; then
  # Installed under the old name so existing docs and haar-provision-stack.sh keep working.
  install -m 0755 "${JOS_DIR}/scripts/jos-stage-boot.sh" /usr/local/sbin/haar-stage-jos-boot.sh
  install -d -m 0755 /usr/local/share/haar/jos
  if [[ -f "${JOS_DIR}/VERSION" ]]; then install -m 0644 "${JOS_DIR}/VERSION" /usr/local/share/haar/jos/VERSION; fi
  if [[ -f "${JOS_DIR}/branding/jos-logo.txt" ]]; then install -m 0644 "${JOS_DIR}/branding/jos-logo.txt" /usr/local/share/haar/jos/jos-logo.txt; fi
else
  echo "haar-install: JOS checkout not found (set JOS_DIR, or clone github.com/splippers/jos next to this repo); skipping JOS boot staging script" >&2
fi
install -m 0755 "${ROOT}/scripts/haar-doctor.sh" /usr/local/sbin/haar-doctor.sh
install -m 0755 "${ROOT}/scripts/haar-provision-stack.sh" /usr/local/sbin/haar-provision-stack.sh
install -m 0755 "${ROOT}/scripts/haar-qemu-workshop.sh" /usr/local/sbin/haar-qemu-workshop.sh
install -m 0755 "${ROOT}/scripts/haar-setup-reliable-kiosk.sh" /usr/local/sbin/haar-setup-reliable-kiosk.sh
install -m 0755 "${ROOT}/scripts/haar-fog-install-once.sh" /usr/local/sbin/haar-fog-install-once.sh
install -m 0755 "${ROOT}/scripts/haar-force-imaging-nic-up.sh" /usr/local/sbin/haar-force-imaging-nic-up.sh
install -m 0755 "${ROOT}/scripts/haar-imaging-nic-guard.sh" /usr/local/sbin/haar-imaging-nic-guard.sh

# Corporate pipeline: driver share, multicast profile, provisioning payload.
install -m 0755 "${ROOT}/scripts/haar-driver-share.sh" /usr/local/sbin/haar-driver-share.sh
install -m 0755 "${ROOT}/scripts/haar-update-dell-driver-pack.sh" /usr/local/sbin/haar-update-dell-driver-pack.sh
install -m 0755 "${ROOT}/scripts/haar-sync-driver-packs.sh" /usr/local/sbin/haar-sync-driver-packs.sh
install -m 0755 "${ROOT}/scripts/haar-sync-driver-packs.py" /usr/local/sbin/haar-sync-driver-packs.py
install -m 0755 "${ROOT}/scripts/haar-multicast-tune.sh" /usr/local/sbin/haar-multicast-tune.sh
install -m 0755 "${ROOT}/scripts/haar-model-api-setup.sh" /usr/local/sbin/haar-model-api-setup.sh
install -m 0755 "${ROOT}/scripts/haar-model-api.py" /usr/local/bin/haar-model-api.py
install -m 0755 "${ROOT}/scripts/haar-autojoin-setup.sh" /usr/local/sbin/haar-autojoin-setup.sh
install -d -m 0755 /usr/local/share/haar/scripts /usr/local/share/haar/systemd
install -m 0755 "${ROOT}/scripts/haar-model-api.py" /usr/local/share/haar/scripts/haar-model-api.py
install -m 0644 "${ROOT}/scripts/haar-autojoin.php" /usr/local/share/haar/scripts/haar-autojoin.php
install -m 0644 "${ROOT}/systemd/haar-model-api.service" /usr/local/share/haar/systemd/haar-model-api.service
install -d -m 0755 /usr/local/share/haar/config
install -m 0644 "${ROOT}/config/model-api.env.example" /usr/local/share/haar/config/model-api.env.example
install -m 0755 "${ROOT}/scripts/haar-corporate-setup.sh" /usr/local/sbin/haar-corporate-setup.sh
install -m 0755 "${ROOT}/scripts/haar-install-provisioner.sh" /usr/local/sbin/haar-install-provisioner.sh
install -m 0755 "${ROOT}/scripts/haar-post-fog-setup.sh" /usr/local/sbin/haar-post-fog-setup.sh
install -d -m 0755 /usr/local/share/haar/provisioner/windows /usr/local/share/haar/postdownload /usr/local/share/haar/config
install -m 0644 "${ROOT}"/provisioner/windows/* /usr/local/share/haar/provisioner/windows/
install -m 0755 "${ROOT}/install/postdownload/haar-inject-provisioner.sh" /usr/local/share/haar/postdownload/haar-inject-provisioner.sh
install -m 0644 "${ROOT}/config/haar-provisioning.env.example" /usr/local/share/haar/config/haar-provisioning.env.example

install -m 0644 "${ROOT}/systemd/haar-refresh-status.service" /etc/systemd/system/haar-refresh-status.service
install -m 0644 "${ROOT}/systemd/haar-refresh-status.timer" /etc/systemd/system/haar-refresh-status.timer
install -m 0644 "${ROOT}/systemd/haar-render-dnsmasq.service" /etc/systemd/system/haar-render-dnsmasq.service
install -m 0644 "${ROOT}/systemd/haar-force-imaging-nic-up.service" /etc/systemd/system/haar-force-imaging-nic-up.service
install -m 0644 "${ROOT}/systemd/haar-imaging-nic-guard.service" /etc/systemd/system/haar-imaging-nic-guard.service
install -m 0644 "${ROOT}/systemd/haar-imaging-nic-guard.timer" /etc/systemd/system/haar-imaging-nic-guard.timer
install -m 0644 "${ROOT}/systemd/haar-fog-install.service" /etc/systemd/system/haar-fog-install.service
install -m 0755 "${ROOT}/scripts/haar-replicator-first-boot.sh" /usr/local/sbin/haar-replicator-first-boot.sh
install -m 0755 "${ROOT}/scripts/haar-replicate.py" /usr/local/sbin/haar-replicate.py
install -m 0644 "${ROOT}/systemd/haar-replicator-first-boot.service" /etc/systemd/system/haar-replicator-first-boot.service

# Live imaging view (kiosk page + local API, bound to 127.0.0.1). Needs /etc/haar/fog-api.env to show live data.
install -m 0755 "${ROOT}/scripts/haar-imaging-api.py" /usr/local/bin/haar-imaging-api.py
install -d /usr/local/share/haar/imaging
install -m 0644 "${ROOT}"/kiosk/imaging/* /usr/local/share/haar/imaging/
install -d -m 0755 /var/www/html
install -m 0644 "${ROOT}/kiosk/haar-build-status.php" /var/www/html/haar-build-status.php
install -m 0644 "${ROOT}/systemd/haar-imaging-api.service" /etc/systemd/system/haar-imaging-api.service
install -d -m 0755 /etc/haar
[[ -f /etc/haar/fog-api.env ]] || install -m 0600 "${ROOT}/config/fog-api.env.example" /etc/haar/fog-api.env

mkdir -p /etc/systemd/system/dnsmasq.service.d
install -m 0644 "${ROOT}/systemd/dnsmasq.service.d/haar-pre.conf" /etc/systemd/system/dnsmasq.service.d/haar-pre.conf

# Without this, real-hardware PXE clients can stall mid-transfer: conntrack drops the
# TFTP data phase's port switch as untracked unless the helper module is loaded.
install -m 0644 "${ROOT}/config/haar-tftp-conntrack.conf" /etc/modules-load.d/haar-tftp-conntrack.conf
modprobe nf_conntrack_tftp 2>/dev/null || true

mkdir -p /etc/xdg/autostart
install -m 0644 "${ROOT}/kiosk/haar-chromium.desktop" /etc/xdg/autostart/haar-chromium.desktop

# During ISO late-commands (curtin in-target), systemd is not operational — skip.
if [[ "${Brume_SKIP_SYSTEMD:-${JOG_SKIP_SYSTEMD:-0}}" != "1" ]] && [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl enable haar-render-dnsmasq.service || true
  systemctl enable haar-force-imaging-nic-up.service || true
  systemctl enable --now haar-imaging-nic-guard.timer || true
  systemctl enable --now haar-refresh-status.timer || true
  systemctl enable --now haar-imaging-api.service || true
  systemctl enable haar-fog-install.service || true
  systemctl enable haar-replicator-first-boot.service || true
fi

echo "Done. Next:"
echo "  1) Run: sudo haar-install-wizard   (applies EFI → /tftpboot, dnsmasq, starts native FOG in background)."
echo "  2) Or edit /etc/haar/haar.env then: sudo haar-provision-stack.sh"
echo "  3) Graphical kiosk (X11 + LightDM + Chromium): sudo haar-setup-reliable-kiosk.sh jogadmin && sudo reboot"
echo "  4) Log into graphical session — Chromium autostarts from /etc/xdg/autostart/"
