# Driver share and driver sync

The JOG appliance serves vendor driver packs to the Windows provisioner over SMB. The device pulls its
model pack and the VMD base pack during the `DRIVERS` stage, before domain join.

The pack list comes from FOG's hardware inventory, not from a hand-maintained list. A Windows 11
workstation queries the read-only JOG model API, resolves the latest Dell/HP driver-pack catalog entry for
each registered model, extracts the INF tree, and publishes it to the share.

## Layout

```text
\\192.168.254.1\Drivers\
├── manifest.json                 # model → folder, vendor, pack, version, aliases
├── VMD\                          # storage base pack, always installed first
│   ├── iaStorVD.inf
│   ├── iaStorVD.sys
│   └── ...
├── LATITUDE-3440\
│   ├── <extracted Dell INF tree>
│   └── ...
├── LATITUDE-3410\
├── DELL-PRO-14-PC14250\
├── HP-ELITEBOOK-735-G6\
└── DEFAULT\                      # optional fallback
```

The folder name is the uppercase model slug (`ConvertTo-JOGSlug`), but the provisioner prefers the
`manifest.json` mapping, so an operator can rename a folder or add aliases without breaking clients. The
folder is case-insensitive on SMB; keep it stable and documented.

`manifest.json` is written by `Sync-FOGDriverPacks.ps1` and has this shape:

```json
{
  "generated": "2026-11-13T12:00:00.0000000Z",
  "models": [
    {
      "model": "Latitude 3440",
      "vendor": "Dell",
      "folder": "LATITUDE-3440",
      "pack": "TG46W",
      "version": "A13",
      "date": "2026-05-14T00:00:00.0000000Z",
      "url": "https://downloads.dell.com/...",
      "sha256": "...",
      "aliases": ["Latitude 3440", "Dell Inc. Latitude 3440"]
    }
  ]
}
```

## Model API

The appliance exposes a read-only inventory API so the workstation does not need FOG database access or a
FOG API token:

```bash
sudo jog-model-api-setup.sh --apply
sudo jog-model-api-setup.sh --check
curl -fsS http://127.0.0.1:8089/healthz
curl -fsS -H "Authorization: Bearer <token>" http://127.0.0.1:8089/api/models
```

- Default endpoint: `http://192.168.254.1:8089/api/models` (the USB/workstation network).
- The service binds `0.0.0.0:8089`; use `http://10.99.0.1:8089/api/models` from the imaging network.
- Token file on the appliance: `/etc/jog/model-api.env` (0640 root:fogproject).
- Token for the workstation: `C:\ProgramData\JOG\model-api.token`, or pass `-ApiToken`.
- Retrieve the token on the appliance with `sudo jog-model-api-setup.sh --print-token`; do not commit it.
- The API reads the FOG `inventory` table (`iSysman`, `iSysproduct`, `iSysversion`, `iMbproductname`) and
  returns distinct models that have checked in.

`jog-post-fog-setup.sh` installs the API when `JOG_MODEL_API_ENABLE=1`. `jog-doctor.sh` checks the service
and `/healthz`.

## Sync packs from FOG inventory

Run this on a Windows 11 workstation that can reach both the appliance and the vendor download sites:

```powershell
# Preview the models and selected packs; downloads catalogs but does not upload
.\Sync-FOGDriverPacks.ps1 -PlanOnly

# Normal sync: prompt for the driveradmin password, download, extract, upload
.\Sync-FOGDriverPacks.ps1

# Limit to one model or vendor
.\Sync-FOGDriverPacks.ps1 -Model 'Latitude 3440'
.\Sync-FOGDriverPacks.ps1 -Vendor Dell

# Drop the large video/audio trees (recommended for the corporate fleet)
.\Sync-FOGDriverPacks.ps1 -Minimal

# Use the imaging-network address if the workstation routes to 10.99.0.0/24
.\Sync-FOGDriverPacks.ps1 -ApiUrl http://10.99.0.1:8089/api/models `
  -Destination \\10.99.0.1\Drivers
```

What the script does:

1. Queries the model API (unless `-Model` supplies a manual list).
2. Downloads the Dell `DriverPackCatalog.cab` and/or HP `HPClientDriverPackCatalog.cab`.
3. Selects the newest Windows 11 x64 pack for each model. With `-OS Windows11` and
   `-AllowWindows10Fallback $true` (the default), it publishes the latest Windows 10 pack when the vendor
   has no Windows 11 pack; the HP EliteBook 735 G6 is such a model.
4. Verifies the catalog SHA256, downloads the vendor `.exe`, extracts it with `expand.exe`, and checks that
   the tree contains `.inf` files.
5. With `-Minimal`, drops the large `video`/`audio` category trees and Linux `.so` files.
6. Mirrors the extracted tree to `\\192.168.254.1\Drivers\<MODEL-SLUG>` as `driveradmin`.
7. Merges the new entries into `manifest.json`.

Useful switches:

| Switch | Effect |
|---|---|
| `-PlanOnly` | Resolve and print the plan; no upload |
| `-NoUpload` | Download and extract, leave the tree in `-WorkDir` |
| `-Force` | Re-download even when the cache has the pack |
| `-KeepDownloads` | Keep the multi-gigabyte vendor downloads for diagnosis |
| `-Minimal` | Drop the large `video`/`audio` trees and Linux `.so` files |
| `-WorkDir` | Cache/catalog/extract directory; default `%ProgramData%\JOG\driver-sync` |
| `-OS` | `Windows11` (default), `Windows10`, or `Auto` |
| `-Vendor` | `All`, `Dell`, `HP`, or `Lenovo` |

The script logs to `%ProgramData%\JOG\logs\fog-driver-sync-*.log`.

## Run the sync on the appliance

`jog-sync-driver-packs.sh` does the catalog work on the appliance itself, so no Windows workstation
has to be online. It reads the FOG model inventory, downloads the newest Dell/HP Windows 11 x64 pack
for each model (falling back to Windows 10 when the vendor has no Windows 11 pack), verifies the
vendor SHA256 and size, extracts the pack, prunes it to the INF trees `pnputil` needs, and publishes
it to the `[Drivers]` share.

```bash
# Resolve the models and packs without downloading
sudo jog-sync-driver-packs.sh --plan-only

# Download, extract, prune, publish, and update manifest.json
sudo jog-sync-driver-packs.sh

# Limit the run
sudo jog-sync-driver-packs.sh --model 'Latitude 3440'
sudo jog-sync-driver-packs.sh --vendor Dell

# Drop the large video/audio trees and Linux .so files while publishing
sudo jog-sync-driver-packs.sh --minimal

# Slim packs that are already on the share (dry run first)
sudo jog-sync-driver-packs.sh --slim-existing --plan-only
sudo jog-sync-driver-packs.sh --slim-existing

# Keep the vendor .exe/.cab instead of publishing an INF tree
sudo jog-sync-driver-packs.sh --mode vendor
```

The default output is `<share>/<MODEL-SLUG>` (for example `LATITUDE-3440`) with a `pack.json` and a
merged `manifest.json` at the share root. Vendor downloads are removed after a successful publish;
pass `--keep-downloads` to retain them under `/tmp/opencode/jog-driver-sync/downloads`. The script
uses `cabextract` first and `7z`/`unzip` as fallbacks; install `p7zip-full` if a pack is a 7z or
InstallShield self-extractor.

`--mode vendor` is useful when the client-side installer will extract the pack itself. The normal
provisioner (`Install-JOGDrivers.ps1`) requires INF files, so keep the default `extract` mode for the
corporate pipeline.

## Minimal pack profile

The corporate fleet needs storage, chipset, network, input, security, dock, and vendor-system drivers.
It does not need the multi-gigabyte display and audio packages: Windows Update supplies those, and they
are the largest part of a vendor pack. The minimal profile removes shallow `video` and `audio` category
folders and Linux `.so` files, while keeping the VMD base pack and all other INF trees.

The live share is already slimmed. The full trees were kept as a hardlink backup at
`/images/.drivers-full-20261117`; remove that directory once a deployment test passes. The manifest is
unchanged: every model entry still points at its folder, and each folder still has `pack.json` and at
least one INF.

| Pack | Before | After | INFs kept |
|---|---:|---:|---:|
| HP EliteBook 735 G6 | 315 MiB | 184 MiB | 85 |
| Latitude 3410 | 2.9 GiB | 387 MiB | 145 |
| Latitude 3440 | 11.2 GiB | 291 MiB | 173 |
| Latitude 3450 | 7.0 GiB | 344 MiB | 198 |
| **Model total** | **21.4 GiB** | **1.2 GiB** | |

Use `--minimal` for future appliance syncs and `--slim-existing` for an existing share.
`--slim-existing --plan-only` is a dry run. The PowerShell sync has the equivalent `-Minimal` switch;
the appliance-side script is still the primary path because it also prunes non-INF vendor files.

## How the device uses the share

`Install-JOGDrivers.ps1`:

1. Reads `Win32_ComputerSystem` (manufacturer, model) and `Win32_BaseBoard` (product).
2. Normalises the model string and looks it up in `ModelMap`; otherwise derives the uppercase slug.
3. Maps `\\10.99.0.1\Drivers` with the `drivers` account.
4. Reads `manifest.json` and matches the model/aliases.
5. Stages the `BasePacks` (default `VMD`) and the model pack.
6. Runs `pnputil.exe /add-driver <dir>\*.inf /subdirs /install`.
7. Logs the INF names and exit codes, unmaps the share, and deletes the staging directory.

The VMD base pack is installed even when the model pack is missing, so a factory-RAID machine can still
boot. If the share, manifest, or model pack is unavailable, the stage sets `DRIVERS_PENDING` and the
scheduled task retries.

For a manual one-model handoff, `Install-JOGDriverPack.ps1` and `JOGDriverHandoff.bat` install the VMD base
pack plus the detected model pack. They are a fallback for a lab or a single machine, not the fleet path.

## Accounts

| Account | Rights | Used by |
|---|---|---|
| `drivers` | read-only | the Windows provisioner on the device |
| `driveradmin` | read/write | the workstation running `Sync-FOGDriverPacks.ps1` |

Both are Samba accounts created by `jog-driver-share.sh`. Their passwords live in
`/etc/jog/driver-share.env` (0600) on the appliance. Do not commit them.

Guest access can be enabled for legacy clients, but Windows 11 24H2 blocks insecure guest SMB by default
(`0x800704F8`). Use the `drivers` credentials; do not make guest access the fix.

## Upload a pack manually

If you already have an extracted INF tree and do not want to run the catalog sync, copy it to the share as
`driveradmin`:

```powershell
$dest = '\\192.168.254.1\Drivers\LATITUDE-3440'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -Path D:\Drivers\Latitude-3440\* -Destination $dest -Recurse -Force
```

Then add or update the model entry in `manifest.json`. The provisioner falls back to the slug when the
manifest has no entry, so a manual folder named `LATITUDE-3440` still works.

## Extract, do not upload the installer

`pnputil /add-driver` needs `.inf` files. Extract the vendor pack first:

- Dell: run the `.exe` with `/s` or extract the `.cab` with `expand`.
- HP/Lenovo: extract the SoftPaq/package to a folder.
- Keep the `VMD\iaStorVD.inf` (or the model's storage driver) if the fleet boots in RAID On.

The `DRIVERS` stage fails with `No .inf files` if only an `.exe` is present. That is deliberate: a silent
installer is not reproducible and cannot be audited.

## Verify as the client account

```bash
smbclient //127.0.0.1/Drivers -U 'drivers%<password>' -c 'ls'
smbclient //127.0.0.1/Drivers -U 'drivers%<password>' -c 'get manifest.json /tmp/manifest.json'
smbclient //127.0.0.1/Drivers -U 'drivers%<password>' -c 'ls LATITUDE-3440'
smbclient //127.0.0.1/Drivers -U 'drivers%<password>' -c 'get VMD\\iaStorVD.inf /tmp/iaStorVD.inf'
```

`0x800704F8` (Windows 11 24H2) and `0x80070569` (older) mean the client tried guest access. Use the
`drivers` credentials from the rendered config.

## RAID On and `iaStorVD`

The fleet standard is RAID On. The `iaStorVD` INF has no `CriticalDeviceDatabase` entry by design; it
binds as a boot-start SCSI miniport (`StartType = SERVICE_BOOT_START`). Keep the storage driver in
`VMD\`, and keep the AHCI image (`WIN11-SEP26`) as rollback until the RAID image (`WIN11-NOV26-18`) is
deploy-tested on a factory-RAID machine.

## Permissions

> On this appliance the live share is on the separate `/images` volume at
> `/images/Drivers`; `/etc/jog/jog.env` sets `JOG_DRIVER_SHARE_PATH` to that path.
> `/opt/thepermanentway/refmaterial/Drivers` is kept as a compatibility symlink.
> Keep the share off the root LV: full vendor packs can exceed 15 GB.

- Share path: `/srv/jog/drivers`, mode 2775, owner `jogshare:jogdrivers`.
- `force user = jogshare`, `force group = jogdrivers`, `create mask = 0664`, `directory mask = 2775`.
- `write list = @jogdriveradmin`; `read only = yes` for everyone else.
- Guest access is optional (`JOG_DRIVER_ALLOW_GUEST`), not required by the provisioner.

If you migrate an existing share, set `JOG_DRIVER_SHARE_PATH` to its path before `--apply`, or keep the
inline Samba section and use `--rotate` to manage passwords.
