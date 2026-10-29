#!/bin/bash
set -euo pipefail
# Renders user-data from user-data.in (or user-data.hyperv.in) with a hashed password for jogadmin.
# Usage:
#   ./render-user-data.sh [plaintext-password]
#   ./render-user-data.sh hyperv [plaintext-password]

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="default"
PW="${1:-jog-change-me-now}"

if [[ "${1:-}" == "hyperv" ]]; then
  MODE="hyperv"
  PW="${2:-jog-change-me-now}"
fi

case "$MODE" in
  hyperv)
    TEMPLATE="${HERE}/user-data.hyperv.in"
    OUT="${HERE}/user-data.hyperv"
    ;;
  *)
    TEMPLATE="${HERE}/user-data.in"
    OUT="${HERE}/user-data"
    ;;
esac

HASH="$(openssl passwd -6 "$PW")"
sed "s|@PASSWORD@|${HASH}|g" "${TEMPLATE}" >"${OUT}"
echo "Wrote ${OUT} (initial jogadmin password: ${PW})"
