#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log

# jog-corporate-setup.sh — render /etc/jog/provisioning.env and install the Windows payload.
#
#   sudo jog-corporate-setup.sh                 # interactive
#   sudo jog-corporate-setup.sh --non-interactive
#   sudo jog-corporate-setup.sh --show          # print the current config, no secrets
#
# The resulting file is mode 0600. It is read by jog-install-provisioner.sh, which
# renders /images/postdownloadscripts/jog-provisioner/jog-provisioning.json.
#
# Nothing here talks to the domain. It only writes configuration.

log()  { echo "[jog-corporate-setup] $*"; }
warn() { echo "[jog-corporate-setup] WARN: $*" >&2; }
die()  { echo "[jog-corporate-setup] ERROR: $*" >&2; exit 1; }

CONFIG=/etc/jog/provisioning.env
JOG_ENV=/etc/jog/jog.env
DRIVER_ENV=/etc/jog/driver-share.env
MODE=interactive

for arg in "$@"; do
  case "$arg" in
    --non-interactive) MODE=non-interactive ;;
    --show) MODE=show ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0"

if [[ -f "$JOG_ENV" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$JOG_ENV"
  set +a
fi
if [[ -f "$DRIVER_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$DRIVER_ENV"
  set +a
fi

# Existing values become the defaults.
if [[ -f "$CONFIG" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CONFIG"
  set +a
fi

SITE="${JOG_SITE_CODE:-SITE01}"
ORG="${JOG_ORG_NAME:-Example Corporation}"
PATTERN="${JOG_DEVICE_NAME_PATTERN:-LT-{Site}-{Serial}}"
DOMAIN="${JOG_DOMAIN:-corp.example.com}"
NETBIOS="${JOG_DOMAIN_NETBIOS:-CORP}"
JOIN_MODE="${JOG_DOMAIN_JOIN_MODE:-Credential}"
OU="${JOG_DOMAIN_JOIN_OU:-OU=Workstations,OU=JOG,DC=corp,DC=example,DC=com}"
JOIN_USER="${JOG_DOMAIN_JOIN_USER:-}"
JOIN_PASS="${JOG_DOMAIN_JOIN_PASSWORD:-}"
BLOB="${JOG_DOMAIN_JOIN_BLOB:-}"
HYBRID="${JOG_HYBRID_JOIN:-1}"
HYBRID_TIMEOUT="${JOG_HYBRID_JOIN_TIMEOUT_MIN:-30}"
GROUPS="${JOG_AD_GROUPS:-JOG-Workstations,EndpointProtection,DeviceEncryption}"
GROUPS_MODE="${JOG_GROUPS_MODE:-Device}"
BL_ENABLED="${JOG_BITLOCKER_ENABLED:-1}"
BL_MODE="${JOG_BITLOCKER_MODE:-TpmOnly}"
BL_PIN_LEN="${JOG_BITLOCKER_PIN_LENGTH:-6}"
BL_ESCROW="${JOG_BITLOCKER_ESCROW:-AD}"
BL_PIN_STORAGE="${JOG_BITLOCKER_PIN_STORAGE:-None}"
BL_ALLOW_AD_PIN="${JOG_BITLOCKER_ALLOW_AD_PIN_STORAGE:-0}"
BL_AD_ATTR="${JOG_BITLOCKER_AD_PIN_ATTRIBUTE:-extensionAttribute15}"
UNC="${JOG_DRIVER_SHARE_UNC:-\\\\10.99.0.1\\Drivers}"
READ_USER="${JOG_DRIVER_READ_USER:-drivers}"
READ_PASS="${JOG_DRIVER_READ_PASSWORD:-}"
MODEL_MAP="${JOG_DRIVER_MODEL_MAP:-{}}"
FALLBACK="${JOG_DRIVER_FALLBACK:-Default}"
REBOOT="${JOG_PROVISIONING_REBOOT_BETWEEN_STAGES:-1}"
SHUTDOWN="${JOG_PROVISIONING_SHUTDOWN_ON_COMPLETE:-0}"
MAX_ATTEMPTS="${JOG_PROVISIONING_MAX_ATTEMPTS:-5}"
DELETE_CONFIG="${JOG_PROVISIONING_DELETE_CONFIG_ON_COMPLETE:-1}"
PROV_MODE="${JOG_PROVISIONING_MODE:-AirGapped}"
BASE_PACKS="${JOG_DRIVER_BASE_PACKS:-VMD}"
MANIFEST="${JOG_DRIVER_MANIFEST:-manifest.json}"
ENABLE="${JOG_PROVISIONING_ENABLE:-0}"

ask() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value || true
  printf '%s' "${value:-$default}"
}

ask_secret() {
  local prompt="$1" value
  read -r -s -p "$prompt: " value || true
  echo >&2
  printf '%s' "$value"
}

ask_yesno() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value || true
  value="${value:-$default}"
  [[ "$value" =~ ^[Yy] ]]
}

if [[ "$MODE" == "show" ]]; then
  log "config: $CONFIG"
  if [[ -f "$CONFIG" ]]; then
    # Never print passwords.
    sed -E 's/^(JOG_DOMAIN_JOIN_PASSWORD|JOG_DRIVER_READ_PASSWORD)=.*/\1=REDACTED/' "$CONFIG"
  else
    log "not created yet"
  fi
  exit 0
fi

if [[ "$MODE" == "interactive" ]]; then
  echo
  echo "JOG corporate provisioning"
  echo "--------------------------"
  echo "Enter to accept the value in brackets. Nothing is written until the end."
  echo

  SITE="$(ask 'Site code' "$SITE")"
  ORG="$(ask 'Organisation name' "$ORG")"
  PATTERN="$(ask 'Computer-name pattern' "$PATTERN")"
  DOMAIN="$(ask 'AD DNS domain' "$DOMAIN")"
  NETBIOS="$(ask 'AD NetBIOS name' "$NETBIOS")"
  OU="$(ask 'Target OU' "$OU")"
  JOIN_MODE="$(ask 'Join mode (Offline|Credential)' "$JOIN_MODE")"
  PROV_MODE="$(ask 'Provisioning mode (AirGapped|Connected)' "$PROV_MODE")"
  if [[ "$PROV_MODE" == "AirGapped" ]]; then
    echo "AirGapped leaves the device at AWAITING_CORPORATE; the join account is prompted on the corporate LAN." >&2
  fi
  if [[ "$JOIN_MODE" == "Credential" ]]; then
    JOIN_USER="$(ask 'Delegated join account (UPN or DOMAIN\\user)' "$JOIN_USER")"
    if ask_yesno 'Set/replace the join password?' 'n'; then
      JOIN_PASS="$(ask_secret 'Join password')"
    fi
  else
    echo "Offline mode uses one djoin blob for one computer account." >&2
    echo "For a fleet, use Credential mode or generate a per-device blob." >&2
    BLOB="$(ask 'djoin blob path on this appliance (blank = inject later)' "$BLOB")"
  fi
  if ask_yesno 'Enable Entra hybrid join?' "$([[ "$HYBRID" == "1" ]] && echo y || echo n)"; then HYBRID=1; else HYBRID=0; fi
  HYBRID_TIMEOUT="$(ask 'Hybrid-join timeout (minutes)' "$HYBRID_TIMEOUT")"
  GROUPS="$(ask 'AD groups (comma-separated)' "$GROUPS")"
  BL_MODE="$(ask 'BitLocker mode (TpmOnly|TpmPin)' "$BL_MODE")"
  BL_ESCROW="$(ask 'BitLocker escrow (AD|Entra|Both|None)' "$BL_ESCROW")"
  if [[ "$BL_MODE" == "TpmPin" ]]; then
    BL_PIN_LEN="$(ask 'BitLocker PIN length' "$BL_PIN_LEN")"
    BL_PIN_STORAGE="$(ask 'PIN storage (None|LocalDPAPI|ADCustomAttribute)' "$BL_PIN_STORAGE")"
    if [[ "$BL_PIN_STORAGE" == "ADCustomAttribute" ]]; then
      BL_ALLOW_AD_PIN="$(ask 'Allow PIN in AD? (0|1)' "$BL_ALLOW_AD_PIN")"
      BL_AD_ATTR="$(ask 'AD PIN attribute' "$BL_AD_ATTR")"
    fi
  fi
  UNC="$(ask 'Driver share UNC' "$UNC")"
  READ_USER="$(ask 'Driver read account' "$READ_USER")"
  if ask_yesno 'Set/replace the driver-share read password?' 'n'; then
    READ_PASS="$(ask_secret 'Driver read password')"
  fi
  MODEL_MAP="$(ask 'Driver model map JSON' "$MODEL_MAP")"
  BASE_PACKS="$(ask 'Base driver packs (comma-separated)' "$BASE_PACKS")"
  MANIFEST="$(ask 'Driver manifest name' "$MANIFEST")"
  if ask_yesno 'Install the payload and post-download hook now?' "$([[ "$ENABLE" == "1" ]] && echo y || echo n)"; then ENABLE=1; else ENABLE=0; fi
  echo
fi

# --- validation ------------------------------------------------------------

[[ -n "$SITE" ]] || die "site code is empty"
[[ -n "$DOMAIN" ]] || die "domain is empty"
[[ "$JOIN_MODE" == "Offline" || "$JOIN_MODE" == "Credential" ]] || die "join mode must be Offline or Credential"
[[ "$PROV_MODE" == "AirGapped" || "$PROV_MODE" == "Connected" ]] || die "provisioning mode must be AirGapped or Connected"
[[ "$BL_MODE" == "TpmOnly" || "$BL_MODE" == "TpmPin" ]] || die "BitLocker mode must be TpmOnly or TpmPin"
[[ "$BL_ESCROW" =~ ^(AD|Entra|Both|None)$ ]] || die "BitLocker escrow must be AD, Entra, Both, or None"
[[ "$BL_PIN_STORAGE" =~ ^(None|LocalDPAPI|ADCustomAttribute)$ ]] || die "PIN storage must be None, LocalDPAPI, or ADCustomAttribute"
if [[ "$BL_PIN_STORAGE" == "ADCustomAttribute" && "$BL_ALLOW_AD_PIN" != "1" ]]; then
  die "ADCustomAttribute requires JOG_BITLOCKER_ALLOW_AD_PIN_STORAGE=1 (not recommended)"
fi
if [[ "$JOIN_MODE" == "Credential" && "$PROV_MODE" == "Connected" ]]; then
  [[ -n "$JOIN_USER" ]] || die "connected credential join needs a join account"
fi
if [[ "$JOIN_MODE" == "Credential" && "$PROV_MODE" == "AirGapped" && -z "$JOIN_USER" ]]; then
  warn "air-gapped credential join: the join account is prompted by Resume-JOGCorporateEnrollment.ps1"
fi

# Single quotes would break the shell env file. Reject them rather than write
# something that sources incorrectly.
for value in "$ORG" "$PATTERN" "$OU" "$JOIN_USER" "$JOIN_PASS" "$GROUPS" "$UNC" "$READ_USER" "$READ_PASS" "$MODEL_MAP" "$BLOB" "$BASE_PACKS" "$MANIFEST"; do
  [[ "$value" != *"'"* ]] || die "values may not contain a single quote (found in: $value)"
done

python3 - "$MODEL_MAP" <<'PY' || die "JOG_DRIVER_MODEL_MAP is not valid JSON"
import json, sys
json.loads(sys.argv[1])
PY

if [[ "$JOIN_MODE" == "Offline" && -n "$BLOB" && ! -f "$BLOB" ]]; then
  warn "offline join blob does not exist yet: $BLOB"
fi
if [[ "$JOIN_MODE" == "Offline" ]]; then
  warn "Offline mode: one djoin blob joins one computer account. Use Credential for a fleet, or generate a per-device blob."
fi
if [[ -z "$READ_PASS" ]]; then
  warn "driver read password is empty; run jog-driver-share.sh --apply or set it here"
fi

# --- write -----------------------------------------------------------------

install -d -m 0755 /etc/jog
umask 077
cat > "$CONFIG" <<EOF
# /etc/jog/provisioning.env — generated by jog-corporate-setup.sh
# Mode 0600. Never commit this file.

JOG_SITE_CODE='${SITE}'
JOG_ORG_NAME='${ORG}'
JOG_DEVICE_NAME_PATTERN='${PATTERN}'

JOG_PROVISIONING_MODE='${PROV_MODE}'

JOG_DOMAIN='${DOMAIN}'
JOG_DOMAIN_NETBIOS='${NETBIOS}'
JOG_DOMAIN_JOIN_MODE='${JOIN_MODE}'
JOG_DOMAIN_JOIN_OU='${OU}'
JOG_DOMAIN_JOIN_USER='${JOIN_USER}'
JOG_DOMAIN_JOIN_PASSWORD='${JOIN_PASS}'
JOG_DOMAIN_JOIN_BLOB='${BLOB}'

JOG_HYBRID_JOIN='${HYBRID}'
JOG_HYBRID_JOIN_TIMEOUT_MIN='${HYBRID_TIMEOUT}'

JOG_AD_GROUPS='${GROUPS}'
JOG_GROUPS_MODE='${GROUPS_MODE}'

JOG_BITLOCKER_ENABLED='${BL_ENABLED}'
JOG_BITLOCKER_MODE='${BL_MODE}'
JOG_BITLOCKER_PIN_LENGTH='${BL_PIN_LEN}'
JOG_BITLOCKER_ESCROW='${BL_ESCROW}'
JOG_BITLOCKER_PIN_STORAGE='${BL_PIN_STORAGE}'
JOG_BITLOCKER_ALLOW_AD_PIN_STORAGE='${BL_ALLOW_AD_PIN}'
JOG_BITLOCKER_AD_PIN_ATTRIBUTE='${BL_AD_ATTR}'

JOG_DRIVER_SHARE_UNC='${UNC}'
JOG_DRIVER_READ_USER='${READ_USER}'
JOG_DRIVER_READ_PASSWORD='${READ_PASS}'
JOG_DRIVER_MODEL_MAP='${MODEL_MAP}'
JOG_DRIVER_FALLBACK='${FALLBACK}'
JOG_DRIVER_BASE_PACKS='${BASE_PACKS}'
JOG_DRIVER_MANIFEST='${MANIFEST}'

JOG_PROVISIONING_REBOOT_BETWEEN_STAGES='${REBOOT}'
JOG_PROVISIONING_SHUTDOWN_ON_COMPLETE='${SHUTDOWN}'
JOG_PROVISIONING_MAX_ATTEMPTS='${MAX_ATTEMPTS}'
JOG_PROVISIONING_DELETE_CONFIG_ON_COMPLETE='${DELETE_CONFIG}'
JOG_PROVISIONING_ENABLE='${ENABLE}'
EOF
chmod 0600 "$CONFIG"
chown root:root "$CONFIG"

log "wrote $CONFIG (0600)"
if [[ "$ENABLE" == "1" ]]; then
  if [[ -x /usr/local/sbin/jog-install-provisioner.sh ]]; then
    /usr/local/sbin/jog-install-provisioner.sh
  else
    warn "jog-install-provisioner.sh not installed; run it from the repo"
  fi
else
  log "payload not installed (JOG_PROVISIONING_ENABLE=0)."
  log "Install it with: sudo jog-install-provisioner.sh"
fi
