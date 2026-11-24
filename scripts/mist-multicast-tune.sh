#!/bin/bash
set -euo pipefail
exec 2>>/tmp/mist_error.log

# mist-multicast-tune.sh — set the FOG multicast profile for the 100-client reference design.
#
#   sudo mist-multicast-tune.sh --check    # report only
#   sudo mist-multicast-tune.sh --apply    # back up the FOG tables, then apply
#
# Why this exists:
#   * nfsGroupMembers.ngmMaxClients defaults to 10, which caps a multicast session.
#   * FOG_UDPCAST_MAXWAIT is in minutes and defaults to 10, which delays the start.
#   * ngmMaxBitrate is empty, so udp-sender is not capped to the link budget.
#
# Settings come from /etc/mist/mist.env:
#   JOG_MULTICAST_MAX_CLIENTS (100), JOG_MULTICAST_BITRATE (800m),
#   JOG_MULTICAST_MAXWAIT_MIN (3), JOG_MULTICAST_MAX_SESSIONS (64),
#   JOG_MULTICAST_RENDEZVOUS (the imaging interface's IPv4 address)
#
# The bitrate is a udp-sender --max-bitrate value: 800m = 800 Mbps.
# The rendezvous address must match the address the FOS client uses for
# $storageip. If it is empty, udp-sender and udp-receiver can wait on
# different control addresses and the session never starts.

log()  { echo "[mist-multicast-tune] $*"; }
warn() { echo "[mist-multicast-tune] WARN: $*" >&2; }
die()  { echo "[mist-multicast-tune] ERROR: $*" >&2; exit 1; }

MODE="--check"
for arg in "$@"; do
  case "$arg" in
    --check) MODE="--check" ;;
    --apply) MODE="--apply" ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

if [[ -f /etc/mist/mist.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /etc/mist/mist.env
  set +a
fi

MAX_CLIENTS="${Brume_MULTICAST_MAX_CLIENTS:-${JOG_MULTICAST_MAX_CLIENTS:-100}}"
BITRATE="${Brume_MULTICAST_BITRATE:-${JOG_MULTICAST_BITRATE:-800m}}"
MAXWAIT="${Brume_MULTICAST_MAXWAIT_MIN:-${JOG_MULTICAST_MAXWAIT_MIN:-3}}"
MAX_SESSIONS="${Brume_MULTICAST_MAX_SESSIONS:-${JOG_MULTICAST_MAX_SESSIONS:-64}}"
IFACE="${Brume_MULTICAST_IFACE:-${JOG_MULTICAST_IFACE:-${JOG_USB_IFACE:-}}}"
RENDEZVOUS="${JOG_MULTICAST_RENDEZVOUS:-}"

[[ "$MAX_CLIENTS" =~ ^[0-9]+$ ]] || die "JOG_MULTICAST_MAX_CLIENTS must be numeric"
[[ "$MAXWAIT" =~ ^[0-9]+$ ]] || die "JOG_MULTICAST_MAXWAIT_MIN must be numeric (minutes)"
[[ "$MAX_SESSIONS" =~ ^[0-9]+$ ]] || die "JOG_MULTICAST_MAX_SESSIONS must be numeric"
[[ "$BITRATE" =~ ^[0-9]+[kmg]?$ ]] || die "JOG_MULTICAST_BITRATE must look like 800m, 1g, or 500000k"
[[ -z "$RENDEZVOUS" || "$RENDEZVOUS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "JOG_MULTICAST_RENDEZVOUS must be an IPv4 address"

FOG_SETTINGS="/opt/fog/.fogsettings"
if [[ -f "$FOG_SETTINGS" ]]; then
  # shellcheck disable=SC1090
  source "$FOG_SETTINGS"
fi
DB_USER="${DB_user:-fogmaster}"
DB_PASS="${DB_password:-}"
DB_HOST="${DB_host:-localhost}"
DB_NAME="${DB_name:-fog}"
if [[ -z "$IFACE" && -n "${NET_interface:-}" ]]; then IFACE="$NET_interface"; fi
if [[ -z "$IFACE" ]]; then
  IFACE="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')"
fi
[[ -n "$IFACE" ]] || die "could not determine the imaging interface; set JOG_USB_IFACE"
if [[ -z "$RENDEZVOUS" ]]; then
  RENDEZVOUS="$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
fi
[[ -n "$RENDEZVOUS" ]] || die "could not determine the multicast rendezvous address; set JOG_MULTICAST_RENDEZVOUS"

MYSQL_DEFAULTS=""
cleanup() { [[ -n "$MYSQL_DEFAULTS" && -f "$MYSQL_DEFAULTS" ]] && rm -f "$MYSQL_DEFAULTS"; }
trap cleanup EXIT

mysql_run() {
  if [[ -n "$DB_PASS" ]]; then
    if [[ -z "$MYSQL_DEFAULTS" ]]; then
      MYSQL_DEFAULTS="$(mktemp)"
      chmod 0600 "$MYSQL_DEFAULTS"
      cat > "$MYSQL_DEFAULTS" <<EOF
[client]
user=${DB_USER}
password=${DB_PASS}
host=${DB_HOST}
EOF
    fi
    mysql --defaults-extra-file="$MYSQL_DEFAULTS" -N -B "$DB_NAME" "$@"
  else
    mysql -N -B "$DB_NAME" "$@"
  fi
}

query_current() {
  mysql_run -e "SELECT ngmID,ngmMemberName,ngmMaxClients,ngmMaxBitrate,ngmInterface,ngmIsMasterNode FROM nfsGroupMembers;" 2>/dev/null || true
  mysql_run -e "SELECT settingKey,settingValue FROM globalSettings WHERE settingKey IN ('FOG_UDPCAST_MAXWAIT','FOG_MULTICAST_MAX_SESSIONS','FOG_MULTICAST_DUPLEX','FOG_UDPCAST_INTERFACE','FOG_MULTICAST_ADDRESS','FOG_MULTICAST_RENDEZVOUS','MULTICASTGLOBALENABLED') ORDER BY settingKey;" 2>/dev/null || true
}

show_summary() {
  cat <<EOF
[mist-multicast-tune] target profile
  storage node clients : ${MAX_CLIENTS}
  max bitrate          : ${BITRATE}  (udp-sender --max-bitrate)
  join wait            : ${MAXWAIT} minute(s)
  concurrent sessions  : ${MAX_SESSIONS}
  interface            : ${IFACE}
  rendezvous address   : ${RENDEZVOUS}
EOF
}

link_speed_check() {
  if ! command -v ethtool >/dev/null 2>&1; then
    warn "ethtool not installed; cannot check the link speed"
    return 0
  fi
  local speed
  speed="$(ethtool "$IFACE" 2>/dev/null | awk -F: '/Speed:/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
  if [[ -z "$speed" ]]; then
    warn "could not read link speed for ${IFACE} (link down?)"
    return 0
  fi
  log "link speed on ${IFACE}: ${speed} Mb/s"
  if [[ "$speed" -lt 10000 ]]; then
    warn "the reference design wants a 10/25 GbE server uplink; ${speed} Mb/s will cap the room"
  fi
}

# --- check -----------------------------------------------------------------

if [[ "$MODE" == "--check" ]]; then
  show_summary
  echo
  log "current FOG values:"
  query_current
  echo
  link_speed_check
  if command -v udp-sender >/dev/null 2>&1; then
    log "udp-sender: $(command -v udp-sender)"
  elif [[ -x /opt/fog/udpcast/udp-sender ]]; then
    log "udp-sender: /opt/fog/udpcast/udp-sender"
  else
    warn "udp-sender not found in PATH or /opt/fog/udpcast"
  fi

  rc=0
  current_clients="$(mysql_run -e "SELECT ngmMaxClients FROM nfsGroupMembers WHERE ngmIsMasterNode=1 LIMIT 1;" 2>/dev/null || true)"
  current_bitrate="$(mysql_run -e "SELECT ngmMaxBitrate FROM nfsGroupMembers WHERE ngmIsMasterNode=1 LIMIT 1;" 2>/dev/null || true)"
  current_wait="$(mysql_run -e "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_UDPCAST_MAXWAIT' LIMIT 1;" 2>/dev/null || true)"
  current_rdv="$(mysql_run -e "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_MULTICAST_RENDEZVOUS' LIMIT 1;" 2>/dev/null || true)"
  [[ "${current_clients:-0}" -ge "$MAX_CLIENTS" ]] 2>/dev/null || { warn "ngmMaxClients is ${current_clients:-unknown}, target ${MAX_CLIENTS}"; rc=1; }
  [[ "${current_bitrate:-}" == "$BITRATE" ]] || { warn "ngmMaxBitrate is '${current_bitrate:-empty}', target ${BITRATE}"; rc=1; }
  [[ "${current_wait:-}" == "$MAXWAIT" ]] || { warn "FOG_UDPCAST_MAXWAIT is '${current_wait:-unknown}', target ${MAXWAIT}"; rc=1; }
  [[ "${current_rdv:-}" == "$RENDEZVOUS" ]] || { warn "FOG_MULTICAST_RENDEZVOUS is '${current_rdv:-empty}', target ${RENDEZVOUS}"; rc=1; }
  [[ "$rc" -eq 0 ]] && log "check passed" || log "check found drift; run --apply"
  exit "$rc"
fi

# --- apply -----------------------------------------------------------------

[[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0 --apply"
command -v mysql >/dev/null 2>&1 || die "mysql client not installed"
mysql_run -e "SELECT 1;" >/dev/null 2>&1 || die "cannot connect to the FOG database"

BACKUP_DIR="/var/backups/mist"
install -d -m 0750 "$BACKUP_DIR"
BACKUP="${BACKUP_DIR}/fog-multicast-$(date +%Y%m%d-%H%M%S).sql"
if [[ -n "$MYSQL_DEFAULTS" ]]; then
  mysqldump --defaults-extra-file="$MYSQL_DEFAULTS" "$DB_NAME" nfsGroupMembers globalSettings > "$BACKUP"
else
  mysqldump "$DB_NAME" nfsGroupMembers globalSettings > "$BACKUP"
fi
log "backed up nfsGroupMembers + globalSettings to ${BACKUP}"

mysql_run -e "UPDATE nfsGroupMembers SET ngmMaxClients=${MAX_CLIENTS}, ngmMaxBitrate='${BITRATE}', ngmInterface='${IFACE}';"
mysql_run -e "INSERT INTO globalSettings (settingKey,settingValue) VALUES ('FOG_UDPCAST_MAXWAIT','${MAXWAIT}') ON DUPLICATE KEY UPDATE settingValue=VALUES(settingValue);"
mysql_run -e "INSERT INTO globalSettings (settingKey,settingValue) VALUES ('FOG_MULTICAST_MAX_SESSIONS','${MAX_SESSIONS}') ON DUPLICATE KEY UPDATE settingValue=VALUES(settingValue);"
mysql_run -e "INSERT INTO globalSettings (settingKey,settingValue) VALUES ('FOG_MULTICAST_DUPLEX','--full-duplex') ON DUPLICATE KEY UPDATE settingValue=VALUES(settingValue);"
mysql_run -e "INSERT INTO globalSettings (settingKey,settingValue) VALUES ('FOG_UDPCAST_INTERFACE','${IFACE}') ON DUPLICATE KEY UPDATE settingValue=VALUES(settingValue);"
mysql_run -e "INSERT INTO globalSettings (settingKey,settingValue) VALUES ('FOG_MULTICAST_RENDEZVOUS','${RENDEZVOUS}') ON DUPLICATE KEY UPDATE settingValue=VALUES(settingValue);"
mysql_run -e "INSERT INTO globalSettings (settingKey,settingValue) VALUES ('MULTICASTGLOBALENABLED','1') ON DUPLICATE KEY UPDATE settingValue=VALUES(settingValue);"

show_summary
echo
log "applied values:"
query_current
echo
link_speed_check
log "done. Re-create any existing multicast session so it picks up the new maxwait."
log "Note: FOG_UDPCAST_MAXWAIT is minutes; the session stores maxwait = value x 60 seconds."
