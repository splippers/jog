#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSHOP_DIR="${Brume_QEMU_WORKSHOP_DIR:-${JOG_QEMU_WORKSHOP_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}}/mist/qemu-workshop}"
WORKSHOP_BUDGET_GIB="${Brume_QEMU_WORKSHOP_BUDGET_GIB:-${JOG_QEMU_WORKSHOP_BUDGET_GIB:-100}}"
OVMF_DIR="${Brume_QEMU_OVMF_DIR:-${JOG_QEMU_OVMF_DIR:-/usr/share/OVMF}}"
QEMU_RAM_MIB="${Brume_QEMU_RAM_MIB:-${JOG_QEMU_RAM_MIB:-4096}}"
QEMU_CPUS="${Brume_QEMU_CPUS:-${JOG_QEMU_CPUS:-2}}"

usage() {
  cat <<'EOF'
Usage:
  mist-qemu-workshop.sh check
  mist-qemu-workshop.sh create NAME DISK_GIB
  mist-qemu-workshop.sh list
  mist-qemu-workshop.sh run NAME [INSTALLER.iso]
  mist-qemu-workshop.sh test-jos TFTP_ROOT

VMs use OVMF with Microsoft Secure Boot keys and isolated QEMU user-mode
networking. They are not bridged to the imaging or corporate network.

Environment:
  JOG_QEMU_WORKSHOP_DIR          Workspace directory
  JOG_QEMU_WORKSHOP_BUDGET_GIB   Total reserved-storage budget (default: 100)
  JOG_QEMU_OVMF_DIR              OVMF firmware directory
  JOG_QEMU_RAM_MIB               VM memory (default: 4096)
  JOG_QEMU_CPUS                  VM CPU count (default: 2)
  JOG_QEMU_DISPLAY               QEMU display driver (default: gtk; use none for headless)
  JOS_DIR                        JOS checkout, required by test-jos if not a sibling checkout
EOF
}

fail() {
  echo "mist-qemu-workshop: ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$ ]] ||
    fail "invalid VM name '$1' (use 1-48 letters, digits, dot, underscore or dash)"
}

validate_config() {
  [[ "$WORKSHOP_BUDGET_GIB" =~ ^[1-9][0-9]*$ ]] ||
    fail "JOG_QEMU_WORKSHOP_BUDGET_GIB must be a positive integer"
  (( ${#WORKSHOP_BUDGET_GIB} <= 4 && 10#$WORKSHOP_BUDGET_GIB <= 8192 )) ||
    fail "JOG_QEMU_WORKSHOP_BUDGET_GIB must not exceed 8192 GiB"
  [[ "$QEMU_RAM_MIB" =~ ^[1-9][0-9]*$ ]] ||
    fail "JOG_QEMU_RAM_MIB must be a positive integer"
  [[ "$QEMU_CPUS" =~ ^[1-9][0-9]*$ ]] ||
    fail "JOG_QEMU_CPUS must be a positive integer"
}

find_ovmf() {
  local code="${OVMF_DIR}/OVMF_CODE_4M.secboot.fd"
  local vars="${OVMF_DIR}/OVMF_VARS_4M.ms.fd"
  [[ -r "$code" && -r "$vars" ]] || fail \
    "Secure Boot OVMF files not found in $OVMF_DIR (install OVMF or set JOG_QEMU_OVMF_DIR)"
  OVMF_CODE="$code"
  OVMF_VARS="$vars"
}

find_jos() {
  local candidate
  for candidate in "${JOS_DIR:-}" "${ROOT}/../jos" "${ROOT}/jos" /opt/mist/jos /opt/Brume/jos; do
    [[ -n "$candidate" && -x "$candidate/scripts/test-secureboot-vm.sh" ]] || continue
    JOS_DIR="$(cd "$candidate" && pwd)"
    return 0
  done
  fail "JOS checkout not found; set JOS_DIR to a jos checkout"
}

budget_check() {
  local requested_bytes="$1"
  python3 - "$WORKSHOP_DIR" "$WORKSHOP_BUDGET_GIB" "$requested_bytes" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
limit = int(sys.argv[2]) * (1 << 30)
requested = int(sys.argv[3])
reserved = 0

if root.exists():
    for path in root.rglob("*"):
        if path.is_symlink():
            print(f"mist-qemu-workshop: refusing symlink in workspace: {path}", file=sys.stderr)
            sys.exit(2)
        if not path.is_file():
            continue
        if path.suffix.lower() == ".qcow2":
            result = subprocess.run(
                ["qemu-img", "info", "--output=json", str(path)],
                check=False, capture_output=True, text=True,
            )
            if result.returncode:
                print(f"mist-qemu-workshop: cannot inspect {path}: {result.stderr.strip()}",
                      file=sys.stderr)
                sys.exit(2)
            try:
                virtual_size = int(json.loads(result.stdout)["virtual-size"])
            except (ValueError, KeyError, TypeError) as exc:
                print(f"mist-qemu-workshop: invalid qemu-img metadata for {path}: {exc}",
                      file=sys.stderr)
                sys.exit(2)
            # Leave room for qcow2 metadata as its guest data becomes allocated.
            reserved += virtual_size + max(64 * (1 << 20), virtual_size // 100)
        else:
            reserved += path.stat().st_size

if reserved + requested > limit:
    print(
        "mist-qemu-workshop: storage budget exceeded "
        f"({reserved / (1 << 30):.2f} GiB reserved + "
        f"{requested / (1 << 30):.2f} GiB requested > "
        f"{limit / (1 << 30):.2f} GiB budget)",
        file=sys.stderr,
    )
    sys.exit(1)
print(f"{(reserved + requested) / (1 << 30):.2f} GiB / {limit / (1 << 30):.2f} GiB reserved")
PY
}

cmd="${1:-}"
case "$cmd" in
  check)
    validate_config
    require_command qemu-system-x86_64
    require_command qemu-img
    require_command python3
    find_ovmf
    echo "QEMU workshop ready"
    echo "  workspace: $WORKSHOP_DIR"
    echo "  budget:    $WORKSHOP_BUDGET_GIB GiB"
    echo "  OVMF:      $OVMF_CODE"
    ;;
  create)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    validate_config
    validate_name "$2"
    [[ "$3" =~ ^[1-9][0-9]*$ ]] || fail "DISK_GIB must be a positive integer"
    (( ${#3} <= 4 && 10#$3 <= 8192 )) || fail "DISK_GIB must not exceed 8192 GiB"
    (( 10#$3 <= WORKSHOP_BUDGET_GIB )) || fail "disk exceeds the workspace budget"
    require_command qemu-img
    [[ ! -L "$WORKSHOP_DIR" ]] || fail "workspace directory must not be a symlink"
    mkdir -p "$WORKSHOP_DIR/disks"
    disk="$WORKSHOP_DIR/disks/$2.qcow2"
    [[ ! -e "$disk" ]] || fail "VM disk already exists: $disk"
    requested_bytes=$((10#$3 * 1024 * 1024 * 1024))
    requested_bytes=$((requested_bytes + requested_bytes / 100))
    (( requested_bytes >= 64 * 1024 * 1024 )) || requested_bytes=$((64 * 1024 * 1024))
    budget_check "$requested_bytes"
    umask 077
    qemu-img create -f qcow2 -o preallocation=off "$disk" "${3}G"
    echo "Created $disk (${3} GiB virtual capacity)"
    ;;
  list)
    if [[ ! -d "$WORKSHOP_DIR/disks" ]]; then
      echo "No workshop disks in $WORKSHOP_DIR"
      exit 0
    fi
    require_command qemu-img
    for disk in "$WORKSHOP_DIR"/disks/*.qcow2; do
      [[ -e "$disk" ]] || continue
      info="$(qemu-img info --output=json "$disk")"
      python3 -c 'import json,sys; d=json.load(sys.stdin); size=d["virtual-size"]; print(f"{size / (1 << 30):.1f} GiB\t{sys.argv[1]}")' \
        "$(basename "$disk" .qcow2)" <<<"$info"
    done
    ;;
  run)
    [[ $# -eq 2 || $# -eq 3 ]] || { usage >&2; exit 2; }
    validate_config
    validate_name "$2"
    require_command qemu-system-x86_64
    find_ovmf
    [[ ! -L "$WORKSHOP_DIR" ]] || fail "workspace directory must not be a symlink"
    disk="$WORKSHOP_DIR/disks/$2.qcow2"
    [[ -f "$disk" && ! -L "$disk" ]] || fail "VM disk not found: $disk"
    budget_check 0
    mkdir -p "$WORKSHOP_DIR/vars"
    vars="$WORKSHOP_DIR/vars/$2.fd"
    if [[ ! -e "$vars" ]]; then
      budget_check $((4 * 1024 * 1024))
      install -m 0600 "$OVMF_VARS" "$vars"
    fi
    [[ -f "$vars" && ! -L "$vars" ]] || fail "invalid UEFI variable store: $vars"
    qemu_args=(
      -machine q35,smm=on
      -m "$QEMU_RAM_MIB"
      -smp "$QEMU_CPUS"
      -global driver=cfi.pflash01,property=secure,value=on
      -drive "if=pflash,format=raw,unit=0,file=$OVMF_CODE,readonly=on"
      -drive "if=pflash,format=raw,unit=1,file=$vars"
      -drive "if=virtio,format=qcow2,file=$disk"
      -netdev user,id=net0,restrict=on
      -device virtio-net-pci,netdev=net0
    )
    if [[ -w /dev/kvm ]]; then
      qemu_args+=(-accel kvm -cpu host)
    else
      qemu_args+=(-accel tcg)
    fi
    if [[ $# -eq 3 ]]; then
      [[ -f "$3" ]] || fail "installer ISO not found: $3"
      qemu_args+=(-cdrom "$3" -boot order=d,menu=on)
    else
      qemu_args+=(-boot order=c,menu=on)
    fi
    display="${Brume_QEMU_DISPLAY:-${JOG_QEMU_DISPLAY:-gtk}}"
    if [[ "$display" == "none" ]]; then
      qemu_args+=(-display none -serial mon:stdio)
    else
      qemu_args+=(-display "$display" -monitor stdio -serial null)
    fi
    exec qemu-system-x86_64 "${qemu_args[@]}"
    ;;
  test-jos)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    find_jos
    exec "$JOS_DIR/scripts/test-secureboot-vm.sh" "$2"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
