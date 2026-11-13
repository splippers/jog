# Corporate pipeline on the JOG appliance

This is the appliance-side runbook. The Windows-side state machine and the full design are in
[`jog-jos/docs/CORPORATE-PROVISIONING.md`](https://github.com/splippers/jog-jos/blob/main/docs/CORPORATE-PROVISIONING.md).

> **Two clocks.** The 100-laptops-in-under-5-minutes figure is the **multicast imaging phase only**.
> Drivers, domain join, Entra hybrid join, AD groups, and BitLocker run afterward as a separate,
> resumable provisioning phase.

---

## 1. What the appliance does

```text
PXE → JOS → FOG multicast → image written
                               │
                               ▼
              /images/postdownloadscripts/jog-inject-provisioner.sh
              copies C:\ProgramData\JOG\* and SetupComplete.cmd
                               │
                               ▼
              Windows first boot → JOGProvisioning state machine
```

The appliance provides:

| Piece | Script | Output |
|---|---|---|
| Driver share | `jog-driver-share.sh` | Samba `[Drivers]`, read/write accounts, `/etc/jog/driver-share.env` |
| Driver model API | `jog-model-api-setup.sh` | Read-only FOG inventory API for the Windows driver sync |
| Multicast auto-join | `jog-autojoin-setup.sh` | `/fog/service/jog-autojoin.php`; default PXE entry joins a waiting session |
| Multicast profile | `jog-multicast-tune.sh` | FOG `nfsGroupMembers` + `globalSettings`, including rendezvous |
| Configuration | `jog-corporate-setup.sh` | `/etc/jog/provisioning.env` (0600) |
| Payload installer | `jog-install-provisioner.sh` | `/images/postdownloadscripts/jog-provisioner/` + FOG hook |
| Post-FOG orchestration | `jog-post-fog-setup.sh` | Applies the above after native FOG finishes |
| Health check | `jog-doctor.sh` | Secure Boot chain + corporate checks |

---

## 2. Prerequisites

- JOG installed and native FOG finished (`/etc/jog/fog-native.done`).
- `/etc/jog/jog.env` has the imaging NIC and IPs finalised.
- Driver packs synced from the FOG model inventory — see [`DRIVERS.md`](DRIVERS.md). The Windows
  workstation needs internet access to the Dell/HP catalogs; the appliance does not.
- AD/Entra prerequisites from the integration doc: target OU, delegated join account (the fleet default)
  or a per-device `djoin` blob, groups, hybrid-join line of sight, BitLocker schema/GPO.

---

## 3. Configure

### 3.1 Driver share

```bash
sudo jog-driver-share.sh --check
sudo jog-driver-share.sh --apply
sudo jog-driver-share.sh --rotate     # new passwords
```

This creates:

- Unix groups `jogdrivers` (read) and `jogdriveradmin` (write), and the `jogshare` force-user.
- Samba accounts `drivers` (read-only) and `driveradmin` (write).
- `/srv/jog/drivers` (2775, `jogshare:jogdrivers`).
- `/etc/samba/jog-drivers.conf` and an `include` line in `/etc/samba/smb.conf`.
- `/etc/jog/driver-share.env` (0600) with the generated passwords.

If `smb.conf` already contains an inline `[Drivers]` section, `--apply` leaves it untouched and exits
non-zero. Point `JOG_DRIVER_SHARE_PATH` at that path, or remove the inline section and re-run. `--rotate`
still updates the Samba passwords for an inline share.

The client UNC is `\\10.99.0.1\Drivers` on the imaging network (or `\\192.168.254.1\Drivers` on the
management network).

### 3.2 Provisioning configuration

```bash
sudo jog-corporate-setup.sh
```

It writes `/etc/jog/provisioning.env` (0600) and, if enabled, runs the payload installer. The fields are
documented in [`config/jog-provisioning.env.example`](../config/jog-provisioning.env.example).

Key choices:

| Choice | Recommended | Why |
|---|---|---|
| `JOG_PROVISIONING_MODE` | `AirGapped` | Imaging is on an isolated network; corporate stages are deferred until the device reaches Corporate |
| `JOG_DOMAIN_JOIN_MODE` | `Credential` | One `djoin` blob joins one computer account, so a single blob cannot cover a fleet; use `Offline` only for a single device or per-device blob |
| `JOG_DRIVER_BASE_PACKS` | `VMD` | Installs the `iaStorVD` storage base pack before the model pack |
| `JOG_BITLOCKER_MODE` | `TpmOnly` | No pre-boot PIN to distribute or store |
| `JOG_BITLOCKER_ESCROW` | `AD` (or `Both`) | AD stores the 48-digit recovery password in `msFVE-RecoveryPassword` |
| `JOG_BITLOCKER_PIN_STORAGE` | `None` for TPM-only | AD has no supported startup-PIN attribute |
| `JOG_AD_GROUPS` | your standard workstation groups | Verified with `net group ... /domain` before `COMPLETE` |

### 3.3 Multicast profile

```bash
sudo jog-multicast-tune.sh --check
sudo jog-multicast-tune.sh --apply
```

It sets `ngmMaxClients=100`, `ngmMaxBitrate=800m`, `FOG_UDPCAST_MAXWAIT=3` minutes,
`FOG_MULTICAST_MAX_SESSIONS=64`, `FOG_MULTICAST_DUPLEX=--full-duplex`, the interface, and
`FOG_MULTICAST_RENDEZVOUS` (defaults to the imaging interface's IPv4 address, `10.99.0.1` for `enp2s0`).
It backs up `nfsGroupMembers` + `globalSettings` to `/var/backups/jog/` first. The arithmetic and network
checklist are in [`jog-jos/docs/MULTICAST-100.md`](https://github.com/splippers/jog-jos/blob/main/docs/MULTICAST-100.md).

The rendezvous address must match the address the FOS client uses for `$storageip`. A mismatch makes
`udp-sender` and `udp-receiver` wait on different control addresses and the session never starts.

`FOG_UDPCAST_MAXWAIT` is **minutes**; FOG stores it as `value × 60` seconds. Re-create an existing session
after applying the profile; the sender command is built when the session starts.

### 3.4 Default PXE auto-join

```bash
sudo jog-autojoin-setup.sh --check
sudo jog-autojoin-setup.sh --apply
```

Installs `/fog/service/jog-autojoin.php`. On the default JOS PXE entry, the client asks this endpoint
before the normal FOG handshake. If exactly one multicast session is still in its join window, the
endpoint creates the per-host multicast association; JOS then starts the normal FOS client and joins
without a menu selection or a FOG login. An existing queued task is left alone. If nothing is waiting,
JOS boots the local disk; if several sessions are waiting, JOS asks the operator to use entry 8 rather
than guessing.

The endpoint is MAC-resolved like FOG's own service endpoints and is restricted to
`JOG_AUTOJOIN_ALLOW_NET` (default `10.99.0.0/24`, derived from `JOG_IMAGING_IP`/`JOG_IMAGING_PREFIX`).
Set `JOG_AUTOJOIN_ENABLE=1` to have `jog-post-fog-setup.sh` install it automatically. `jog-doctor.sh`
checks the endpoint.

### 3.5 Install the payload

```bash
sudo jog-install-provisioner.sh
sudo jog-install-provisioner.sh --check
```

This renders `/images/postdownloadscripts/jog-provisioner/jog-provisioning.json`, copies the PowerShell
payload, installs `jog-inject-provisioner.sh`, and appends a source line to
`/images/postdownloadscripts/fog.postdownload`.

The rendered config contains the driver-share read password. In `AirGapped` mode the join password is
blank; the resume script prompts for it on the corporate LAN. In `Connected` mode the join password is
rendered too, so use that mode only in a lab. The file is mode 0640, owned by the FOG service user, on the
read-only `/images` export. The handoff stage removes the driver and join passwords before the device leaves
the imaging network.

---

## 4. One-shot profile

Set these in `/etc/jog/jog.env` before `jog-provision-stack.sh`:

```bash
JOG_DRIVER_SHARE_ENABLE=1
JOG_MODEL_API_ENABLE=1
JOG_AUTOJOIN_ENABLE=1
JOG_MULTICAST_TUNE=1
JOG_PROVISIONING_ENABLE=1
```

`jog-provision-stack.sh` applies the profile immediately if FOG is already installed. Otherwise
`jog-fog-install-once.sh` calls `jog-post-fog-setup.sh` when the native install finishes. Re-run manually
at any time:

```bash
sudo jog-post-fog-setup.sh
```

---

## 5. Verify

```bash
# Secure Boot chain + corporate checks
sudo jog-doctor.sh

# Strict corporate checks
sudo JOG_CORPORATE_STRICT=1 jog-doctor.sh

# Share read/write as the two accounts
smbclient //127.0.0.1/Drivers -U 'drivers%<password>' -c 'ls'
smbclient //127.0.0.1/Drivers -U 'driveradmin%<password>' -c 'mkdir .t; rmdir .t'

# FOG values, including the rendezvous address
sudo jog-multicast-tune.sh --check

# Default PXE auto-join endpoint
sudo jog-autojoin-setup.sh --check

# Model API and a sample inventory response
curl -fsS http://127.0.0.1:8089/healthz
sudo jog-model-api-setup.sh --check

# Payload
sudo jog-install-provisioner.sh --check
```

On the imaged device, after first boot:

```powershell
C:\ProgramData\JOG\Get-JOGProvisioningStatus.ps1
Get-Content C:\ProgramData\JOG\Provisioning.json
Get-ChildItem C:\ProgramData\JOG\logs
```

Expected end state after imaging is `State: AWAITING_CORPORATE` with the desktop handoff shortcut. After
the device reaches Corporate and `Resume-JOGCorporateEnrollment.ps1` runs, the end state is `State:
COMPLETE`, `DomainJoined: YES`, `AzureAdJoined: YES` (if enabled), BitLocker `ProtectionStatus: On`, and the
recovery password visible in AD under the computer object's `msFVE-RecoveryInformation`.

---

## 6. Troubleshooting

| Symptom | Check |
|---|---|
| `0x800704F8` / `0x80070569` on the driver share | Windows 11 24H2 blocks guest SMB; use the `drivers` credentials, not guest |
| Driver stage `DRIVERS_PENDING` | Share reachable? `manifest.json` present? `Drivers\<Model>` exists? INF files extracted? |
| Model API unhealthy | `systemctl status jog-model-api`; `curl http://127.0.0.1:8089/healthz`; rerun `jog-model-api-setup.sh --apply` |
| Driver sync finds no pack | Check the model API inventory, catalog network access, and `-PlanOnly` output |
| `AWAITING_CORPORATE` after imaging | Expected in `AirGapped` mode; connect to Corporate and run the desktop resume shortcut |
| Domain join `DOMAIN_JOIN_PENDING` | Credential delegated to the OU? Offline blob present and per-device? DNS/line of sight? |
| `HYBRID_JOIN_PENDING` | `dsregcmd /status`; SCP, DNS, `enterpriseregistration.windows.net` |
| `GROUPS_PENDING` | Offline join: run `Add-JOGComputerGroups.ps1` from a management host |
| `BITLOCKER_PENDING` | TPM ready? GPO allows BitLocker? AD escrow permitted? |
| No `C:\ProgramData\JOG` after imaging | Did the post-download hook run? Check the FOG task log for `[jog-inject]` |
| Provisioner not resuming | `Get-ScheduledTask JOGProvisioning`; the task runs at startup as SYSTEM |

---

## 7. Security notes

- No autologon; the payload runs as SYSTEM via `SetupComplete.cmd` and a startup task.
- The driver account is read-only. The upload account is `driveradmin`; do not put its password in the
  repository or in the payload.
- Credential join is the fleet default. The join password is prompted on the corporate LAN, written only
  for the resume, and deleted at `COMPLETE`. Use offline join only for a single device or per-device blob.
- AD stores the **recovery password**, not the startup PIN. See
  [`jog-jos/docs/BITLOCKER-AD.md`](https://github.com/splippers/jog-jos/blob/main/docs/BITLOCKER-AD.md).
- The `/images` export is on the isolated imaging network; treat it as sensitive anyway.
