#!/bin/bash
set -euo pipefail
# Download the official Ubuntu **26.04** Server live ISO (amd64) used with JOG autoinstall.
# Pin: see installer/UBUNTU_RELEASE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REL="$(tr -d '[:space:]' <"${HERE}/UBUNTU_RELEASE")"
OUT="${1:-${HERE}/ubuntu-${REL}-live-server-amd64.iso}"

# GA naming (verified for 26.04): ubuntu-26.04-live-server-amd64.iso
URL="https://releases.ubuntu.com/${REL}/ubuntu-${REL}-live-server-amd64.iso"
SUMS_URL="https://releases.ubuntu.com/${REL}/SHA256SUMS"

want_checksum() {
  curl -fsSL "$SUMS_URL" | awk "/\\*ubuntu-${REL}-live-server-amd64\\.iso$/{print \$1}" | head -n1
}

verify_checksum() {
  local file="$1"
  local want="$2"
  [[ -n "$want" ]] || return 2
  [[ -f "$file" ]] || return 1
  local got
  got="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$got" == "$want" ]]
}

echo "Ubuntu ${REL} ISO: $OUT"
WANT="$(want_checksum || true)"
if [[ -z "$WANT" ]]; then
  echo "WARN: Unable to fetch SHA256SUMS from ${SUMS_URL}"
fi

if [[ -f "$OUT" ]]; then
  if verify_checksum "$OUT" "$WANT"; then
    echo "OK: ISO already downloaded and SHA256 verified."
    exit 0
  fi
  echo "WARN: Existing ISO present but checksum did not verify; re-downloading."
  rm -f "$OUT"
fi

echo "Downloading ${URL}"
rm -f "${OUT}.partial"
if ! curl -fL --retry 3 --retry-delay 2 -o "${OUT}.partial" "$URL"; then
  rm -f "${OUT}.partial"
  exit 1
fi
mv -f "${OUT}.partial" "$OUT"

if [[ -n "$WANT" ]] && ! verify_checksum "$OUT" "$WANT"; then
  echo "ERROR: Downloaded ISO checksum mismatch."
  echo "Expected: $WANT"
  echo "Got:      $(sha256sum "$OUT" | awk '{print $1}')"
  exit 1
fi

echo "Saved: $OUT"
