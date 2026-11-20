#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log
# Clone FOG Project to FOG_SRC (/opt/fogproject) and run the official installer (no Docker). FOG installs
# itself into FOG_HOME (/opt/fog); cloning into FOG_HOME makes the installer's copy step fail
# ("'/opt/fog/utils/.' and '/opt/fog/utils/.' are the same file").
#
# The installer opens its ports to ANYWHERE in ufw/firewalld. On a laptop that is also on a corporate or home
# LAN, this script closes them again and re-opens only the imaging NIC (see "firewall" below).
# Requires /etc/jog/jog.env with imaging NIC + IPs. Run as root after jog-install-wizard (or equivalent).
#
# JOG uses dnsmasq for DHCP only; FOG owns TFTP (UDP/69). See scripts/jog-render-dnsmasq.sh.
#
# Env (optional):
#   FOG_HOME (/opt/fog), FOG_SRC (/opt/fogproject), FOG_GIT_URL, FOG_GIT_REF — install dir and git source
#   FOG_CERT_HOSTNAME — hostname embedded in TLS cert (default: hostname -f)

[[ "$(id -u)" -eq 0 ]] || {
  echo "Run as root: sudo $0" >&2
  exit 1
}

JOG_ENV="${JOG_ENV:-/etc/jog/jog.env}"
[[ -f "$JOG_ENV" ]] || {
  echo "Missing $JOG_ENV — configure imaging network first." >&2
  exit 1
}
# shellcheck disable=SC1090
source "$JOG_ENV"

JOG_REPO="${JOG_REPO:-/opt/JOG}"
if [[ -f "${JOG_REPO}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${JOG_REPO}/.env"
  set +a
fi

: "${JOG_USB_IFACE:?Set JOG_USB_IFACE in $JOG_ENV}"
: "${JOG_IMAGING_IP:?}"
: "${JOG_IMAGING_PREFIX:?}"
: "${JOG_DHCP_ROUTER:?}"

FOG_HOME="${FOG_HOME:-/opt/fog}"
FOG_SRC="${FOG_SRC:-/opt/fogproject}"
[[ "$FOG_SRC" != "$FOG_HOME" ]] || { echo "FOG_SRC must differ from FOG_HOME" >&2; exit 1; }
FOG_GIT_URL="${FOG_GIT_URL:-https://github.com/FOGProject/fogproject.git}"
# FOG is pinned to the release JOG was tested against (1.5.10.2518) and its commit is verified after the clone.
# To move to another release: set FOG_GIT_REF and FOG_GIT_COMMIT together, re-run the VM test, then update here.
# FOG_ALLOW_UNPINNED=1 skips the commit check (development only).
FOG_GIT_REF="${FOG_GIT_REF:-1.5.10.2518}"
FOG_GIT_COMMIT="${FOG_GIT_COMMIT:-c97e2050051a1056578e32556c20eba49a460b1d}"
FOG_ALLOW_UNPINNED="${FOG_ALLOW_UNPINNED:-0}"

prefix_to_mask() {
  case "${1:?}" in
    8) echo "255.0.0.0" ;;
    16) echo "255.255.0.0" ;;
    24) echo "255.255.255.0" ;;
    25) echo "255.255.255.128" ;;
    26) echo "255.255.255.192" ;;
    *) echo "255.255.255.0" ;;
  esac
}

SUBMASK="$(prefix_to_mask "${JOG_IMAGING_PREFIX}")"

DNS=""
if command -v resolvectl >/dev/null 2>&1; then
  DNS="$(resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)"
fi
[[ -n "$DNS" ]] && [[ "$DNS" =~ ^[0-9.]+$ ]] || DNS=""
if [[ -z "$DNS" && -r /etc/resolv.conf ]]; then
  DNS="$(grep -m1 '^nameserver[[:space:]]' /etc/resolv.conf | awk '{print $2}')"
fi
[[ -n "$DNS" ]] || DNS="1.1.1.1"

log() { echo "[fog-native-install] $*"; }

if [[ -f "${FOG_HOME}/.fogsettings" ]] && systemctl is-active --quiet apache2 2>/dev/null; then
  log "FOG appears installed under ${FOG_HOME}; running installer again for upgrades only."
fi

export LC_ALL=C

if [[ ! -f "${FOG_SRC}/bin/installfog.sh" ]]; then
  install -d "$(dirname "$FOG_SRC")"
  log "cloning ${FOG_GIT_URL} to ${FOG_SRC}"
  git clone --depth 1 --branch "$FOG_GIT_REF" "$FOG_GIT_URL" "$FOG_SRC"
fi

if [[ "$FOG_ALLOW_UNPINNED" != "1" ]]; then
  got_commit="$(git -C "$FOG_SRC" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$got_commit" != "$FOG_GIT_COMMIT" ]]; then
    echo "[fog-native-install] ERROR: FOG source at ${FOG_SRC} is ${got_commit:-not a git checkout}, expected ${FOG_GIT_COMMIT} (${FOG_GIT_REF})." >&2
    echo "[fog-native-install] Remove ${FOG_SRC} to re-clone the pinned release, or set FOG_ALLOW_UNPINNED=1 for development." >&2
    exit 1
  fi
  log "FOG source verified: ${FOG_GIT_REF} (${FOG_GIT_COMMIT})"
fi

# Satisfy FOG installfog.sh non-interactive (-Y) input.sh loops (see FOG lib/common/input.sh).
export interface="${JOG_USB_IFACE}"
export ipaddress="${JOG_IMAGING_IP}"
export submask="$SUBMASK"
export dodhcp="N"
export bldhcp=0
export hostname="${FOG_CERT_HOSTNAME:-$(hostname -f)}"
export routeraddress="${JOG_DHCP_ROUTER}"
export plainrouter="${JOG_DHCP_ROUTER}"
export dnsaddress="$DNS"
export sendreports="${FOG_SEND_REPORTS:-N}"
export installlang="0"
export installtype="N"

log "starting FOG installfog.sh -Y (no FOG DHCP — use JOG dnsmasq + next-server)"
cd "${FOG_SRC}/bin"
./installfog.sh -Y

# firewall: the installer allowed its ports from Anywhere. Close those and allow the imaging NIC only.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  for r in 80/tcp 443/tcp 69/udp 21/tcp 2049/tcp 111/tcp 111/udp 20048/tcp 20048/udp; do
    ufw --force delete allow "$r" >/dev/null 2>&1 || true
  done
  # insert at the top: ufw matches first-hit, and hosts commonly carry broad DENY rules (e.g. 111) above this
  for pp in 80,443/tcp 21/tcp 2049/tcp 111/tcp 111/udp 20048/tcp 20048/udp 69/udp 67/udp; do
    ufw insert 1 allow in on "${JOG_USB_IFACE}" to any port "${pp%/*}" proto "${pp#*/}" >/dev/null
  done
  log "ufw: FOG ports restricted to ${JOG_USB_IFACE}"
fi
