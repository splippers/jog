#!/bin/bash
set -euo pipefail
exec 2>>/tmp/mist_error.log
# Install graphical stack tuned for Brume kiosk: X11-only session (ubuntu-xorg), LightDM,
# Chromium. Intended for Intel iGPU laptops (e.g. Dell Latitude 3410). Run as root.

log() { echo "[mist-setup-reliable-kiosk] $*"; }

[[ "$(id -u)" -eq 0 ]] || {
  echo "Run as root: sudo $0 [kiosk-username]" >&2
  exit 1
}

KIOSK_USER="${1:-jogadmin}"
ROOT="${Brume_REPO:-${JOG_REPO:-/opt/Brume}}"
[[ -d "$ROOT" ]] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export DEBIAN_FRONTEND=noninteractive

log "preconfiguring LightDM as display manager"
echo lightdm shared/default-x-display-manager select lightdm | debconf-set-selections

log "installing packages (this may take several minutes)"
apt-get update -qq
apt-get install -y -qq \
  ubuntu-desktop-minimal \
  ubuntu-session \
  xorg \
  lightdm \
  chromium-browser \
  mesa-utils \
  linux-firmware \
  dbus-x11

log "installing LightDM snippets"
install -d /etc/lightdm/lightdm.conf.d
sed "s/USERNAME/${KIOSK_USER}/g" "${ROOT}/lightdm/50-mist-autologin.conf.example" \
  >/etc/lightdm/lightdm.conf.d/50-mist-autologin.conf
chmod 0644 /etc/lightdm/lightdm.conf.d/50-mist-autologin.conf

log "default target = graphical"
systemctl set-default graphical.target

systemctl daemon-reload || true
log "done. Reboot to graphical login (autologin ${KIOSK_USER}, session ubuntu-xorg)."
log "If the login screen uses GDM from a prior install: sudo dpkg-reconfigure lightdm"
