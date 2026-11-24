#!/bin/bash
set -euo pipefail
exec 2>>/tmp/mist_error.log

# Install Brume helpers on the laptop (run with sudo).
# Repo root = directory containing install/, scripts/, config/

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

install -d /etc/mist /usr/local/bin /var/lib/mist/status

if [[ ! -f /etc/mist/mist.env ]]; then
  install -m 0644 "${ROOT}/config/mist.env.example" /etc/mist/mist.env
  echo "Created /etc/mist/mist.env — EDIT Brume_USB_IFACE and IPs before starting dnsmasq."
fi

install -m 0755 "${ROOT}/scripts/mist-render-dnsmasq.sh" /usr/local/bin/mist-render-dnsmasq.sh
install -m 0755 "${ROOT}/scripts/mist-portal-network.sh" /usr/local/sbin/mist-portal-network.sh
install -m 0755 "${ROOT}/scripts/mist-fog-task-default.sh" /usr/local/sbin/mist-fog-task-default.sh
install -m 0755 "${ROOT}/scripts/mist-refresh-status.sh" /usr/local/bin/mist-refresh-status.sh
install -m 0755 "${ROOT}/kiosk/chromium-mist.sh" /usr/local/bin/chromium-mist.sh
install -m 0755 "${ROOT}/installer/mist-install-wizard.sh" /usr/local/sbin/mist-install-wizard.sh
install -m 0644 "${ROOT}/installer/motd/mist-remind.sh" /etc/profile.d/mist-remind.sh
install -m 0755 "${ROOT}/scripts/mist-sync-images-from-primary.sh" /usr/local/bin/mist-sync-images-from-primary.sh
install -m 0755 "${ROOT}/install/fog-native-install.sh" /usr/local/sbin/fog-native-install.sh
install -m 0755 "${ROOT}/scripts/mist-copy-signed-ubuntu-efi-to-tftpboot.sh" /usr/local/sbin/mist-copy-signed-ubuntu-efi-to-tftpboot.sh
# The JOS client runtime lives in its own repo (github.com/splippers/jos). Find a checkout: $JOS_DIR, a sibling
# of this repo (the mist-jos layout), a jos/ inside it, or the legacy /opt/Brume/jos.
for d in "${JOS_DIR:-}" "${ROOT}/../jos" "${ROOT}/jos" /opt/mist/jos /opt/Brume/jos; do
  [[ -n "$d" && -f "$d/scripts/jos-stage-boot.sh" ]] && { JOS_DIR="$(cd "$d" && pwd)"; break; }
done
if [[ -f "${JOS_DIR:-}/scripts/jos-stage-boot.sh" ]]; then
  # Installed under the old name so existing docs and mist-provision-stack.sh keep working.
  install -m 0755 "${JOS_DIR}/scripts/jos-stage-boot.sh" /usr/local/sbin/mist-stage-jos-boot.sh
  install -d -m 0755 /usr/local/share/mist/jos
  if [[ -f "${JOS_DIR}/VERSION" ]]; then install -m 0644 "${JOS_DIR}/VERSION" /usr/local/share/mist/jos/VERSION; fi
  if [[ -f "${JOS_DIR}/branding/jos-logo.txt" ]]; then install -m 0644 "${JOS_DIR}/branding/jos-logo.txt" /usr/local/share/mist/jos/jos-logo.txt; fi
else
  echo "mist-install: JOS checkout not found (set JOS_DIR, or clone github.com/splippers/jos next to this repo); skipping JOS boot staging script" >&2
fi
install -m 0755 "${ROOT}/scripts/mist-doctor.sh" /usr/local/sbin/mist-doctor.sh
install -m 0755 "${ROOT}/scripts/mist-provision-stack.sh" /usr/local/sbin/mist-provision-stack.sh
install -m 0755 "${ROOT}/scripts/mist-qemu-workshop.sh" /usr/local/sbin/mist-qemu-workshop.sh
install -m 0755 "${ROOT}/scripts/mist-setup-reliable-kiosk.sh" /usr/local/sbin/mist-setup-reliable-kiosk.sh
install -m 0755 "${ROOT}/scripts/mist-fog-install-once.sh" /usr/local/sbin/mist-fog-install-once.sh
install -m 0755 "${ROOT}/scripts/mist-force-imaging-nic-up.sh" /usr/local/sbin/mist-force-imaging-nic-up.sh
install -m 0755 "${ROOT}/scripts/mist-imaging-nic-guard.sh" /usr/local/sbin/mist-imaging-nic-guard.sh

# Corporate pipeline: driver share, multicast profile, provisioning payload.
install -m 0755 "${ROOT}/scripts/mist-driver-share.sh" /usr/local/sbin/mist-driver-share.sh
install -m 0755 "${ROOT}/scripts/mist-update-dell-driver-pack.sh" /usr/local/sbin/mist-update-dell-driver-pack.sh
install -m 0755 "${ROOT}/scripts/mist-sync-driver-packs.sh" /usr/local/sbin/mist-sync-driver-packs.sh
install -m 0755 "${ROOT}/scripts/mist-sync-driver-packs.py" /usr/local/sbin/mist-sync-driver-packs.py
install -m 0755 "${ROOT}/scripts/mist-multicast-tune.sh" /usr/local/sbin/mist-multicast-tune.sh
install -m 0755 "${ROOT}/scripts/mist-model-api-setup.sh" /usr/local/sbin/mist-model-api-setup.sh
install -m 0755 "${ROOT}/scripts/mist-model-api.py" /usr/local/bin/mist-model-api.py
install -m 0755 "${ROOT}/scripts/mist-autojoin-setup.sh" /usr/local/sbin/mist-autojoin-setup.sh
install -d -m 0755 /usr/local/share/mist/scripts /usr/local/share/mist/systemd
install -m 0755 "${ROOT}/scripts/mist-model-api.py" /usr/local/share/mist/scripts/mist-model-api.py
install -m 0644 "${ROOT}/scripts/mist-autojoin.php" /usr/local/share/mist/scripts/mist-autojoin.php
install -m 0644 "${ROOT}/systemd/mist-model-api.service" /usr/local/share/mist/systemd/mist-model-api.service
install -d -m 0755 /usr/local/share/mist/config
install -m 0644 "${ROOT}/config/model-api.env.example" /usr/local/share/mist/config/model-api.env.example
install -m 0755 "${ROOT}/scripts/mist-corporate-setup.sh" /usr/local/sbin/mist-corporate-setup.sh
install -m 0755 "${ROOT}/scripts/mist-install-provisioner.sh" /usr/local/sbin/mist-install-provisioner.sh
install -m 0755 "${ROOT}/scripts/mist-post-fog-setup.sh" /usr/local/sbin/mist-post-fog-setup.sh
install -d -m 0755 /usr/local/share/mist/provisioner/windows /usr/local/share/mist/postdownload /usr/local/share/mist/config
install -m 0644 "${ROOT}"/provisioner/windows/* /usr/local/share/mist/provisioner/windows/
install -m 0755 "${ROOT}/install/postdownload/mist-inject-provisioner.sh" /usr/local/share/mist/postdownload/mist-inject-provisioner.sh
install -m 0644 "${ROOT}/config/mist-provisioning.env.example" /usr/local/share/mist/config/mist-provisioning.env.example

install -m 0644 "${ROOT}/systemd/mist-refresh-status.service" /etc/systemd/system/mist-refresh-status.service
install -m 0644 "${ROOT}/systemd/mist-refresh-status.timer" /etc/systemd/system/mist-refresh-status.timer
install -m 0644 "${ROOT}/systemd/mist-render-dnsmasq.service" /etc/systemd/system/mist-render-dnsmasq.service
install -m 0644 "${ROOT}/systemd/mist-force-imaging-nic-up.service" /etc/systemd/system/mist-force-imaging-nic-up.service
install -m 0644 "${ROOT}/systemd/mist-imaging-nic-guard.service" /etc/systemd/system/mist-imaging-nic-guard.service
install -m 0644 "${ROOT}/systemd/mist-imaging-nic-guard.timer" /etc/systemd/system/mist-imaging-nic-guard.timer
install -m 0644 "${ROOT}/systemd/mist-fog-install.service" /etc/systemd/system/mist-fog-install.service
install -m 0755 "${ROOT}/scripts/mist-replicator-first-boot.sh" /usr/local/sbin/mist-replicator-first-boot.sh
install -m 0755 "${ROOT}/scripts/mist-replicate.py" /usr/local/sbin/mist-replicate.py
install -m 0644 "${ROOT}/systemd/mist-replicator-first-boot.service" /etc/systemd/system/mist-replicator-first-boot.service

# Live imaging view (kiosk page + local API, bound to 127.0.0.1). Needs /etc/mist/fog-api.env to show live data.
install -m 0755 "${ROOT}/scripts/mist-imaging-api.py" /usr/local/bin/mist-imaging-api.py
install -d /usr/local/share/mist/imaging
install -m 0644 "${ROOT}"/kiosk/imaging/* /usr/local/share/mist/imaging/
install -d -m 0755 /var/www/html
install -m 0644 "${ROOT}/kiosk/mist-build-status.php" /var/www/html/mist-build-status.php
install -m 0644 "${ROOT}/systemd/mist-imaging-api.service" /etc/systemd/system/mist-imaging-api.service
install -d -m 0755 /etc/mist
[[ -f /etc/mist/fog-api.env ]] || install -m 0600 "${ROOT}/config/fog-api.env.example" /etc/mist/fog-api.env

mkdir -p /etc/systemd/system/dnsmasq.service.d
install -m 0644 "${ROOT}/systemd/dnsmasq.service.d/mist-pre.conf" /etc/systemd/system/dnsmasq.service.d/mist-pre.conf

# Without this, real-hardware PXE clients can stall mid-transfer: conntrack drops the
# TFTP data phase's port switch as untracked unless the helper module is loaded.
install -m 0644 "${ROOT}/config/mist-tftp-conntrack.conf" /etc/modules-load.d/mist-tftp-conntrack.conf
modprobe nf_conntrack_tftp 2>/dev/null || true

mkdir -p /etc/xdg/autostart
install -m 0644 "${ROOT}/kiosk/mist-chromium.desktop" /etc/xdg/autostart/mist-chromium.desktop

# During ISO late-commands (curtin in-target), systemd is not operational — skip.
if [[ "${Brume_SKIP_SYSTEMD:-${JOG_SKIP_SYSTEMD:-0}}" != "1" ]] && [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl enable mist-render-dnsmasq.service || true
  systemctl enable mist-force-imaging-nic-up.service || true
  systemctl enable --now mist-imaging-nic-guard.timer || true
  systemctl enable --now mist-refresh-status.timer || true
  systemctl enable --now mist-imaging-api.service || true
  systemctl enable mist-fog-install.service || true
  systemctl enable mist-replicator-first-boot.service || true
fi

echo "Done. Next:"
echo "  1) Run: sudo mist-install-wizard   (applies EFI → /tftpboot, dnsmasq, starts native FOG in background)."
echo "  2) Or edit /etc/mist/mist.env then: sudo mist-provision-stack.sh"
echo "  3) Graphical kiosk (X11 + LightDM + Chromium): sudo mist-setup-reliable-kiosk.sh jogadmin && sudo reboot"
echo "  4) Log into graphical session — Chromium autostarts from /etc/xdg/autostart/"
