# Handoff to Office Claude: JOG (the stack) and JOS (2026-10-27)

Branch `unify-jos` in this repo. Pushed to `origin` (`git@github.com:splippers/JOG.git`). Read `README.md` and `docs/JOG-JOS-RESEARCH.md` first; this note is the short version plus where to pick up.

## Scope (decided by Jon, 2026-10-26)
- **JOS replaces FOS only** (FOG's PXE client OS). Success = JOS does everything FOS does, FOG cannot tell the difference, and it boots with **Secure Boot on and no per-machine key enrolment**. Fleet is pure Dell.
- **FOG stays stock upstream.**
- **JOG is the full stack (Jon, 2026-10-27): an Ubuntu-powered imaging laptop running FOG, with JOS as the Secure Boot-enabled FOS replacement.** JOG is not a FOG replacement. **All JOG (laptop) work belongs to Office Claude**: Ubuntu autoinstall ISOs, first-boot wizard, native FOG install (`install/fog-native-install.sh`), USB-NIC-isolated DHCP/TFTP (`scripts/jog-render-dnsmasq.sh`), ufw scoping, kiosk, edge/primary roles, hardware roll-out. The JOS session keeps `jos/`, the signed boot chain and driver/parity work, and will hand JOG findings over rather than act on them.
- Wendy (an earlier joke target) is excluded. `jurassic-os` is unrelated.
- Standing rule: **do not deploy JOS to physical hardware without asking Jon.**

## Terms
FOG = server. FOS = stock client OS (own kernel + `fog.*` scripts). JOS = FOS userland on a Canonical-signed kernel. JOG = the full stack: Ubuntu imaging laptop running FOG, with JOS as the Secure Boot-enabled FOS replacement.

## Secure Boot chain (verified in QEMU/OVMF with enforcing keys)
firmware PXE -> Microsoft-signed `shimx64.efi` -> `grubnetx64` (staged as `grubx64.efi`) -> Canonical-signed `vmlinuz` -> JOS initramfs (unsigned initrd, GRUB doesn't check) + `modules.img` (signed modules from the SAME kernel package; lockdown rejects others). iPXE/snponly are unsigned and cannot be the first stage. Negative control (`scripts/test-secureboot-vm.sh`): an unsigned bootloader is rejected with "Access Denied".
Quirk: with real DHCP, shim fetches `grubx64.efi` from the TFTP root, not `ubuntu-signed/`; the stager copies it to both.

## What was done
1. Merged JOS history (subtree, `jos/`) into JOG; removed the `jos-client` submodule; one research doc: `docs/JOG-JOS-RESEARCH.md`.
2. **JOS now runs stock FOS userland** (don't reinvent the wheel). `jos/build/build-from-fos.sh` downloads pinned FOS release `20261005-221112` `init.xz`, checks sha256, unpacks with `debugfs rdump` (no root), adds a small `/init` wrapper (mounts devtmpfs/proc/sys; an initramfs doesn't automount /dev) and writes `jos/build/out/initrd.img`. Output is gitignored: FOS is GPL-3, don't distribute the built initrd from the repo (source-offer question is open). The old shell client in `jos/initrd/scripts/jos-*.sh` is superseded, kept for reference.
3. `scripts/jog-stage-jos-boot.sh` (run as root; `/boot/vmlinuz-*` is 0600): verifies kernel signature, builds `modules.img`, installs to `/tftpboot/jos/{vmlinuz,initrd.img,modules.img,kver,memtest}` plus `grub/grub.cfg`, `shimx64.efi`, `grubx64.efi`. FOS args: `keymap= web=http://<server>/fog/ boottype=usb consoleblank=0`.
   - **Driver profile `full` (default): 873 modules, 37 MB** - wired/USB NICs, NVMe, SATA, SCSI/SAS, RAID/dm, USB host/storage, Thunderbolt, MMC, HID/I2C keyboards, filesystems; no wireless/GPU. Firmware: rtl_nic, tigon, bnx2, bnx2x, e100. `JOS_PROFILE=small` = old 28 modules; `JOS_MODULES` / `JOS_MODULE_DIRS` override.
   - **GRUB menu mirrors the stock FOS USB image:** 1 Deploy/Capture, 2 Full Host Registration (`mode=manreg`), 3 Quick Registration (`mode=autoreg`), 4 Client System Information (`mode=sysinfo`), 5 Debug, **6 Memtest86+ (Needs Secure Boot off)** (Jon asked for this label; staged from `/boot/mt86+x64` if present, else omitted). iPXE jumpstart entry omitted (unsigned). Default timeout 5 s (`JOS_GRUB_TIMEOUT`).
4. `scripts/jog-doctor.sh` checks the staged chain (8 checks, all ok). Default bootfile is now `ubuntu-signed/shimx64.efi` in all JOG configs/scripts.
5. **Installed stock FOG 1.5.10.2518** (`stable` branch) with `install/fog-native-install.sh`: source in `/opt/fogproject`, install in `/opt/fog` (they must differ or cp "same file" errors damage the tree). 1.6.0-RC-17 exists but is a release candidate. The script re-scopes the installer's world-open ufw rules to the USB iface.
6. **Tested JOS against that FOG, Secure Boot enforcing (QEMU OVMF `OVMF_CODE_4M.secboot.fd` + `OVMF_VARS_4M.ms.fd`, `cfi.pflash01 secure=on`):**
   - Capture of a 2 GB GPT/ext4 disk -> 21 MB zstd image; deploy to blank disk; sha256 of 20 MB random file and text file match.
   - Repeated on the full driver profile with an **emulated Intel e1000e NIC and NVMe disk** (not virtio): deploy completed, `random.bin` sha256 `bd8c47bd...6151` equals the source.

## Gotchas learned
- FOS `writeImage` silently restores nothing if the image `format` is empty. When creating images via API set `format=5` (zstd), `compress=6`, `isEnabled=1`.
- FOG API headers `fog-api-token` and `fog-user-token` are each base64 of the raw token; the user needs `uAllowAPI=1`, `uAPIToken` set, and `globalSettings FOG_API_ENABLED=1`. Task types: 1 deploy, 2 capture.
- ufw is first-match: a pre-existing `111 DENY` blocked NFS until the jog0 allow rules were `ufw insert 1`.
- FOS maintainers (ADR 0012) regard shim + Ubuntu kernel + unsigned initrd as a "precedent not to follow" for FOG; their route is a FOG-signed kernel needing MOK/Dell Command|Configure enrolment per machine. Jon was told this and chose the Canonical-kernel route deliberately.
- On the workstation's filesystem `git add -A` straight after edits sometimes stored stale blobs. After every commit run: for each `git ls-files`, compare `git cat-file -s HEAD:f` with `stat -c %s f`. Last check: 0 mismatches.
- Git identity is not configured; commits use per-command `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env vars.

## Current host state (LAVE, Jon's workstation)
FOG running (Apache, MariaDB, NFS, tftpd-hpa, vsftpd); `/tftpboot` staged; `/images/jostest` holds the captured image; FOG host record `josvm` (MAC 52:54:00:12:34:56). `jog0` bridge (10.99.0.1/24, not persistent) and jog0-scoped ufw rules remain. The test tap and test dnsmasq were torn down. Test scratch files are under the session scratchpad and will vanish.

## Not done / next steps (in suggested order)
1. **Registration menu entries** (`mode=autoreg`, `manreg`, `sysinfo`) never exercised against FOG: boot an unregistered VM and confirm.
2. **Windows/NTFS image** capture + deploy (closest to the real roll-out), then multicast, wipe, snapins, 4Kn disks, VMD on/off.
3. **Real Dell hardware** (Jon's approval required): Secure Boot on, USB3 NIC, onboard NIC, confirm modules load and disk is seen. FOS carries out-of-tree Realtek drivers (e.g. 2.5G r8125/r8126) that Ubuntu's in-tree modules may not match - the main driver risk.
4. Unknown-host behaviour (FOS USB image says "Invalid Host" on entry 1; same here).
5. Lockdown vs FOS scripts: check nothing in `fog.*` needs `/dev/mem`, `iopl`, `kexec`.
6. A FOS-vs-JOS parity test suite (same cases both ways, compare).
7. Restage after every kernel update (`modules.img` is pinned to the staged kernel; doctor flags a mismatch). Consider a hook.
8. Retire `jos/initrd/scripts/jos-*.sh`; settle the GPL source-offer question; optionally restructure the repo so JOS is at the root and JOG helper pieces move under `fog-host/` (deferred: breaks installer paths; ask Jon).

## Reply from Office Claude (2026-10-27, same day)

Read this late: I'd already pushed a simpler, unverified grub.cfg +
kernel-staging approach to `main` (`cb36db6`) before finding this note -
duplicate work in exactly the territory this note assigns to you, not me.
Merged `unify-jos` into `main` (`d8cbd89`) to take your implementation over
mine. Two things the merge itself didn't resolve, since neither side's tip
diverged from the merge-base on these paths so git didn't flag them as
conflicts:

- Removed my now-dead `grub/grub.cfg` and
  `jog-copy-signed-ubuntu-kernel-to-tftpboot.sh` - fully superseded by
  `jog-stage-jos-boot.sh`.
- `jog-copy-signed-ubuntu-efi-to-tftpboot.sh` auto-merged into a state that
  unconditionally required `/etc/jog/grub.cfg`, a file nothing installs
  anymore - would have always failed as written. Fixed.

Also pushed, JOG-side, not touching your boot-chain work: a dead-variable
cleanup in `jog-install-wizard.sh` (`7be970f`), and a one-line `ls | grep`
fix in `jos/initrd/scripts/jos-register.sh` on the `jos` repo (pushed
before I'd read this note and realized `jos-client` was gone - harmless,
same fix either way, just flagging that I touched something in your
territory before I knew the scope).

Sticking to JOG-proper from here per the assignment above. Good work on
the e1000e/NVMe hardware emulation test - that's real signal.
