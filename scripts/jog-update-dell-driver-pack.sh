#!/bin/bash
set -euo pipefail

# Fetch the latest Dell Windows 11 x64 driver pack for the Latitude 3440 into
# the local directory exported by Samba as [Drivers].
#
#   sudo jog-update-dell-driver-pack.sh --check
#   sudo jog-update-dell-driver-pack.sh --download
#
# The Windows first-logon installer extracts the downloaded Dell executable
# locally and installs its INF files. The client does not need internet access.

log() { echo "[jog-update-dell-driver-pack] $*"; }
die() { echo "[jog-update-dell-driver-pack] ERROR: $*" >&2; exit 1; }

MODE="--check"
case "${1:---check}" in
  --check|--download) MODE="$1" ;;
  -h|--help)
    cat <<'EOF'
Fetch the latest Dell Windows 11 x64 driver pack for the Latitude 3440.

Usage:
  jog-update-dell-driver-pack.sh --check
  jog-update-dell-driver-pack.sh --download

The Windows first-logon installer extracts the downloaded Dell executable.
The client does not need internet access.
EOF
    exit 0
    ;;
  *) die "usage: $0 [--check|--download]" ;;
esac
[[ "$#" -le 1 ]] || die "usage: $0 [--check|--download]"

for command_name in curl cabextract python3 sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done

SHARE_NAME="${JOG_DRIVER_SHARE_NAME:-Drivers}"
if [[ -n "${JOG_DRIVER_SHARE_PATH:-}" ]]; then
  SHARE_PATH="$JOG_DRIVER_SHARE_PATH"
elif command -v testparm >/dev/null 2>&1; then
  SHARE_PATH="$(testparm -s --section-name="$SHARE_NAME" --parameter-name=path 2>/dev/null)" ||
    die "could not read the [$SHARE_NAME] path from Samba"
else
  die "set JOG_DRIVER_SHARE_PATH or install Samba's testparm to locate the share"
fi

[[ -d "$SHARE_PATH" ]] || die "Samba share path does not exist: $SHARE_PATH"
[[ -w "$SHARE_PATH" ]] || die "share path is not writable: $SHARE_PATH"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Read the official catalog and select the newest exact Latitude 3440,
# Windows 11 x64 executable pack; emit values in a shell-safe TSV format.
curl --fail --location --silent --show-error --retry 3 \
  https://downloads.dell.com/catalog/DriverPackCatalog.cab \
  --output "$WORK_DIR/DriverPackCatalog.cab"
mkdir "$WORK_DIR/catalog"
cabextract --quiet --directory "$WORK_DIR/catalog" "$WORK_DIR/DriverPackCatalog.cab"
CATALOG_XML="$WORK_DIR/catalog/DriverPackCatalog.xml"
[[ -s "$CATALOG_XML" ]] || die "Dell catalog did not contain DriverPackCatalog.xml"

PACK_INFO="$(python3 - "$CATALOG_XML" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET

catalog = ET.parse(sys.argv[1]).getroot()
matches = []

def elements(parent, name):
    return [
        element
        for element in parent.iter()
        if element.tag.rsplit("}", 1)[-1] == name
    ]

for package in elements(catalog, "DriverPackage"):
    if package.get("format", "").lower() != "exe":
        continue
    if not any(
        os_node.get("osCode") == "Windows11" and os_node.get("osArch") == "x64"
        for os_node in elements(package, "OperatingSystem")
    ):
        continue
    if not any(
        model.get("name", "").strip() == "Latitude 3440"
        for model in elements(package, "Model")
    ):
        continue

    relative_path = package.get("path", "")
    if (
        not relative_path
        or relative_path.startswith("/")
        or any(part in ("", ".", "..") for part in relative_path.split("/"))
        or not re.fullmatch(r"[A-Za-z0-9._/-]+", relative_path)
    ):
        raise SystemExit("Dell catalog contained an unsafe driver-pack path")

    sha256 = next(
        (
            node.text.strip().lower()
            for node in elements(package, "Hash")
            if node.get("algorithm", "").upper() == "SHA256" and node.text
        ),
        "",
    )
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise SystemExit("Dell catalog did not provide a SHA256 for the selected pack")

    matches.append(
        (
            package.get("dateTime", ""),
            tuple(int(part) for part in re.findall(r"\d+", package.get("dellVersion", ""))),
            package.get("dellVersion", ""),
            package.get("releaseID", ""),
            relative_path,
            sha256,
            package.get("size", ""),
        )
    )

if not matches:
    raise SystemExit("Dell's catalog has no Latitude 3440 Windows 11 x64 driver pack")

date, _, version, release_id, relative_path, sha256, size = max(matches)
if not size.isdigit():
    raise SystemExit("Dell catalog provided an invalid driver-pack size")
print("\t".join((date, version, release_id, relative_path, sha256, size)))
PY
)" || die "could not select a Latitude 3440 driver pack from Dell's catalog"

IFS=$'\t' read -r PACK_DATE PACK_VERSION PACK_RELEASE PACK_PATH PACK_SHA256 PACK_SIZE <<< "$PACK_INFO"
PACK_URL="https://downloads.dell.com/$PACK_PATH"
PACK_DIR="$SHARE_PATH/Latitude-3440"
PACK_FILE="$PACK_DIR/DellDriverPack.exe"

log "Latest pack: Latitude 3440, Windows 11 x64, Dell $PACK_VERSION ($PACK_RELEASE)"
log "Catalog date: $PACK_DATE; size: $PACK_SIZE bytes"
log "Source: $PACK_URL"
log "Destination: $PACK_FILE"

if [[ "$MODE" == "--check" ]]; then
  log "check only; use --download to update the Samba share"
  exit 0
fi

mkdir -p "$PACK_DIR"
if [[ -f "$PACK_FILE" ]] && [[ "$(sha256sum "$PACK_FILE" | awk '{print $1}')" == "$PACK_SHA256" ]]; then
  log "the share already contains this exact Dell pack"
  exit 0
fi

# Keep the previous pack usable until the new download passes size and hash checks.
AVAILABLE_KB="$(df -Pk "$PACK_DIR" | awk 'NR == 2 {print $4}')"
REQUIRED_KB=$(( (PACK_SIZE + 1023) / 1024 + 512 * 1024 ))
[[ "$AVAILABLE_KB" =~ ^[0-9]+$ ]] || die "could not determine free space for $PACK_DIR"
(( AVAILABLE_KB >= REQUIRED_KB )) ||
  die "not enough free space: need about $((REQUIRED_KB / 1024)) MiB, have $((AVAILABLE_KB / 1024)) MiB"

PART_FILE="$PACK_DIR/.DellDriverPack.exe.part.$$"
trap 'rm -rf "$WORK_DIR"; rm -f "$PART_FILE"' EXIT
log "downloading Dell's pack; this file is several gigabytes"
curl --fail --location --show-error --retry 3 --connect-timeout 30 \
  --progress-bar "$PACK_URL" --output "$PART_FILE"

ACTUAL_SIZE="$(stat -c '%s' "$PART_FILE")"
[[ "$ACTUAL_SIZE" == "$PACK_SIZE" ]] ||
  die "download size mismatch: expected $PACK_SIZE bytes, got $ACTUAL_SIZE"

ACTUAL_SHA256="$(sha256sum "$PART_FILE" | awk '{print $1}')"
[[ "$ACTUAL_SHA256" == "$PACK_SHA256" ]] ||
  die "download SHA256 mismatch; leaving the existing pack untouched"

chmod 0644 "$PART_FILE"
mv -f "$PART_FILE" "$PACK_FILE"
printf 'Model: Latitude 3440\nOS: Windows 11 x64\nDell version: %s\nRelease ID: %s\nCatalog date: %s\nSHA256: %s\n' \
  "$PACK_VERSION" "$PACK_RELEASE" "$PACK_DATE" "$PACK_SHA256" > "$PACK_DIR/DellDriverPack.txt"
chmod 0644 "$PACK_DIR/DellDriverPack.txt"
log "updated share with the verified Dell driver pack"
