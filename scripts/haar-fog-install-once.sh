#!/bin/bash
set -euo pipefail
exec 2>>/tmp/haar_error.log
# Single attempt at native FOG via fog-native-install.sh; marks /etc/haar/fog-native.done on success.
# Exits 0 quietly if haar.env is not ready yet (wizard not run) so the service can retry later.

[[ "$(id -u)" -eq 0 ]] || {
  echo "Run as root: sudo $0" >&2
  exit 1
}

MARK=/etc/haar/fog-native.done
[[ -f "$MARK" ]] && exit 0

JOG_ENV=/etc/haar/haar.env
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
systemctl disable haar-fog-install.service 2>/dev/null || true
echo "[haar-fog-install-once] native FOG install finished (marker $MARK)."

if [[ -x /usr/local/sbin/haar-post-fog-setup.sh ]]; then
  /usr/local/sbin/haar-post-fog-setup.sh || echo "[haar-fog-install-once] post-FOG corporate setup warned; re-run: sudo haar-post-fog-setup.sh" >&2
fi
