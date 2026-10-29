#!/bin/bash
set -euo pipefail
# Builds a tiny "cidata" ISO holding meta-data + user-data for Ubuntu 26.04 autoinstall.
# Attach as a second virtual CD, or use Ventoy + this ISO alongside the live-server ISO.
# See docs/ISO-BUILD.md

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${HERE}/jog-autoinstall-seed.iso}"
AIN="${HERE}/autoinstall"

if [[ ! -f "${AIN}/user-data" ]]; then
  echo "Run first: (cd ${AIN} && ./render-user-data.sh ...)" >&2
  exit 1
fi

rm -f "$OUT"

# Prefer Canonical's helper when present (Ubuntu autoinstall quick start).
if command -v cloud-localds >/dev/null 2>&1; then
  cloud-localds "$OUT" "${AIN}/user-data" "${AIN}/meta-data"
else
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  install -m 0644 "${AIN}/meta-data" "${STAGE}/meta-data"
  install -m 0644 "${AIN}/user-data" "${STAGE}/user-data"
  if command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -o "$OUT" -V CIDATA -r -J "$STAGE"
  elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -o "$OUT" -V CIDATA -r -J "$STAGE"
  else
    echo "Install cloud-image-utils (cloud-localds) or xorriso." >&2
    exit 1
  fi
fi

echo "Wrote $OUT"
