#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/haar-qemu-workshop.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/ovmf"
cat >"$TMP/bin/qemu-img" <<'MOCK'
#!/bin/bash
set -euo pipefail
case "$1" in
  create)
    printf '%s\n' "${@: -1}" >"${@: -2:1}"
    ;;
  info)
    path="${@: -1}"
    size="$(<"$path")"
    gib="${size%G}"
    printf '{"virtual-size": %s}\n' "$((gib * 1024 * 1024 * 1024))"
    ;;
  *)
    exit 2
    ;;
esac
MOCK
chmod 0755 "$TMP/bin/qemu-img"
cat >"$TMP/bin/qemu-system-x86_64" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" >"$JOG_QEMU_TEST_ARGS"
MOCK
chmod 0755 "$TMP/bin/qemu-system-x86_64"
touch "$TMP/ovmf/OVMF_CODE_4M.secboot.fd" "$TMP/ovmf/OVMF_VARS_4M.ms.fd"
export PATH="$TMP/bin:$PATH"
export JOG_QEMU_WORKSHOP_DIR="$TMP/workspace"
export JOG_QEMU_WORKSHOP_BUDGET_GIB=6
export JOG_QEMU_OVMF_DIR="$TMP/ovmf"
export JOG_QEMU_DISPLAY=none
export JOG_QEMU_TEST_ARGS="$TMP/qemu-args"

"$ROOT/scripts/haar-qemu-workshop.sh" check >/dev/null
"$ROOT/scripts/haar-qemu-workshop.sh" create first 5 >/dev/null
"$ROOT/scripts/haar-qemu-workshop.sh" list | grep -q '5.0 GiB[[:space:]]first'
"$ROOT/scripts/haar-qemu-workshop.sh" run first
grep -q 'value=on' "$JOG_QEMU_TEST_ARGS"
grep -q 'id=net0,restrict=on' "$JOG_QEMU_TEST_ARGS"
! grep -q 'tap' "$JOG_QEMU_TEST_ARGS"
[[ "$(stat -c '%a' "$JOG_QEMU_WORKSHOP_DIR/vars/first.fd")" == 600 ]]

if "$ROOT/scripts/haar-qemu-workshop.sh" create second 1 >"$TMP/out" 2>&1; then
  echo "expected the workspace budget to reject the second disk" >&2
  exit 1
fi
grep -q 'storage budget exceeded' "$TMP/out"
[[ ! -e "$JOG_QEMU_WORKSHOP_DIR/disks/second.qcow2" ]]

if "$ROOT/scripts/haar-qemu-workshop.sh" create ../escape 1 >"$TMP/out" 2>&1; then
  echo "expected invalid VM name to be rejected" >&2
  exit 1
fi
grep -q 'invalid VM name' "$TMP/out"

echo "QEMU workshop tests passed"
