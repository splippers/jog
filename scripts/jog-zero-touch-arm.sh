#!/bin/bash
# jog-zero-touch-arm.sh — arm the prebuilt multicast job for zero-touch imaging.
#
# Usage:
#   sudo jog-zero-touch-arm [--image NAME] [--clients N] [--name NAME]
#                             [--maxwait SECONDS]
#
# For one directly-connected test laptop use --clients 1. The default of 10
# makes udp-sender wait for nine more receivers that will never arrive.
#
# Creates a fresh, named, joinable FOG multicast session. The JOS default PXE
# entry calls jog-autojoin.php, which registers unknown hosts from their MAC
# and attaches them to this session. Run this immediately before the laptops
# are PXE-booted: udp-sender waits for --clients receivers, then transmits.
#
# Nothing here stores a FOG credential or changes FOG's schema. The session is
# inserted with the same fields FOG writes when a group is tasked.

set -euo pipefail

IMAGE_NAME="WIN11-NOV26-18"
CLIENTS=10
SESSION_NAME="JOG-DELL-ZERO"
SENDER_PORT=63100
MAXWAIT=180

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[jog-zero-touch-arm] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)   IMAGE_NAME="${2:?--image needs a value}"; shift 2 ;;
    --clients) CLIENTS="${2:?--clients needs a value}"; shift 2 ;;
    --name)    SESSION_NAME="${2:?--name needs a value}"; shift 2 ;;
    --maxwait) MAXWAIT="${2:?--maxwait needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "run as root"
[[ "$CLIENTS" =~ ^[0-9]+$ ]] && (( CLIENTS >= 1 )) || die "--clients must be a positive integer"
[[ "$MAXWAIT" =~ ^[0-9]+$ ]] && (( MAXWAIT >= 1 )) || die "--maxwait must be a positive integer"

MYSQL=(mysql -N -D fog -e)

# FOG's display name and its on-disk path can differ (this appliance stores
# "WIN11-NOV26 - (18)" as the name and "WIN11-NOV26-18" as the path), so accept
# either spelling.
IMAGE_ID="$("${MYSQL[@]}" "SELECT imageID FROM images WHERE imageName='$IMAGE_NAME' OR imagePath='$IMAGE_NAME' LIMIT 1;" 2>/dev/null || true)"
[[ -n "$IMAGE_ID" ]] || die "image '$IMAGE_NAME' not found in FOG"
IMAGE_PATH="$("${MYSQL[@]}" "SELECT imagePath FROM images WHERE imageID=$IMAGE_ID;" | head -1)"
IMAGE_TYPE="$("${MYSQL[@]}" "SELECT imageTypeID FROM images WHERE imageID=$IMAGE_ID;" | head -1)"
GROUP_ID="$("${MYSQL[@]}" "SELECT ngmGroupID FROM nfsGroupMembers WHERE ngmIsMasterNode='1' AND ngmIsEnabled='1' LIMIT 1;" | head -1)"
IFACE="$("${MYSQL[@]}" "SELECT ngmInterface FROM nfsGroupMembers WHERE ngmIsMasterNode='1' AND ngmIsEnabled='1' LIMIT 1;" | head -1)"
[[ -n "$IMAGE_PATH" && -n "$IMAGE_TYPE" && -n "$GROUP_ID" && -n "$IFACE" ]] || die "cannot resolve image/storage-node fields"
[[ -d "/images/$IMAGE_PATH" ]] || die "image directory /images/$IMAGE_PATH missing"

# Retire any live session with the same name, and stop its sender.
ACTIVE_IDS="$("${MYSQL[@]}" "SELECT msID FROM multicastSessions WHERE msName='$SESSION_NAME' AND msState IN (1,2,3);" 2>/dev/null || true)"
for id in $ACTIVE_IDS; do
  log "retiring previous session $id"
  # Drop the old task/association too. Otherwise a retried boot finds the
  # stale queued task, returns OK TASK, and never joins the fresh session.
  OLD_TASKS="$("${MYSQL[@]}" "SELECT tID FROM multicastSessionsAssoc WHERE msID=$id;" 2>/dev/null || true)"
  if [[ -n "$OLD_TASKS" ]]; then
    log "retiring stale multicast task(s): $(echo "$OLD_TASKS" | tr '\n' ' ')"
    "${MYSQL[@]}" "DELETE FROM multicastSessionsAssoc WHERE msID=$id;"
    for tid in $OLD_TASKS; do
      "${MYSQL[@]}" "DELETE FROM tasks WHERE taskID=$tid AND taskTypeID=8 AND taskStateID IN (1,2);"
    done
  fi
  OLD_PORT="$("${MYSQL[@]}" "SELECT msBasePort FROM multicastSessions WHERE msID=$id;")"
  "${MYSQL[@]}" "UPDATE multicastSessions SET msState=5, msName='', msSenderPID=0, msSenderNode=NULL, msSenderStart=NULL WHERE msID=$id;"
  [[ -n "${OLD_PORT:-}" ]] && pkill -f "udp-sender.*--portbase $OLD_PORT" 2>/dev/null || true
done

# Free the chosen port if a stale sender still holds it.
pkill -f "udp-sender.*--portbase $SENDER_PORT" 2>/dev/null || true

"${MYSQL[@]}" "INSERT INTO multicastSessions
  (msName, msBasePort, msLogPath, msImage, msClients, msSessClients,
   msInterface, msStartDateTime, msState, msPercent, msIsDD, msNFSGroupID,
   msMaxwait, msSenderPID, msShutdown)
  VALUES
  ('$SESSION_NAME', $SENDER_PORT, '$IMAGE_PATH', $IMAGE_ID, 0, $CLIENTS,
   '$IFACE', NOW(), 1, 0, $IMAGE_TYPE, $GROUP_ID, $MAXWAIT, 0, 0);"

# LAST_INSERT_ID is per-connection and each mysql -e above opens a new one,
# so read the row back by its unique name instead.
NEW_ID="$("${MYSQL[@]}" "SELECT msID FROM multicastSessions WHERE msName='$SESSION_NAME' ORDER BY msID DESC LIMIT 1;")"
log "armed session $NEW_ID: '$SESSION_NAME', image '$IMAGE_NAME' (id $IMAGE_ID), $CLIENTS clients, port $SENDER_PORT, max-wait ${MAXWAIT}s"

# The daemon picks queued sessions up on its next tick. Nudge it only if it
# is not running; otherwise it will notice the row itself within 10 seconds.
if ! systemctl is-active --quiet FOGMulticastManager.service; then
  systemctl restart FOGMulticastManager.service
  log "restarted FOGMulticastManager.service"
fi

log "ready — PXE-boot the laptops now (F12 > Network Boot)"
