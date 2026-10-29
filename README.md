# JOG — Jonathan's Opensource Ghost

A portable imaging appliance: an Ubuntu laptop running stock [FOG](https://fogproject.org) on an isolated imaging network (USB Ethernet), with a kiosk UI and a guided installer. JOG is **not** a FOG fork.

JOG is the **server side**. The machines being imaged boot **[JOS](https://github.com/splippers/jos)**, a Secure Boot-compatible replacement for FOG's FOS, which JOG serves over PXE.

## The three repos

| Repo | Role | Runs on |
|---|---|---|
| **jog** (this repo) | The imaging laptop: Ubuntu autoinstall, FOG install, DHCP/TFTP/nftables, kiosk, wizard, status/doctor scripts | the laptop (server) |
| [jos](https://github.com/splippers/jos) | The client runtime: initrd build, GRUB menu generator, local-boot fallback, Secure Boot chain staging | the machine being imaged (client); staged by the server |
| [jog-jos](https://github.com/splippers/jog-jos) | Integration: pins `jog` and `jos` together at known-good commits, combined docs, end-to-end tests | n/a |

**Rule of thumb:** if it configures or installs something on the laptop, it belongs here. If it runs on, or builds for, the imaged machine, it belongs in `jos`.

## How they connect

```
 imaged machine                          JOG laptop
 --------------                          ----------
 UEFI PXE ──DHCP/TFTP──────────────────▶ dnsmasq (jog)     serves shimx64.efi
 shim → grubnetx64 → signed kernel ◀──── /tftpboot/{grub,jos}/   staged by jos/scripts/jos-stage-boot.sh
 JOS (FOS userland) ──HTTP/NFS─────────▶ FOG server (stock)
```

`jog` installs the JOS staging script as `/usr/local/sbin/jog-stage-jos-boot.sh` (from a `jos` checkout, found via `$JOS_DIR`, a sibling `../jos`, or `/opt/JOG/jos`) and calls it during provisioning. JOG does not contain any JOS code.

## Layout

- `installer/`, `install/` — Ubuntu autoinstall seeds, wizard, native FOG install.
- `dnsmasq.d/`, `netplan/`, `nftables/`, `systemd/`, `config/` — imaging-network services (DHCP/TFTP isolated to the USB NIC).
- `kiosk/`, `lightdm/` — appliance UI.
- `scripts/` — provisioning, `jog-doctor.sh`, NIC and dnsmasq helpers, signed-shim copy.
- `cluster/` — multi-node image replication.
- `docs/` — laptop-side docs (`ISO-BUILD.md`, `CLUSTER.md`, `HANDOFF-OFFICE-CLAUDE.md`).

## Quick start

Get both repos, then see the integration repo (`jog-jos`) for the end-to-end flow:

```bash
git clone --recurse-submodules https://github.com/splippers/jog-jos.git
```

Build the JOS initrd with `jos/build/build-from-fos.sh`, install JOG with `sudo jog/install/jog-install.sh`, then stage with `sudo jog-stage-jos-boot.sh`.

## License

See [LICENSE](LICENSE).
