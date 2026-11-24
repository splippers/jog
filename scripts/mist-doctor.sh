#!/bin/bash
# Verify the Secure Boot PXE chain staged on this Brume: bootfile -> shim -> grub -> signed kernel -> JOS initrd.
# Exit 0 only if every check passes. Safe to run any time; changes nothing.
TFTP="${Brume_TFTP_ROOT:-${JOG_TFTP_ROOT:-/tftpboot}}"
[[ -f /etc/mist/mist.env ]] && source /etc/mist/mist.env
BOOTFILE="${Brume_DHCP_BOOTFILE:-${JOG_DHCP_BOOTFILE:-ubuntu-signed/shimx64.efi}}"
rc=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; rc=1; }
signed() { sbverify --list "$1" 2>&1 | grep -q 'signature 1'; }

echo "Brume doctor (tftp root: $TFTP)"
if [[ ! -f "$TFTP/$BOOTFILE" ]]; then bad "bootfile $BOOTFILE missing"
elif signed "$TFTP/$BOOTFILE"; then ok "bootfile $BOOTFILE is signed"
else bad "bootfile $BOOTFILE is UNSIGNED — Secure Boot machines will refuse it (set JOG_DHCP_BOOTFILE=ubuntu-signed/shimx64.efi)"; fi

D="$(dirname "$TFTP/$BOOTFILE")"
if [[ -f "$D/grubx64.efi" ]] && signed "$D/grubx64.efi"; then ok "grubx64.efi next to shim is signed"; else bad "signed grubx64.efi missing next to shim"; fi
if [[ -f "$D/grubx64.efi" ]] && [[ -f "$D/grubnetx64.efi" ]] && cmp -s "$D/grubx64.efi" "$D/grubnetx64.efi"; then ok "grubx64.efi is the network build"; else bad "grubx64.efi is not grubnetx64 (PXE GRUB would not find grub.cfg)"; fi
[[ -f "$TFTP/grub/grub.cfg" ]] && ok "grub/grub.cfg present" || bad "grub/grub.cfg missing (run mist-stage-jos-boot.sh)"
if [[ -f "$TFTP/jos/vmlinuz" ]] && signed "$TFTP/jos/vmlinuz"; then ok "jos/vmlinuz is signed"; else bad "jos/vmlinuz missing or unsigned"; fi
[[ -s "$TFTP/jos/initrd.img" ]] && ok "jos/initrd.img present" || bad "jos/initrd.img missing"
[[ -s "$TFTP/jos/modules.img" ]] && ok "jos/modules.img present" || bad "jos/modules.img missing"
if [[ -f "$TFTP/jos/kver" ]]; then
  if [[ -d "/lib/modules/$(cat "$TFTP/jos/kver")" ]]; then ok "staged kernel $(cat "$TFTP/jos/kver") still installed"
  else bad "staged kernel $(cat "$TFTP/jos/kver") no longer installed locally (restage after upgrades)"; fi
fi

# --- corporate pipeline ----------------------------------------------------
# These checks are advisory unless JOG_CORPORATE_STRICT=1, so the Secure Boot
# doctor still passes on a plain imaging appliance.

corp_bad() {
  if [[ "${Brume_CORPORATE_STRICT:-${JOG_CORPORATE_STRICT:-0}}" == "1" ]]; then bad "$*"; else echo "  warn  $*"; fi
}

echo
echo "Brume corporate pipeline"

if command -v smbclient >/dev/null 2>&1; then ok "smbclient installed"; else corp_bad "smbclient not installed"; fi
if command -v testparm >/dev/null 2>&1; then
  if testparm -s 2>/dev/null | grep -qE '^\[Drivers\]'; then ok "Samba [Drivers] share configured"
  else corp_bad "Samba [Drivers] share not found (run mist-driver-share.sh --apply)"; fi
else
  corp_bad "testparm not installed (Samba missing)"
fi
SHARE_PATH="${Brume_DRIVER_SHARE_PATH:-${JOG_DRIVER_SHARE_PATH:-/srv/mist/drivers}}"
if [[ -d "$SHARE_PATH" ]]; then ok "driver share path $SHARE_PATH exists"
else corp_bad "driver share path $SHARE_PATH missing"; fi
if [[ -r /etc/mist/driver-share.env ]]; then ok "driver-share credentials generated"
else corp_bad "/etc/mist/driver-share.env missing (run mist-driver-share.sh --apply)"; fi
if systemctl is-active --quiet mist-model-api.service 2>/dev/null; then
  ok "model API service active"
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 3 http://127.0.0.1:8089/healthz >/dev/null 2>&1; then
    ok "model API health endpoint"
  else
    corp_bad "model API health endpoint failed (journalctl -u mist-model-api)"
  fi
else
  corp_bad "model API service not active (run mist-model-api-setup.sh --apply)"
fi

if [[ "${Brume_AUTOJOIN_ENABLE:-${JOG_AUTOJOIN_ENABLE:-1}}" == "1" ]]; then
  AUTOJOIN=/var/www/html/fog/service/mist-autojoin.php
  [[ -f "$AUTOJOIN" ]] || AUTOJOIN=/var/www/fog/service/mist-autojoin.php
  if [[ -f "$AUTOJOIN" ]]; then
    ok "multicast auto-join endpoint installed"
    if command -v php >/dev/null 2>&1 && php -l "$AUTOJOIN" >/dev/null 2>&1; then
      ok "multicast auto-join endpoint parses"
    else
      corp_bad "multicast auto-join endpoint does not parse"
    fi
    if command -v curl >/dev/null 2>&1; then
      aj_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 \
        -X POST --data 'mac=00:00:00:00:00:00' \
        http://127.0.0.1/fog/service/mist-autojoin.php 2>/dev/null || true)"
      case "$aj_code" in
        200|400) ok "multicast auto-join endpoint reachable (HTTP $aj_code)" ;;
        404) corp_bad "multicast auto-join endpoint returns 404" ;;
        *) echo "  warn  multicast auto-join endpoint returned HTTP ${aj_code:-none}" ;;
      esac
    fi
  else
    corp_bad "multicast auto-join endpoint missing (run mist-autojoin-setup.sh --apply)"
  fi
fi

PAYLOAD=/images/postdownloadscripts/mist-provisioner
if [[ -f "$PAYLOAD/Start-JOGProvisioning.ps1" ]]; then ok "provisioner payload installed"
else corp_bad "provisioner payload missing ($PAYLOAD)"; fi
if [[ -f "$PAYLOAD/mist-provisioning.json" ]]; then
  if python3 -m json.tool "$PAYLOAD/mist-provisioning.json" >/dev/null 2>&1; then ok "provisioning config is valid JSON"
  else corp_bad "provisioning config is not valid JSON"; fi
else
  corp_bad "rendered provisioning config missing"
fi
if [[ -f /images/postdownloadscripts/mist-inject-provisioner.sh ]]; then ok "post-download injection installed"
else corp_bad "post-download injection missing"; fi
if [[ -f /images/postdownloadscripts/fog.postdownload ]] && grep -qF mist-inject-provisioner /images/postdownloadscripts/fog.postdownload; then
  ok "fog.postdownload calls the injection"
else
  corp_bad "fog.postdownload does not call mist-inject-provisioner.sh"
fi

db_query() {
  local sql="$1"
  [[ -r /opt/fog/.fogsettings ]] || return 1
  # shellcheck disable=SC1091
  source /opt/fog/.fogsettings
  local tmp
  tmp="$(mktemp)"
  chmod 0600 "$tmp"
  printf '[client]\nuser=%s\npassword=%s\nhost=%s\n' "${DB_user:-fogmaster}" "${DB_password:-}" "${DB_host:-localhost}" > "$tmp"
  mysql --defaults-extra-file="$tmp" -N -B "${DB_name:-fog}" -e "$sql" 2>/dev/null
  local rc=$?
  rm -f "$tmp"
  return $rc
}

if db_query "SELECT 1;" >/dev/null 2>&1; then
  clients="$(db_query "SELECT ngmMaxClients FROM nfsGroupMembers WHERE ngmIsMasterNode=1 LIMIT 1;")"
  bitrate="$(db_query "SELECT ngmMaxBitrate FROM nfsGroupMembers WHERE ngmIsMasterNode=1 LIMIT 1;")"
  maxwait="$(db_query "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_UDPCAST_MAXWAIT' LIMIT 1;")"
  rendezvous="$(db_query "SELECT settingValue FROM globalSettings WHERE settingKey='FOG_MULTICAST_RENDEZVOUS' LIMIT 1;")"
  if [[ "${clients:-0}" -ge 100 ]] 2>/dev/null; then ok "multicast client cap: $clients"
  else corp_bad "multicast client cap is ${clients:-unknown} (target 100)"; fi
  if [[ -n "$bitrate" ]]; then ok "multicast bitrate: $bitrate"
  else corp_bad "multicast bitrate is empty (target 800m)"; fi
  if [[ "${maxwait:-99}" -le 3 ]] 2>/dev/null; then ok "multicast join wait: ${maxwait}m"
  else corp_bad "multicast join wait is ${maxwait:-unknown}m (target 3m)"; fi
  if [[ -n "$rendezvous" ]]; then ok "multicast rendezvous: $rendezvous"
  else corp_bad "multicast rendezvous is empty (run mist-multicast-tune.sh --apply)"; fi
  null_sessions="$(db_query "SELECT COUNT(*) FROM multicastSessions WHERE msState IS NULL;")"
  if [[ "${null_sessions:-0}" -gt 0 ]] 2>/dev/null; then
    corp_bad "$null_sessions multicast session(s) have msState=NULL and will never start (requeue or delete them)"
  else
    ok "no stateless multicast sessions"
  fi
else
  echo "  warn  cannot read the FOG database (run as root, or FOG is not installed)"
fi

exit $rc
