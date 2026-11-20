#!/bin/bash
set -euo pipefail
# Build a Windows golden image in QEMU, then capture it with FOG/JOS over the isolated imaging network.
# See docs/WINDOWS-IMAGE-QEMU.md.
#
#   jog-image-vm.sh check                 verify QEMU, KVM, OVMF and swtpm are present
#   jog-image-vm.sh create [size]         create the VM disk, firmware vars and TPM state (default 64G, thin-provisioned)
#   jog-image-vm.sh install <windows.iso> boot the Windows installer (your ISO and licence)
#   jog-image-vm.sh boot                  boot the installed VM (customise, then run Sysprep /generalize /oobe /shutdown)
#   jog-image-vm.sh pxe                   boot the generalised disk from the imaging network so JOS can capture it
#
# Environment:
#   JOG_VM_DIR      REQUIRED. Where the disk, firmware vars and TPM state live. Needs about 100 GB free.
#   JOG_VM_CPUS     default 4         JOG_VM_MEM  default 8G
#   JOG_VM_BRIDGE   bridge on the imaging network, required for `pxe` (the VM needs layer-2 access to JOG's DHCP/TFTP)
#   JOG_VM_MAC      default 52:54:00:6a:6f:67   fixed NIC MAC so FOG recognises the VM as the same host every run
#   JOG_VM_DISPLAY  default gtk       JOG_VM_DRYRUN=1  print the QEMU command instead of running it
#
# Hardware is deliberately plain: q35, NVMe disk, Intel e1000e NIC, USB tablet. Windows has inbox drivers for all of
# these, so nothing third-party is downloaded or baked into the image. Secure Boot (Microsoft keys) and a TPM 2.0 are
# on, as Windows 11 and the JOS Secure Boot chain expect. No Windows product key is ever written by this script.

die() { echo "jog-image-vm: $*" >&2; exit 1; }

CMD="${1:-}"
CPUS="${JOG_VM_CPUS:-4}"
MEM="${JOG_VM_MEM:-8G}"
DISPLAY_KIND="${JOG_VM_DISPLAY:-gtk}"
MAC="${JOG_VM_MAC:-52:54:00:6a:6f:67}"
OVMF_CODE="${JOG_OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.ms.fd}"
OVMF_VARS_TEMPLATE="${JOG_OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.ms.fd}"

need_dir() {
  [[ -n "${JOG_VM_DIR:-}" ]] || die "set JOG_VM_DIR to a directory on a disk with ~100 GB free (this script will not choose one)."
  VMDIR="$JOG_VM_DIR"
  DISK="${VMDIR}/windows.qcow2"
  VARS="${VMDIR}/OVMF_VARS.fd"
  TPMDIR="${VMDIR}/tpm"
}

check() {
  local ok=0
  chk() { if command -v "$1" >/dev/null 2>&1; then printf '  ok       %s\n' "$1"; else printf '  MISSING  %s  (%s)\n' "$1" "$2"; ok=1; fi; }
  echo "Tools:"
  chk qemu-system-x86_64 "apt install qemu-system-x86"
  chk qemu-img "apt install qemu-utils"
  chk swtpm "apt install swtpm swtpm-tools; Windows 11 needs a TPM"
  echo "Firmware:"
  for f in "$OVMF_CODE" "$OVMF_VARS_TEMPLATE"; do
    if [[ -r "$f" ]]; then echo "  ok       $f"; else echo "  MISSING  $f  (apt install ovmf)"; ok=1; fi
  done
  echo "Acceleration:"
  if [[ -w /dev/kvm ]]; then echo "  ok       /dev/kvm writable"; else echo "  MISSING  /dev/kvm not writable (add your user to the kvm group); the VM would be very slow"; ok=1; fi
  if [[ -n "${JOG_VM_DIR:-}" ]]; then
    local free_gb; free_gb="$(df -BG --output=avail "$JOG_VM_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')"
    echo "Storage:"
    if [[ -n "$free_gb" && "$free_gb" -ge 100 ]]; then echo "  ok       ${free_gb} GB free at $JOG_VM_DIR"; else echo "  LOW      ${free_gb:-unknown} GB free at $JOG_VM_DIR (want 100+)"; ok=1; fi
  else
    echo "Storage:"; echo "  UNSET    JOG_VM_DIR"; ok=1
  fi
  return $ok
}

run_qemu() {
  local mode="$1"; shift
  local -a args=(
    qemu-system-x86_64
    -machine q35,accel=kvm -cpu host -smp "$CPUS" -m "$MEM"
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
    -drive "if=pflash,format=raw,file=${VARS}"
    -chardev "socket,id=chrtpm,path=${TPMDIR}/swtpm-sock"
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0
    -drive "file=${DISK},if=none,id=nvm0,format=qcow2,cache=writeback,discard=unmap"
    -device nvme,serial=jogimg0,drive=nvm0
    -device VGA -device qemu-xhci -device usb-tablet
    -display "$DISPLAY_KIND"
    -name "jog-image-vm"
  )
  case "$mode" in
    install) args+=( -drive "file=${1},media=cdrom,if=none,id=cd0,readonly=on" -device ide-cd,drive=cd0,bootindex=1
                     -netdev user,id=n0 -device "e1000e,netdev=n0,mac=${MAC}" ) ;;
    boot)    args+=( -netdev user,id=n0 -device "e1000e,netdev=n0,mac=${MAC}" ) ;;
    pxe)     [[ -n "${JOG_VM_BRIDGE:-}" ]] || die "set JOG_VM_BRIDGE to the bridge on the imaging network."
             args+=( -netdev "bridge,id=n0,br=${JOG_VM_BRIDGE}" -device "e1000e,netdev=n0,mac=${MAC},bootindex=1" ) ;;
  esac
  if [[ "${JOG_VM_DRYRUN:-0}" == "1" ]]; then printf '%q ' "${args[@]}"; echo; return 0; fi

  command -v swtpm >/dev/null 2>&1 || die "swtpm is missing: apt install swtpm swtpm-tools"
  swtpm socket --tpm2 --tpmstate "dir=${TPMDIR}" --ctrl "type=unixio,path=${TPMDIR}/swtpm-sock" \
    --daemon --pid "file=${TPMDIR}/swtpm.pid"
  trap 'kill "$(cat "${TPMDIR}/swtpm.pid" 2>/dev/null)" 2>/dev/null || true' EXIT
  "${args[@]}"
}

case "$CMD" in
  check) check ;;
  create)
    need_dir
    SIZE="${2:-64G}"
    [[ ! -e "$DISK" ]] || die "$DISK already exists; refusing to overwrite."
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img is missing."
    [[ -r "$OVMF_VARS_TEMPLATE" ]] || die "OVMF vars template not found: $OVMF_VARS_TEMPLATE (apt install ovmf)"
    install -d -m 0750 "$VMDIR" "$TPMDIR"
    qemu-img create -f qcow2 "$DISK" "$SIZE" >/dev/null
    install -m 0640 "$OVMF_VARS_TEMPLATE" "$VARS"
    echo "Created $DISK ($SIZE, thin), $VARS, and $TPMDIR."
    echo "Next: jog-image-vm.sh install /path/to/your-windows.iso" ;;
  install)
    need_dir
    ISO="${2:-}"; [[ -f "$ISO" ]] || die "give the path to your Windows ISO."
    [[ -f "$DISK" ]] || die "run 'create' first."
    echo "ISO SHA-256 (compare with the value on the Microsoft / VLSC download page):"
    sha256sum "$ISO" | awk '{print "  " $1}'
    run_qemu install "$ISO" ;;
  boot) need_dir; [[ -f "$DISK" ]] || die "run 'create' first."; run_qemu boot ;;
  pxe)  need_dir; [[ -f "$DISK" ]] || die "run 'create' first."; run_qemu pxe ;;
  *) sed -n 2,22p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
