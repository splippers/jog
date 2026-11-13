# JOG — Jonathan's Opensource Ghost

A portable imaging appliance: an Ubuntu laptop running stock [FOG](https://fogproject.org) on an isolated
imaging network (USB Ethernet), with a kiosk UI and a guided installer. JOG is **not** a FOG fork.

JOG is the **server side**. The machines being imaged boot **[JOS](https://github.com/splippers/jos)**, a
Secure Boot-compatible replacement for FOG's FOS, which JOG serves over PXE.

## The three repos

| Repo | Role | Runs on |
|---|---|---|
| **jog** (this repo) | The imaging laptop: Ubuntu autoinstall, FOG install, DHCP/TFTP/nftables, kiosk, wizard, driver share, multicast profile, provisioning payload installer | the laptop (server) |
| [jos](https://github.com/splippers/jos) | The client runtime: initrd build, GRUB menu generator, local-boot fallback, Secure Boot chain staging | the machine being imaged (client); staged by the server |
| [jog-jos](https://github.com/splippers/jog-jos) | Integration: pins `jog` and `jos` together at known-good commits, combined docs, end-to-end tests | n/a |

**Rule of thumb:** if it configures or installs something on the laptop, it belongs here. If it runs on, or
builds for, the imaged machine, it belongs in `jos`.

## How they connect

```text
 imaged machine                          JOG laptop
 --------------                          ----------
 UEFI PXE ──DHCP/TFTP──────────────────▶ dnsmasq (jog)     serves shimx64.efi
 shim → grubnetx64 → signed kernel ◀──── /tftpboot/{grub,jos}/   staged by jos/scripts/jos-stage-boot.sh
 JOS (FOS userland) ──HTTP/NFS─────────▶ FOG server (stock)
```

`jog` installs the JOS staging script as `/usr/local/sbin/jog-stage-jos-boot.sh` (from a `jos` checkout,
found via `$JOS_DIR`, a sibling `../jos`, or `/opt/JOG/jos`) and calls it during provisioning. JOG does not
contain any JOS code.

## Corporate pipeline

The appliance can take a room of laptops from PXE to a domain-joined, encrypted asset:

```text
PHASE 1 — MULTICAST IMAGING  (the under-5-minute target)
PXE → JOS → FOG multicast → image written → post-download injection
                                                    │
                                                    ▼
PHASE 2 — PROVISIONING  (separate, after imaging)
drivers → hostname → domain join → Entra hybrid join → AD groups
        → BitLocker → escrow verified → COMPLETE
```

The five-minute figure is the **imaging phase only**. It does not include Windows first boot, drivers,
domain join, hybrid join, or BitLocker. Those run afterward as a resumable state machine and typically
take tens of minutes including reboots.

### What is in this repo

| Piece | Script | What it does |
|---|---|---|
| Driver share | `scripts/jog-driver-share.sh` | Samba `[Drivers]`, read-only `drivers` account, write `driveradmin` account |
| Multicast profile | `scripts/jog-multicast-tune.sh` | Sets `ngmMaxClients=100`, bitrate, join wait, sessions |
| Multicast auto-join | `scripts/jog-autojoin-setup.sh` | Default PXE entry joins a waiting session without menu 8 |
| Configuration | `scripts/jog-corporate-setup.sh` | Writes `/etc/jog/provisioning.env` (0600) |
| Payload installer | `scripts/jog-install-provisioner.sh` | Renders the Windows JSON and installs the FOG post-download hook |
| Post-FOG orchestration | `scripts/jog-post-fog-setup.sh` | Applies the profile after native FOG finishes |
| Windows payload | `provisioner/windows/` | Orchestrator, drivers, domain/hybrid join, groups, BitLocker, status |
| Post-download hook | `install/postdownload/jog-inject-provisioner.sh` | Copies the payload to `C:\ProgramData\JOG` |

### Quick start (corporate)

```bash
# 1. Driver share (read + write accounts)
sudo jog-driver-share.sh --apply

# 2. Domain / Entra / BitLocker / driver-share config
sudo jog-corporate-setup.sh

# 3. 100-client multicast profile (needs FOG installed)
sudo jog-multicast-tune.sh --apply

# 4. Default PXE auto-join for a waiting multicast session
sudo jog-autojoin-setup.sh --apply

# 5. Install the Windows payload + FOG hook
sudo jog-install-provisioner.sh
```

Or set `JOG_DRIVER_SHARE_ENABLE=1`, `JOG_MODEL_API_ENABLE=1`, `JOG_AUTOJOIN_ENABLE=1`,
`JOG_MULTICAST_TUNE=1`, and `JOG_PROVISIONING_ENABLE=1` in `/etc/jog/jog.env` and run
`sudo jog-provision-stack.sh`; the post-FOG hook applies them when native FOG finishes.

The driver UNC is `\\10.99.0.1\Drivers` on the imaging network (or `\\192.168.254.1\Drivers` on the
management network). Sync packs for the models FOG has inventoried with
`provisioner/windows/Sync-FOGDriverPacks.ps1` as `driveradmin`; the script queries the model API, resolves
Dell/HP catalog packs, extracts the INF trees, and writes `manifest.json`.

### Verify

```bash
sudo jog-doctor.sh
sudo JOG_CORPORATE_STRICT=1 jog-doctor.sh
sudo jog-multicast-tune.sh --check
sudo jog-autojoin-setup.sh --check
sudo jog-install-provisioner.sh --check
```

On the device: `C:\ProgramData\JOG\Get-JOGProvisioningStatus.ps1`.

## Layout

- `installer/`, `install/` — Ubuntu autoinstall seeds, wizard, native FOG install.
- `dnsmasq.d/`, `netplan/`, `nftables/`, `systemd/`, `config/` — imaging-network services
  (DHCP/TFTP isolated to the USB NIC).
- `kiosk/`, `lightdm/` — appliance UI.
- `scripts/` — provisioning, `jog-doctor.sh`, NIC and dnsmasq helpers, signed-shim copy, corporate
  pipeline.
- `provisioner/windows/` — the PowerShell payload that runs on the imaged device.
- `install/postdownload/` — the FOG post-download injection.
- `cluster/` — multi-node image replication.
- `docs/` — laptop-side docs (`CORPORATE.md`, `DRIVERS.md`, `ISO-BUILD.md`, `CLUSTER.md`).

## Quick start (imaging only)

Get both repos, then see the integration repo (`jog-jos`) for the end-to-end flow:

```bash
git clone --recurse-submodules https://github.com/splippers/jog-jos.git
```

Build the JOS initrd with `jos/build/build-from-fos.sh`, install JOG with
`sudo jog/install/jog-install.sh`, then stage with `sudo jog-stage-jos-boot.sh`.

## Documentation

| Doc | Contents |
|---|---|
| [`docs/CORPORATE.md`](docs/CORPORATE.md) | Appliance runbook for the corporate pipeline |
| [`docs/DRIVERS.md`](docs/DRIVERS.md) | Driver-share layout, upload, permissions, RAID/VMD |
| [`docs/ISO-BUILD.md`](docs/ISO-BUILD.md) | Building the portable ISO |
| [`docs/CLUSTER.md`](docs/CLUSTER.md) | Multi-node replication |
| [`jog-jos/docs/CORPORATE-PROVISIONING.md`](https://github.com/splippers/jog-jos/blob/main/docs/CORPORATE-PROVISIONING.md) | Full state machine, credentials, retries, test plan |
| [`jog-jos/docs/BITLOCKER-AD.md`](https://github.com/splippers/jog-jos/blob/main/docs/BITLOCKER-AD.md) | AD/BitLocker recovery-password vs PIN |
| [`jog-jos/docs/MULTICAST-100.md`](https://github.com/splippers/jog-jos/blob/main/docs/MULTICAST-100.md) | 100-client imaging math and network design |

## License

See [LICENSE](LICENSE).
