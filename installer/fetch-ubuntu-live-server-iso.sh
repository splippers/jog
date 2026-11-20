#!/bin/bash
set -euo pipefail
# Download the official Ubuntu Server live ISO (amd64) used with JOG autoinstall, straight from Canonical.
# Pin: see installer/UBUNTU_RELEASE
#
# Trust chain (fails closed; nothing is installed or kept unless every step passes):
#   1. SHA256SUMS and SHA256SUMS.gpg are fetched from releases.ubuntu.com
#   2. The signature must be valid and made by the pinned Ubuntu CD signing key (fingerprint below)
#   3. The ISO's SHA-256 must match the signed SHA256SUMS
#
# Usage: fetch-ubuntu-live-server-iso.sh [output-path] [--verify-only]
#   --verify-only   Check an existing ISO against the signed checksums; never download or delete.
# Escape hatch for offline lab use only: JOG_ALLOW_UNVERIFIED=1 skips the signature and checksum checks.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REL="$(tr -d '[:space:]' <"${HERE}/UBUNTU_RELEASE")"

VERIFY_ONLY=0
OUT=""
for arg in "$@"; do
  case "$arg" in
    --verify-only) VERIFY_ONLY=1 ;;
    *) OUT="$arg" ;;
  esac
done
OUT="${OUT:-${HERE}/ubuntu-${REL}-live-server-amd64.iso}"

# Ubuntu CD Image Automatic Signing Key (2012). Primary key fingerprint, pinned.
UBUNTU_SIGNING_FPR="843938DF228D22F7B3742BC0D94AA3F0EFE21092"
KEYSERVER="${JOG_KEYSERVER:-hkps://keyserver.ubuntu.com}"

ISO_NAME="ubuntu-${REL}-live-server-amd64.iso"
BASE="https://releases.ubuntu.com/${REL}"
URL="${BASE}/${ISO_NAME}"

die() { echo "ERROR: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Fetch SHA256SUMS + signature, verify the signature against the pinned key, print the ISO's expected hash.
signed_checksum() {
  command -v gpg >/dev/null 2>&1 || die "gpg is required to verify the Ubuntu signature (apt install gnupg)."
  local gh="${WORK}/gnupg"
  install -d -m 0700 "$gh"
  curl -fsSL --retry 3 -o "${WORK}/SHA256SUMS" "${BASE}/SHA256SUMS" || die "cannot fetch ${BASE}/SHA256SUMS"
  curl -fsSL --retry 3 -o "${WORK}/SHA256SUMS.gpg" "${BASE}/SHA256SUMS.gpg" || die "cannot fetch ${BASE}/SHA256SUMS.gpg"
  gpg --homedir "$gh" --batch --quiet --keyserver "$KEYSERVER" --recv-keys "$UBUNTU_SIGNING_FPR" 2>/dev/null \
    || die "cannot fetch Ubuntu signing key ${UBUNTU_SIGNING_FPR} from ${KEYSERVER}"
  local status
  status="$(gpg --homedir "$gh" --batch --status-fd 1 --verify "${WORK}/SHA256SUMS.gpg" "${WORK}/SHA256SUMS" 2>/dev/null || true)"
  # VALIDSIG <fpr> ... <primary-key-fpr>: require a valid signature whose primary key is the pinned one.
  echo "$status" | grep -qE "^\[GNUPG:\] VALIDSIG .* ${UBUNTU_SIGNING_FPR}\$" \
    || die "SHA256SUMS signature is not valid for the pinned Ubuntu signing key. Refusing to continue."
  local want
  want="$(awk -v n="*${ISO_NAME}" '$2==n{print $1}' "${WORK}/SHA256SUMS" | head -n1)"
  [[ -n "$want" ]] || die "${ISO_NAME} not listed in the signed SHA256SUMS."
  echo "$want"
}

verify_file() {
  local file="$1" want="$2" got
  [[ -f "$file" ]] || return 1
  got="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$got" == "$want" ]]
}

echo "Ubuntu ${REL} ISO: $OUT"

if [[ "${JOG_ALLOW_UNVERIFIED:-0}" == "1" ]]; then
  echo "WARNING: JOG_ALLOW_UNVERIFIED=1, skipping signature and checksum verification." >&2
  [[ "$VERIFY_ONLY" == "0" ]] || die "--verify-only cannot be combined with JOG_ALLOW_UNVERIFIED=1."
  [[ -f "$OUT" ]] || curl -fL --retry 3 --retry-delay 2 -o "$OUT" "$URL"
  echo "Saved (UNVERIFIED): $OUT"
  exit 0
fi

WANT="$(signed_checksum)"
echo "Signature OK (key ${UBUNTU_SIGNING_FPR}); expected SHA-256 ${WANT}"

if [[ -f "$OUT" ]]; then
  if verify_file "$OUT" "$WANT"; then
    echo "OK: ISO present and verified against the signed checksum."
    exit 0
  fi
  [[ "$VERIFY_ONLY" == "0" ]] || die "ISO checksum mismatch (got $(sha256sum "$OUT" | awk '{print $1}'))."
  echo "WARN: Existing ISO did not verify; re-downloading."
  rm -f "$OUT"
elif [[ "$VERIFY_ONLY" == "1" ]]; then
  die "no ISO at $OUT to verify."
fi

echo "Downloading ${URL}"
rm -f "${OUT}.partial"
curl -fL --retry 3 --retry-delay 2 -o "${OUT}.partial" "$URL" || { rm -f "${OUT}.partial"; die "download failed."; }

if ! verify_file "${OUT}.partial" "$WANT"; then
  got="$(sha256sum "${OUT}.partial" | awk '{print $1}')"
  rm -f "${OUT}.partial"
  die "downloaded ISO checksum mismatch. Expected ${WANT}, got ${got}. File removed."
fi
mv -f "${OUT}.partial" "$OUT"
echo "Saved and verified: $OUT"
