# Brume Provisioner (Windows)

The Windows-side half of the Brume corporate pipeline. It runs as **SYSTEM** after the image is applied.
In the default `AirGapped` mode it installs drivers, sets the hostname, and leaves the device in
`AWAITING_CORPORATE`. On the corporate network, `Resume-JOGCorporateEnrollment.ps1` finishes the pipeline:
domain join → Entra hybrid join → AD groups → BitLocker → escrow verified.

The Linux side installs this directory into `C:\ProgramData\Brume` and writes
`C:\Windows\Setup\Scripts\SetupComplete.cmd`. The orchestrator registers a `JOGProvisioning` scheduled task
at startup, so reboots resume the pipeline.

---

## Files

| File | Purpose |
|---|---|
| `Start-JOGProvisioning.ps1` | Orchestrator / state machine |
| `JOGCommon.ps1` | Shared logging, ACL, SMB, CIM, dsregcmd, PIN helpers |
| `Install-JOGDrivers.ps1` | Map the Samba share, read `manifest.json`, install VMD + model packs |
| `Set-JOGHostname.ps1` | Deterministic `LT-{Site}-{Serial}` name |
| `Write-JOGHandoff.ps1` | `AWAITING_CORPORATE` note, desktop shortcut, registry state, config sanitisation |
| `Resume-JOGCorporateEnrollment.ps1` | Corporate-LAN resume; checks DNS/DC, prompts for the join account |
| `Join-JOGDomain.ps1` | Credential/offline join, hybrid-join wait, AD groups |
| `Enable-JOGBitLocker.ps1` | TPM-only/TPM+PIN, recovery password escrow, verification |
| `Get-JOGProvisioningStatus.ps1` | Technician status view |
| `Add-JOGComputerGroups.ps1` | Management-host helper for offline-join group assignment |
| `Sync-FOGDriverPacks.ps1` | Workstation-side FOG inventory → vendor catalog → share sync |
| `Sync-JOGDrivers.ps1` | Legacy manual upload of an already-extracted pack |
| `Install-JOGDriverPack.ps1` | Manual one-model handoff; installs VMD + detected model pack |
| `JOGDriverHandoff.bat` | Batch wrapper for the manual first-logon handoff |
| `SetupComplete.cmd` | OOBE entry point |
| `haar-provisioning.example.json` | Configuration schema example |

---

## Configuration

The appliance renders the real `haar-provisioning.json` from
`haar/config/haar-provisioning.env.example`. See `docs/CORPORATE-PROVISIONING.md` for the full schema and the
security model.

Minimum useful air-gapped config:

```json
{
  "ProvisioningMode": "AirGapped",
  "Domain": "corp.example.com",
  "DomainJoin": {
    "Mode": "Credential",
    "OUPath": "OU=Workstations,OU=Brume,DC=corp,DC=example,DC=com"
  },
  "HybridJoin": { "Enabled": true, "TimeoutMinutes": 30 },
  "Groups": ["Brume-Workstations"],
  "BitLocker": { "Enabled": true, "Mode": "TpmOnly", "Escrow": "AD" },
  "DriverShare": {
    "Unc": "\\\\10.99.0.1\\Drivers",
    "ReadUser": "drivers",
    "ReadPassword": "CHANGE_ME",
    "BasePacks": ["VMD"],
    "Manifest": "manifest.json"
  }
}
```

`ProvisioningMode` is `AirGapped` (default) or `Connected`. `DomainJoin.Mode` is `Credential` (fleet
default) or `Offline` (single device or per-device `djoin` blob). The join password is blank in an
air-gapped config; the resume script prompts for it.

---

## Air-gapped handoff

After drivers and hostname:

```text
C:\ProgramData\Brume\AWAITING-CORPORATE.txt
C:\Users\Public\Desktop\Brume - Awaiting Corporate.txt
C:\Users\Public\Desktop\Complete Corporate Enrollment.lnk
HKLM\SOFTWARE\Brume\State = AWAITING_CORPORATE
```

The handoff stage removes the driver-share and domain-join passwords from the config. The device has not
joined the domain, has not been added to AD groups, and is not BitLocker-encrypted.

On the corporate network, sign in with a local administrator and double-click **Complete Corporate
Enrollment**, or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File C:\ProgramData\Brume\Resume-JOGCorporateEnrollment.ps1
```

The script self-elevates, checks DNS/DC reachability, warns about Entra endpoints, prompts for a delegated
join account in `Credential` mode, switches the config to `Connected`, and runs the orchestrator. In
`Offline` mode it does not prompt for a password.

---

## Manual run (lab)

From an elevated PowerShell on the imaged device:

```powershell
# Inspect first
.\Get-JOGProvisioningStatus.ps1

# Run without rebooting, so you can inspect each stage
.\Start-JOGProvisioning.ps1 -NoReboot -NoResumeTask -Force

# Normal run (registers the resume task)
.\Start-JOGProvisioning.ps1 -Resume
```

Logs: `C:\ProgramData\Brume\logs\`.

State: `C:\ProgramData\Brume\Provisioning.json`.

---

## Driver share

The fleet path is the catalog sync, run from a Windows 11 workstation with internet access:

```powershell
# Preview models and selected packs
.\Sync-FOGDriverPacks.ps1 -PlanOnly

# Download, extract, and upload to \\192.168.254.1\Drivers
.\Sync-FOGDriverPacks.ps1
```

It queries the read-only FOG model API, resolves Dell/HP catalog packs for the registered models, extracts
the INF trees, and writes `manifest.json`. The device installs the `VMD` base pack plus its model pack.
The share is read-only for the `drivers` account used by the device; the upload account is `driveradmin`.
Do not put either password in this repository. See `haar/docs/DRIVERS.md` for the API, catalog, and manifest
details.

For a single already-extracted pack, the legacy uploader still works:

```powershell
.\Sync-JOGDrivers.ps1 -Source D:\Drivers\LATITUDE-3440 -Model LATITUDE-3440
```

## Manual first-logon handoff

For a single Latitude 3440 lab machine, copy `JOGDriverHandoff.bat` and
`Install-JOGDriverPack.ps1` together into `C:\Temp`. Keep the existing answer-file
entry that runs `C:\Temp\firstrun.bat`; after its naming prompt and before any
restart or exit, add:

```bat
call C:\Temp\JOGDriverHandoff.bat
```

Before first logon, make sure the share contains `VMD\` and the model folder (the
catalog sync above does both). The handoff prompts for the `drivers` read-only
Samba credential, detects the model folder, installs the VMD base pack and the
model pack, and then calls the existing `C:\firstrun.bat`. A failed driver install
stops the handoff before the root script runs. This manual path does not start
`Start-JOGProvisioning.ps1` or the corporate state machine. The first-logon account
must be a local administrator and the batch must run elevated.

---

## Security notes

- The orchestrator runs as SYSTEM; no autologon and no interactive user is required.
- `C:\ProgramData\Brume` is ACL'd to SYSTEM/Administrators at first run.
- The rendered config contains the driver-share password during OOBE; the handoff stage removes it. In
  `Credential` mode the join password is prompted on the corporate LAN and written only for the resume.
- `CLEANUP` removes the config and secrets and reaches `COMPLETE` only after escrow verification.
- The BitLocker startup PIN is **not** written to AD by default. AD stores the 48-digit recovery password.
  See `../../../docs/BITLOCKER-AD.md`.
- Sign the PowerShell scripts with the organisation's code-signing certificate before production use, or
  enforce an execution policy that trusts the payload path.

---

## Testing checklist

- [ ] `Start-JOGProvisioning.ps1 -NoReboot` reaches `AWAITING_CORPORATE` with the desktop handoff.
- [ ] The handoff config has no driver-share or domain-join password.
- [ ] `Set-JOGHostname.ps1` produces a valid, unique ≤15-character name.
- [ ] `Resume-JOGCorporateEnrollment.ps1` refuses to run when no DC is reachable.
- [ ] Credential join applies and survives a reboot; `dsregcmd /status` shows `DomainJoined: YES`.
- [ ] Hybrid join reaches `AzureAdJoined: YES` + `DomainJoined: YES`.
- [ ] The computer appears in each configured AD group.
- [ ] `Get-BitLockerVolume` shows `ProtectionStatus: On` and a recovery-password protector.
- [ ] `manage-bde -protectors -get C:` shows the AD backup; `Get-ADObject` shows `msFVE-RecoveryPassword`.
- [ ] The pipeline reaches `COMPLETE` exactly once; a second boot does not re-run it.
