#!/bin/bash
set -euo pipefail

# Run the appliance-side driver-pack sync as root.  The Python script resolves
# the [Drivers] path from Samba, reads the FOG model inventory, downloads the
# latest vendor packs, prunes them to the INF trees pnputil needs, and writes
# manifest.json on the share.
#
#   sudo mist-sync-driver-packs.sh --plan-only
#   sudo mist-sync-driver-packs.sh
#   sudo mist-sync-driver-packs.sh --mode vendor
#
# Extra arguments are passed through to mist-sync-driver-packs.py.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "${PYTHON}" "${SCRIPT_DIR}/mist-sync-driver-packs.py" "$@"
fi

exec "${PYTHON}" "${SCRIPT_DIR}/mist-sync-driver-packs.py" "$@"
