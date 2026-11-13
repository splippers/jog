#!/bin/bash
## JOG post-download injection.
##
## Sourced from fog.postdownload inside the FOS/JOS environment. Copies the Windows
## provisioner payload from the NFS-mounted post-download directory onto the freshly
## imaged Windows partition, and installs SetupComplete.cmd so the pipeline starts at
## first boot.
##
## This script must never fail the imaging task. Everything is in a subshell with a
## final `|| true`.

(
  set +e

  base="${postdownpath:-/images/postdownloadscripts/}"
  [[ "$base" == */ ]] || base="${base}/"
  payload="${base}jog-provisioner"

  if [[ ! -d "$payload" ]]; then
    echo "[jog-inject] no payload at $payload (corporate provisioning not installed)"
    exit 0
  fi
  if [[ ! -f "$payload/Start-JOGProvisioning.ps1" ]]; then
    echo "[jog-inject] payload is incomplete: $payload/Start-JOGProvisioning.ps1 missing"
    exit 0
  fi

  disk="${hd:-${disk:-}}"
  if [[ ! -b "$disk" ]]; then
    echo "[jog-inject] target disk unknown ('$disk'); cannot inject"
    exit 0
  fi

  pre=""
  [[ "$disk" =~ [0-9]$ ]] && pre="p"

  # Pick the largest NTFS partition: that is the Windows volume, not WinRE.
  winpart=""
  best=0
  for part in $(ls "${disk}${pre}"[0-9]* 2>/dev/null); do
    fstype="$(blkid -o value -s TYPE "$part" 2>/dev/null)"
    [[ "$fstype" == "ntfs" ]] || continue
    size="$(blockdev --getsize64 "$part" 2>/dev/null || echo 0)"
    if [[ "${size:-0}" -gt "$best" ]]; then
      best="$size"
      winpart="$part"
    fi
  done

  if [[ -z "$winpart" ]]; then
    echo "[jog-inject] no NTFS Windows partition found on $disk; skipping"
    exit 0
  fi

  mnt=/tmp/jog-win
  mkdir -p "$mnt"
  cleanup() { umount "$mnt" 2>/dev/null; }
  trap cleanup EXIT

  if ! mount -t ntfs-3g -o rw "$winpart" "$mnt" 2>/dev/null; then
    if ! mount -t ntfs -o rw "$winpart" "$mnt" 2>/dev/null; then
      echo "[jog-inject] could not mount $winpart read-write (BitLocker or dirty NTFS?); skipping"
      exit 0
    fi
  fi

  if [[ ! -d "$mnt/Windows/System32" ]]; then
    echo "[jog-inject] $winpart does not look like a Windows volume; skipping"
    exit 0
  fi

  mkdir -p "$mnt/ProgramData/JOG/logs" "$mnt/ProgramData/JOG/Secrets" "$mnt/Windows/Setup/Scripts"

  echo "[jog-inject] copying payload to $winpart (C:\\ProgramData\\JOG)"
  cp -a "$payload"/. "$mnt/ProgramData/JOG/" 2>/dev/null || cp -R "$payload"/. "$mnt/ProgramData/JOG/" 2>/dev/null

  # Never leave the example config as the live config.
  rm -f "$mnt/ProgramData/JOG/jog-provisioning.example.json" 2>/dev/null

  sc="$mnt/Windows/Setup/Scripts/SetupComplete.cmd"
  if [[ -f "$sc" ]]; then
    if ! grep -q "Start-JOGProvisioning.ps1" "$sc" 2>/dev/null; then
      printf '\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\\ProgramData\\JOG\\Start-JOGProvisioning.ps1" -Resume\r\n' >> "$sc"
      echo "[jog-inject] appended the provisioner call to the existing SetupComplete.cmd"
    else
      echo "[jog-inject] SetupComplete.cmd already calls the provisioner"
    fi
  else
    if [[ -f "$payload/SetupComplete.cmd" ]]; then
      sed 's/$/\r/' "$payload/SetupComplete.cmd" > "$sc"
      echo "[jog-inject] installed SetupComplete.cmd"
    else
      printf '@echo off\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\\ProgramData\\JOG\\Start-JOGProvisioning.ps1" -Resume\r\n' > "$sc"
      echo "[jog-inject] wrote a minimal SetupComplete.cmd"
    fi
  fi

  sync
  echo "[jog-inject] provisioner injected into C:\\ProgramData\\JOG"
) || true
