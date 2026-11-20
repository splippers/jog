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

# JOG_REF: the JOG release tag the installed appliance clones (installer/JOG_REF, or the JOG_REF env var).
# Ship with a release tag such as v1.0.0 so every install is reproducible; a branch name is for development only.
JOG_REF="${JOG_REF:-$(tr -d '[:space:]' <"${HERE}/../JOG_REF")}"
[[ -n "$JOG_REF" && "$JOG_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "Invalid or empty JOG_REF: '${JOG_REF}'" >&2; exit 1; }
if [[ ! "$JOG_REF" =~ ^v[0-9] ]]; then
  echo "WARNING: JOG_REF='${JOG_REF}' is a branch, not a release tag; installs will not be reproducible." >&2
fi

HASH="$(openssl passwd -6 "$PW")"
sed -e "s|@PASSWORD@|${HASH}|g" -e "s|@JOG_REF@|${JOG_REF}|g" "${TEMPLATE}" >"${OUT}"
echo "Wrote ${OUT} (initial jogadmin password: ${PW})"
