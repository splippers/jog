# Storage driver mode detection

Haar records three separate facts and keeps them independent:

1. **BIOS mode of the booting client** — detected by JOS at boot from sysfs PCI
   class, modalias and bound driver. Priority is `VMD` > `RAID` > `AHCI` >
   `IDE` > `NVME`; a VMD/RST machine still exposes AHCI-class devices, so the
   higher mode wins. `jos_storage_mode=<MODE>` on the kernel command line is an
   override for test hardware.
2. **Mode baked into an image** — captured automatically when JOS boots a host
   with a capture task. The detected mode is written to Haar's image ledger and
   keyed by FOG image ID and name. This is the "what drivers does this image
   contain" flag; it is a proxy based on the source machine's BIOS mode, not a
   scan inside the captured disk.
3. **JOS support for the current mode** — checked against the modules actually
   staged in the running initrd (`/lib/modules/$KVER/jos-modules.list`) and
   `/proc/modules` and `modules.builtin`. Required modules are `vmd`, `ahci`,
   `dm_raid`/`dm_mod`/`raid*`, `pata_acpi` and `nvme` respectively.

Everything is **warn and report**. A mismatch, a missing module or an unknown
mode is printed on the JOS console and exposed in the API; imaging is never
blocked.

## Data flow

- `jos/build/jos-storage-mode.sh` runs from `/init` before the FOG userland and
  writes `/tmp/jos-storage-mode.env`.
- `jos-report-boot-facts.sh` adds `storagemode` and `storagesupport` to the
  existing advisory FOG `ipxe/boot.php` call.
- `S96jos-taskcheck` sends `action=storage_report` and `action=storage_check`
  to `service/jog-autojoin.php` after the hostinfo handshake. Capture tasks
  (`type=up`, `upload`, `capture`) flag the image; deploy tasks compare the
  target mode with the flag and JOS support.
- The state file is `/var/lib/jog/storage-modes.json`, created by
  `jog-autojoin-setup.sh --apply`. It needs no FOG database schema change.
- The kiosk/API can read it at `GET /api/storage-mode`. Optional query keys:
  `mac`, `mode`, `image`, `imgid`, `support`. The response includes `images`,
  `hosts` and a computed `checks` array.

## Example

Capture a reference machine in VMD/RST mode, then deploy it to an AHCI-only
host. JOS prints:

```
[JOS] storage mode AHCI detected from: 00:17.0:class=0x010601,driver=ahci
[jos-taskcheck] Storage mode warning: target=AHCI image=VMD jos=ok verdict=warn detail=image drivers captured for a different mode
```

The operator can continue; the warning means the captured Windows image was
prepared with VMD/iaStorVD drivers and may not boot on the AHCI target.

## Apply

Rebuild the JOS initramfs from the pinned FOS userland, then stage it with the
signed kernel/modules pair:

```sh
jos/build/build-from-fos.sh
sudo JOS_INITRD=jos/build/out/initrd.img jos/scripts/jos-stage-boot.sh
```

The detection runs from the initramfs, so staging a new initrd is required for
the feature to become active on imaged clients. The HAAR-side endpoint can be
installed independently with `sudo jog-autojoin-setup.sh --apply`.

## Verify

```sh
sudo /usr/local/sbin/jog-autojoin-setup.sh --check
curl -s 'http://127.0.0.1:8088/api/storage-mode' | python3 -m json.tool
curl -s -X POST --data 'storage_probe=1' \
  http://127.0.0.1/fog/service/jog-autojoin.php
```

To test detection without hardware, rebuild the initrd with
`jos_storage_mode=VMD` in the kernel command line, or source
`jos-storage-mode.sh` inside a VM whose PCI topology you control.
