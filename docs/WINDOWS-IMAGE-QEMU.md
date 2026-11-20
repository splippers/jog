# Building a Windows golden image in QEMU

Build and customise Windows 11 in a QEMU virtual machine, generalise it with Sysprep, then capture it with
FOG and JOS over the isolated imaging network. `scripts/jog-image-vm.sh` does the VM side.

## Licensing (read first)

- You supply the Windows ISO and the licences. JOG never downloads Windows, and the script never writes a product
  key. Use your organisation's volume-licensed media. Activation happens **after deployment** through KMS or MAK
  (see `docs/CORPORATE-PROVISIONING.md`). Do not bake a MAK or retail key into the image.
- Microsoft's evaluation ISOs are time-limited and for testing the pipeline only.
- Never share the captured image outside your licence terms.
- QEMU, OVMF and swtpm are separate open-source programs installed from your distro. Nothing here redistributes them.

## Why the VM uses plain hardware

The VM uses a q35 machine, an **NVMe** disk and an **Intel e1000e** NIC, all of which have Windows inbox drivers.
No VirtIO drivers are downloaded, so there is nothing third-party to verify or later remove from the image.
Real hardware gets its storage, network and chipset drivers from the JOG driver share during post-download injection.
Secure Boot (Microsoft keys) and a TPM 2.0 (swtpm) are on, as Windows 11 expects and as the JOS boot chain requires.

## One-time setup

```bash
sudo apt install qemu-system-x86 qemu-utils ovmf swtpm swtpm-tools
sudo usermod -aG kvm "$USER"        # log out and in again
export JOG_VM_DIR=/path/with/100GB/free     # not chosen for you, so the root disk cannot fill by accident
scripts/jog-image-vm.sh check
```

## Workflow

1. **Create** the thin-provisioned disk: `scripts/jog-image-vm.sh create 64G`. Keep it smaller than your smallest
   target disk. FOG's resizable image type expands it on deployment.
2. **Install** Windows: `scripts/jog-image-vm.sh install /path/to/windows11.iso`. The script prints the ISO's
   SHA-256 so you can compare it with Microsoft's published value.
3. **Customise** with `scripts/jog-image-vm.sh boot`: updates, applications, policies. Keep it hardware-neutral.
   Leave **BitLocker off**: JOG enables and escrows it after deployment (`docs/BITLOCKER-AD.md`).
4. **Generalise**: inside the VM run
   `C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown`.
   Do **not** use `/mode:vm`: that is for redeploying onto the same hypervisor and is wrong for physical laptops.
5. **Capture**: attach the VM to the imaging network and boot it from PXE:
   `JOG_VM_BRIDGE=<bridge> scripts/jog-image-vm.sh pxe`. JOS boots under Secure Boot; in FOG register the VM
   (its MAC is fixed, default `52:54:00:6a:6f:67`, override with `JOG_VM_MAC`), assign an image, and schedule a
   **Capture** task. Use the single-disk **resizable** image type (partclone).
6. **Do not boot the VM disk again** after Sysprep, or it will start OOBE and no longer be a clean master. Keep a
   copy of the qcow2 from before step 4 (`cp --reflink=auto`) if you want to update the image later.

## Network note

PXE needs layer-2 access to JOG's DHCP/TFTP, so the VM must sit on the imaging network through a bridge, not
QEMU's default user-mode networking. Create the bridge on the machine running QEMU and allow it in
`/etc/qemu/bridge.conf` (`allow <bridge>`). If JOG's imaging NIC is a USB Ethernet adapter on the same machine, bridge
that adapter. Do not bridge onto your corporate LAN: JOG's design keeps DHCP/PXE off it.

## Single-machine test rig (Dell Latitude 3410: 8 GB RAM, 120 GB SSD boot, 256 GB NVMe)

Everything (JOG, FOG, the VM and the captured image) runs on one machine. What that means:

- **Put the VM on the NVMe.** Mount it and set `JOG_VM_DIR` there. Keep FOG's image store (`/images`) on the NVMe too:
  a capture writes a compressed image of 15 to 25 GB, which will not fit comfortably on the 120 GB boot SSD.
- **Memory.** The default VM is 4 GB (Windows 11's minimum), leaving about 4 GB for Ubuntu, FOG, Apache and MariaDB.
  Expect it to be tight. Do not raise `JOG_VM_MEM` on this host.
- **Virtualisation must be on in the BIOS** (Intel VT-x). `scripts/jog-image-vm.sh check` reports `/dev/kvm` status.
- **The VM needs a bridge, and the bridge must carry JOG's address.** JOG's dnsmasq serves one named interface
  (`JOG_USB_IFACE`, using `bind-dynamic`). To let the VM and the host share the imaging network, make the USB NIC a
  port of a bridge and move the imaging IP onto the bridge. Untested sketch, to adapt to your netplan:

  ```yaml
  network:
    version: 2
    ethernets:
      enx00e04c680001: {dhcp4: false}        # your USB NIC; no address of its own
    bridges:
      br-img:
        interfaces: [enx00e04c680001]
        addresses: [10.99.0.1/24]            # JOG_IMAGING_IP
        parameters: {stp: false, forward-delay: 0}
  ```

  Then: set `JOG_USB_IFACE=br-img` in `/etc/jog/jog.env`, re-render dnsmasq (`scripts/jog-render-dnsmasq.sh`) and restart
  it, add `allow br-img` to `/etc/qemu/bridge.conf`, and review `nftables/` (a rule there names the physical NIC
  explicitly). `jog-imaging-nic-guard` follows `JOG_USB_IFACE`, so it should follow the bridge; confirm after a reboot.
  Do not run `netplan apply` over an SSH session on the same NIC; apply it from the console.
- Run `scripts/jog-image-vm.sh pxe` with `JOG_VM_BRIDGE=br-img`.
- **Unplugged cable:** with no cable on the USB NIC the bridge has no carrier. If the VM cannot get a lease, check
  `ip link show br-img` and that the NIC is up before debugging anything else.

## Status

- Script logic and the QEMU hardware configuration were smoke-tested here (disk and firmware creation, refusal to
  overwrite, command generation, QEMU accepting the device set).
- **Not yet tested:** an actual Windows 11 install, Sysprep, and a FOG/JOS capture of the VM. `swtpm` was not
  installed on the build machine, so the TPM path is untested.
- **Open question:** the VM's disk image should be compared against a capture from real hardware to confirm that
  deploys boot on your Dell fleet with Secure Boot on (the open item in `docs/JOG-JOS-RESEARCH.md`).
