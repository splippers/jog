#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log
# Single attempt at native FOG via fog-native-install.sh; marks /etc/jog/fog-native.done on success.
# Exits 0 quietly if jog.env is not ready yet (wizard not run) so the service can retry later.

[[ "$(id -u)" -eq 0 ]] || {
  echo "Run as root: sudo $0" >&2
  exit 1
}

MARK=/etc/jog/fog-native.done
[[ -f "$MARK" ]] && exit 0

JOG_ENV=/etc/jog/jog.env
[[ -f "$JOG_ENV" ]] || exit 0
set -a
# shellcheck disable=SC1090
source "$JOG_ENV"
set +a

[[ -n "${JOG_USB_IFACE:-}" ]] || exit 0
[[ "${JOG_USB_IFACE}" =~ REPLACE_ME ]] && exit 0
[[ -n "${JOG_IMAGING_IP:-}" ]] || exit 0

[[ -x /usr/local/sbin/fog-native-install.sh ]] || exit 1

/usr/local/sbin/fog-native-install.sh

touch "$MARK"
systemctl disable jog-fog-install.service 2>/dev/null || true
echo "[jog-fog-install-once] native FOG install finished (marker $MARK)."
