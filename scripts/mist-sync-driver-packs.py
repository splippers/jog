#!/usr/bin/env python3
"""Sync vendor driver packs for every model in the FOG inventory.

The Brume appliance normally has no Windows workstation attached.  This script
does the same catalog work as Sync-FOGDriverPacks.ps1, but runs on the appliance
and publishes directly into the Samba [Drivers] share.

  sudo mist-sync-driver-packs.py --plan-only
  sudo mist-sync-driver-packs.py
  sudo mist-sync-driver-packs.py --minimal      # drop video/audio/.so
  sudo mist-sync-driver-packs.py --slim-existing --plan-only
  sudo mist-sync-driver-packs.py --slim-existing
  sudo mist-sync-driver-packs.py --mode vendor   # keep the vendor .exe/.cab

By default the vendor pack is downloaded, verified, extracted, pruned to the
INF trees pnputil needs, and published as <share>/<MODEL-SLUG>.  The vendor
download is deleted after a successful publish unless --keep-downloads is set.

The --minimal profile removes the large video/audio trees and Linux .so files
before publishing.  --slim-existing applies the same profile to packs that are
already on the share; use --plan-only for a dry run.  The VMD base pack,
storage, chipset, network, input, security, and dock drivers are retained.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

DELL_CATALOG_URL = "https://downloads.dell.com/catalog/DriverPackCatalog.cab"
HP_CATALOG_URL = "https://hpia.hpcloud.hp.com/downloads/driverpackcatalog/HPClientDriverPackCatalog.cab"
DEFAULT_WORK_DIR = Path("/tmp/opencode/mist-driver-sync")
DEFAULT_OS = "Windows11"
FALLBACK_OS = "Windows10"


def log(message: str) -> None:
    print(f"[mist-sync-driver-packs] {message}", flush=True)


def warn(message: str) -> None:
    print(f"[mist-sync-driver-packs] WARN: {message}", file=sys.stderr, flush=True)


def die(message: str) -> "NoReturn":
    print(f"[mist-sync-driver-packs] ERROR: {message}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def run(command: list[str], *, check: bool = True, quiet: bool = False) -> subprocess.CompletedProcess:
    if not quiet:
        log("$ " + " ".join(command))
    return subprocess.run(
        command,
        check=check,
        stdout=subprocess.DEVNULL if quiet else None,
        stderr=subprocess.PIPE if quiet else None,
        text=True,
    )


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def model_slug(value: str) -> str:
    return re.sub(r"[^A-Z0-9]+", "-", (value or "").upper()).strip("-")


def vendor_name(manufacturer: str) -> str:
    name = (manufacturer or "").strip()
    low = name.lower()
    if low.startswith("dell"):
        return "Dell"
    if low.startswith("hp") or "hewlett" in low:
        return "HP"
    if low.startswith("lenovo"):
        return "Lenovo"
    return name or "Unknown"


def normalized_model(value: str) -> str:
    value = (value or "").lower()
    value = re.sub(
        r"\b(dell|inc\.?|hp|hewlett[- ]packard|lenovo|notebook|laptop|desktop|computer|corporation|company)\b",
        " ",
        value,
    )
    value = re.sub(r"[^a-z0-9]+", " ", value)
    return re.sub(r"\s+", " ", value).strip()


def model_matches(fog_model: str, catalog_model: str) -> bool:
    a = normalized_model(fog_model)
    b = normalized_model(catalog_model)
    if not a or not b:
        return False
    if a == b:
        return True
    at = a.split()
    bt = b.split()
    small, large = (at, bt) if len(at) <= len(bt) else (bt, at)
    if len(small) < 2:
        return False
    return all(token in large for token in small)


def parse_date(value: str) -> datetime:
    value = (value or "").strip()
    for fmt in (
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%d",
        "%m/%d/%Y %I:%M:%S %p",
        "%m/%d/%Y",
    ):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            pass
    return datetime.min


def version_key(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", value or "")) or (0,)


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def resolve_share(explicit: str) -> Path:
    if explicit:
        return Path(explicit).expanduser()
    env = read_env_file(Path("/etc/mist/mist.env"))
    if env.get("JOG_DRIVER_SHARE_PATH"):
        return Path(env["JOG_DRIVER_SHARE_PATH"]).expanduser()
    if os.environ.get("Brume_DRIVER_SHARE_PATH", os.environ.get("JOG_DRIVER_SHARE_PATH")):
        return Path(os.environ["JOG_DRIVER_SHARE_PATH"]).expanduser()
    try:
        result = subprocess.run(
            ["testparm", "-s", "--section-name=Drivers", "--parameter-name=path"],
            capture_output=True,
            text=True,
            check=False,
        )
        value = result.stdout.strip()
        if result.returncode == 0 and value:
            return Path(value)
    except FileNotFoundError:
        pass
    return Path("/srv/mist/drivers")


def fog_models(api_script: Path) -> list[dict]:
    try:
        result = subprocess.run(
            [sys.executable, str(api_script), "--once"],
            capture_output=True,
            text=True,
            check=True,
            timeout=60,
        )
        document = json.loads(result.stdout)
        models = document.get("models", [])
        if models:
            return models
    except Exception as exc:  # noqa: BLE001 - fall back to the DB query
        warn(f"model API --once failed ({exc}); trying the FOG database directly")

    cnf = Path("/etc/mist/model-api.my.cnf")
    if not cnf.is_file():
        die("no model API and no /etc/mist/model-api.my.cnf; cannot read FOG inventory")
    sql = """
SET SESSION group_concat_max_len = 1000000;
SELECT i.iSysman, i.iSysproduct, i.iSysversion, i.iMbproductname,
       COUNT(DISTINCT h.hostID),
       GROUP_CONCAT(DISTINCT h.hostName ORDER BY h.hostName SEPARATOR ',')
FROM inventory i
JOIN hosts h ON h.hostID = i.iHostID
WHERE (i.iDeleteDate IS NULL OR i.iDeleteDate = '0000-00-00 00:00:00')
  AND TRIM(i.iSysproduct) <> ''
GROUP BY i.iSysman, i.iSysproduct, i.iSysversion, i.iMbproductname
ORDER BY i.iSysman, i.iSysproduct;
"""
    result = subprocess.run(
        ["mysql", f"--defaults-extra-file={cnf}", "--batch", "--skip-column-names", "--raw", "-e", sql],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        die((result.stderr or "FOG database query failed").strip().splitlines()[-1])
    models = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) < 6:
            continue
        manufacturer, model, version, product, count, host_names = fields[:6]
        if not model.strip():
            continue
        models.append(
            {
                "manufacturer": manufacturer.strip(),
                "model": model.strip(),
                "version": version.strip(),
                "product": product.strip(),
                "vendor": vendor_name(manufacturer),
                "slug": model_slug(model),
                "count": int(count or 0),
                "hosts": [name for name in host_names.split(",") if name],
            }
        )
    return models


def download(url: str, destination: Path, *, size: str = "", sha256: str = "") -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    part = destination.with_name(destination.name + ".part")
    if part.exists():
        part.unlink()
    progress = ["--progress-bar"] if sys.stdout.isatty() else ["--silent", "--show-error"]
    command = [
        "curl",
        "-fL",
        "--retry",
        "3",
        "--connect-timeout",
        "30",
        *progress,
        "-o",
        str(part),
        url,
    ]
    try:
        run(command)
    except subprocess.CalledProcessError as exc:
        part.unlink(missing_ok=True)
        raise RuntimeError(f"download failed ({exc.returncode}) for {url}") from exc

    expected_size = int(size) if str(size).isdigit() else 0
    actual_size = part.stat().st_size
    if expected_size and actual_size != expected_size:
        part.unlink(missing_ok=True)
        raise RuntimeError(f"size mismatch for {url}: expected {expected_size}, got {actual_size}")

    expected_sha = (sha256 or "").strip().lower()
    if expected_sha:
        digest = hashlib.sha256()
        with part.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected_sha:
            part.unlink(missing_ok=True)
            raise RuntimeError(f"SHA256 mismatch for {url}")
    part.replace(destination)


def extract_catalog(catalog: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    run(["cabextract", "-q", "-d", str(destination), str(catalog)])


def parse_dell_catalog(xml_path: Path) -> list[dict]:
    root = ET.parse(xml_path).getroot()
    packs: list[dict] = []
    for package in root.iter():
        if local_name(package.tag) != "DriverPackage":
            continue
        fmt = (package.get("format") or "").lower()
        if fmt not in ("exe", "cab"):
            continue
        os_codes = sorted(
            {
                node.get("osCode", "")
                for node in package.iter()
                if local_name(node.tag) == "OperatingSystem"
                and node.get("osArch") == "x64"
                and node.get("osCode") in ("Windows11", "Windows10")
            }
        )
        if not os_codes:
            continue
        catalog_models = [
            node.get("name", "").strip()
            for node in package.iter()
            if local_name(node.tag) == "Model" and node.get("name", "").strip()
        ]
        if not catalog_models:
            continue
        sha256 = ""
        for node in package.iter():
            if local_name(node.tag) == "Hash" and node.get("algorithm", "").upper() == "SHA256" and node.text:
                sha256 = node.text.strip().lower()
                break
        relative = package.get("path", "")
        if (
            not relative
            or relative.startswith("/")
            or any(part in ("", ".", "..") for part in relative.split("/"))
            or not re.fullmatch(r"[A-Za-z0-9._/-]+", relative)
        ):
            continue
        packs.append(
            {
                "vendor": "Dell",
                "catalog_models": catalog_models,
                "date": parse_date(package.get("dateTime", "")),
                "version": package.get("dellVersion", ""),
                "release": package.get("releaseID", ""),
                "url": f"https://downloads.dell.com/{relative}",
                "sha256": sha256,
                "size": package.get("size", ""),
                "format": fmt,
                "os_codes": os_codes,
            }
        )
    return packs


def parse_hp_catalog(xml_path: Path) -> list[dict]:
    root = ET.parse(xml_path).getroot()
    softpaqs: dict[str, dict[str, str]] = {}
    for softpaq in root.iter():
        if local_name(softpaq.tag) != "SoftPaq":
            continue
        details = {
            local_name(child.tag): (child.text or "").strip()
            for child in list(softpaq)
        }
        softpaq_id = details.get("Id", "")
        if softpaq_id:
            softpaqs[softpaq_id] = details

    packs: list[dict] = []
    for entry in root.iter():
        if local_name(entry.tag) != "ProductOSDriverPack":
            continue
        details = {
            local_name(child.tag): (child.text or "").strip()
            for child in list(entry)
        }
        system_name = details.get("SystemName", "")
        os_name = details.get("OSName", "")
        softpaq_id = details.get("SoftPaqId", "")
        if not system_name or not softpaq_id:
            continue
        if not re.search(r"Windows 1[01]", os_name, re.IGNORECASE):
            continue
        if not re.search(r"64-bit|x64", os_name, re.IGNORECASE):
            continue
        softpaq = softpaqs.get(softpaq_id, {})
        url = softpaq.get("Url", "")
        if not url:
            continue
        if not url.startswith("https://"):
            warn(f"skipping non-HTTPS HP SoftPaq URL: {url}")
            continue
        os_code = "Windows11" if re.search(r"Windows 11", os_name, re.IGNORECASE) else "Windows10"
        packs.append(
            {
                "vendor": "HP",
                "catalog_models": [system_name],
                "date": parse_date(softpaq.get("DateReleased", "")),
                "version": "",
                "release": softpaq_id,
                "url": url,
                "sha256": softpaq.get("SHA256", "").strip().lower(),
                "size": softpaq.get("Size", ""),
                "format": "exe",
                "os_codes": [os_code],
                "name": softpaq.get("Name", ""),
            }
        )
    return packs


def select_pack(model: dict, packs: list[dict], os_target: str, allow_fallback: bool) -> dict | None:
    vendor = model.get("vendor", "")
    candidates = [
        pack
        for pack in packs
        if pack["vendor"] == vendor
        and any(model_matches(model["model"], catalog_model) for catalog_model in pack["catalog_models"])
    ]
    targets = [os_target]
    if allow_fallback and os_target == "Windows11":
        targets.append(FALLBACK_OS)
    for target in targets:
        matches = [pack for pack in candidates if target in pack["os_codes"]]
        if matches:
            return max(matches, key=lambda pack: (pack["date"], version_key(pack["version"]), version_key(pack["release"])))
    return None


def inf_count(root: Path) -> int:
    return sum(1 for path in root.rglob("*.inf") if path.is_file())


def prune_to_inf_trees(root: Path) -> int:
    """Remove directories that contain no INF file anywhere below them.

    pnputil only consumes INF trees.  Vendor packs also ship installers, logs,
    and HTML documentation; dropping those keeps the share small enough for the
    appliance's root filesystem.
    """
    infs = [path for path in root.rglob("*.inf") if path.is_file()]
    if not infs:
        return 0
    keep_dirs: set[Path] = set()
    for inf in infs:
        parent = inf.parent
        while parent != root.parent:
            keep_dirs.add(parent)
            if parent == root:
                break
            parent = parent.parent

    for path in sorted(root.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if path.is_dir():
            if path not in keep_dirs:
                shutil.rmtree(path, ignore_errors=True)
        elif path.parent not in keep_dirs:
            path.unlink(missing_ok=True)
    return inf_count(root)


def tree_size(root: Path) -> int:
    total = 0
    for path in root.rglob("*"):
        try:
            if path.is_file():
                total += path.stat().st_size
        except OSError:
            pass
    return total


def format_bytes(value: int) -> str:
    size = float(value)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            if unit == "B":
                return f"{int(size)} B"
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{value} B"


def prune_minimal_noise(root: Path, *, max_depth: int = 4) -> int:
    """Drop the large video/audio trees and Linux .so files from a pack.

    The corporate fleet needs storage, chipset, network, input, security, and
    dock drivers. Display and audio drivers are large and Windows Update can
    supply them. Only remove the shallow category folders so a nested audio
    driver inside a graphics package is not removed by accident.
    """
    for path in sorted(root.rglob("*"), key=lambda item: len(item.parts)):
        if not path.exists():
            continue
        try:
            relative_depth = len(path.relative_to(root).parts)
        except ValueError:
            continue
        if path.is_dir() and path.name.lower() in {"video", "audio"} and relative_depth <= max_depth:
            shutil.rmtree(path, ignore_errors=True)
        elif path.is_file() and path.suffix.lower() == ".so":
            path.unlink(missing_ok=True)

    # Remove directories left empty by the deletions.
    for path in sorted(root.rglob("*"), key=lambda item: len(item.parts), reverse=True):
        if path.is_dir() and path.exists():
            try:
                next(path.iterdir())
            except StopIteration:
                path.rmdir()
            except OSError:
                pass
    return inf_count(root)


def slim_share(share: Path, *, dry_run: bool) -> int:
    """Remove the large video/audio trees from already-published model packs."""
    manifest_path = share / "manifest.json"
    folders: list[Path] = []
    if manifest_path.is_file():
        try:
            document = json.loads(manifest_path.read_text(encoding="utf-8"))
            for entry in document.get("models", []):
                folder = str(entry.get("folder", "")).strip()
                if not folder:
                    continue
                candidate = share / folder
                if candidate.is_dir():
                    folders.append(candidate)
        except (OSError, ValueError) as exc:
            warn(f"cannot read {manifest_path}: {exc}")
    if not folders:
        folders = sorted(
            path
            for path in share.iterdir()
            if path.is_dir() and (path / "pack.json").is_file()
        )
    if not folders:
        die(f"no model pack folders found under {share}")

    log(f"slim profile: {len(folders)} model pack(s) under {share}")
    total_before = 0
    total_after = 0
    for folder in folders:
        before_size = tree_size(folder)
        before_infs = inf_count(folder)
        candidates: list[Path] = []
        for path in sorted(folder.rglob("*"), key=lambda item: len(item.parts)):
            if not path.exists():
                continue
            try:
                relative_depth = len(path.relative_to(folder).parts)
            except ValueError:
                continue
            if path.is_dir() and path.name.lower() in {"video", "audio"} and relative_depth <= 4:
                candidates.append(path)
            elif path.is_file() and path.suffix.lower() == ".so":
                candidates.append(path)
        log(
            f"  {folder.name}: {format_bytes(before_size)}, {before_infs} INF, "
            f"{len(candidates)} video/audio/.so item(s) to remove"
        )
        if not dry_run:
            for path in candidates:
                if not path.exists():
                    continue
                if path.is_dir():
                    shutil.rmtree(path, ignore_errors=True)
                else:
                    path.unlink(missing_ok=True)
            for path in sorted(folder.rglob("*"), key=lambda item: len(item.parts), reverse=True):
                if path.is_dir() and path.exists():
                    try:
                        next(path.iterdir())
                    except StopIteration:
                        path.rmdir()
                    except OSError:
                        pass
        after_size = tree_size(folder)
        after_infs = inf_count(folder)
        total_before += before_size
        total_after += after_size
        if not dry_run:
            log(f"    -> {format_bytes(after_size)}, {after_infs} INF")
    if dry_run:
        log(
            f"dry run: current total {format_bytes(total_before)} across "
            f"{len(folders)} pack(s); no files changed"
        )
    else:
        log(
            f"reduced {format_bytes(total_before)} -> {format_bytes(total_after)} "
            f"across {len(folders)} pack(s)"
        )
    return 0


def try_extract(command: list[str]) -> bool:
    try:
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def extract_pack(pack_file: Path, destination: Path) -> int:
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True, exist_ok=True)

    # The vendor .exe files are self-extracting CABs.  cabextract is the
    # smallest reliable extractor; 7z covers the InstallShield/7z variants.
    if pack_file.suffix.lower() in (".cab", ".exe"):
        try_extract(["cabextract", "-q", "-d", str(destination), str(pack_file)])
    if inf_count(destination) == 0:
        try_extract(["7z", "x", "-y", f"-o{destination}", str(pack_file)])
    if inf_count(destination) == 0:
        try_extract(["unzip", "-o", str(pack_file), "-d", str(destination)])

    # Some packs contain a second layer of CABs.  Extract them in place and
    # delete the container so the published tree is the INF tree only.
    for _ in range(3):
        nested = list(destination.rglob("*.cab"))
        if not nested:
            break
        progressed = False
        for cab in nested:
            target = cab.with_suffix("")
            target.mkdir(parents=True, exist_ok=True)
            if try_extract(["cabextract", "-q", "-d", str(target), str(cab)]) or try_extract(
                ["7z", "x", "-y", f"-o{target}", str(cab)]
            ):
                cab.unlink(missing_ok=True)
                progressed = True
        if not progressed:
            break

    return inf_count(destination)


def chown_tree(root: Path, owner: str) -> None:
    if os.geteuid() != 0:
        return
    try:
        import pwd
        import grp

        uid = pwd.getpwnam(owner).pw_uid
        gid = grp.getgrnam(owner).gr_gid
    except (KeyError, ImportError):
        return
    for path in [root, *root.rglob("*")]:
        try:
            os.chown(path, uid, gid, follow_symlinks=False)
            if path.is_dir():
                os.chmod(path, 0o775)
            else:
                os.chmod(path, 0o664)
        except OSError:
            pass


def publish(extracted: Path, target: Path, entry: dict, owner: str) -> None:
    if target.exists():
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(extracted), str(target))
    (target / "pack.json").write_text(json.dumps(entry, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    chown_tree(target, owner)


def write_manifest(share: Path, entries: list[dict]) -> None:
    manifest_path = share / "manifest.json"
    existing: list[dict] = []
    if manifest_path.is_file():
        try:
            old = json.loads(manifest_path.read_text(encoding="utf-8"))
            existing = list(old.get("models", []))
        except (OSError, ValueError):
            warn("existing manifest.json is unreadable; replacing it")
    by_folder = {str(entry.get("folder", "")): entry for entry in existing if entry.get("folder")}
    for entry in entries:
        by_folder[str(entry["folder"])] = entry
    document = {
        "schema": 1,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "models": [by_folder[key] for key in sorted(by_folder)],
    }
    manifest_path.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if os.geteuid() == 0:
        try:
            import pwd
            import grp

            uid = pwd.getpwnam("jon").pw_uid
            gid = grp.getgrnam("jon").gr_gid
            os.chown(manifest_path, uid, gid)
        except (KeyError, ImportError, OSError):
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync FOG model driver packs into the Brume Drivers share")
    parser.add_argument("--share", default="", help="Samba share path (default: [Drivers] path)")
    parser.add_argument("--work-dir", default=str(DEFAULT_WORK_DIR), help="download/extract cache")
    parser.add_argument("--api-script", default="/usr/local/bin/mist-model-api.py", help="model inventory API")
    parser.add_argument("--model", action="append", default=[], help="limit to a model name (repeatable)")
    parser.add_argument("--vendor", choices=["All", "Dell", "HP", "Lenovo"], default="All")
    parser.add_argument("--os", choices=["Windows11", "Windows10", "Auto"], default=DEFAULT_OS)
    parser.add_argument("--no-fallback", action="store_true", help="do not use Windows 10 when Windows 11 is unavailable")
    parser.add_argument("--mode", choices=["extract", "vendor"], default="extract", help="publish INF trees or vendor packs")
    parser.add_argument("--plan-only", action="store_true", help="resolve and print the plan only; with --slim-existing, a dry run")
    parser.add_argument("--keep-downloads", action="store_true", help="keep vendor downloads after publishing")
    parser.add_argument("--force", action="store_true", help="re-download even when the cache has the pack")
    parser.add_argument("--no-prune", action="store_true", help="keep non-INF vendor files")
    parser.add_argument("--minimal", action="store_true", help="drop large video/audio trees and Linux .so files")
    parser.add_argument("--slim-existing", action="store_true", help="slim already-published model packs; no download")
    args = parser.parse_args()

    share = resolve_share(args.share)
    if not share.is_dir():
        die(f"driver share does not exist: {share}")

    if args.slim_existing:
        return slim_share(share, dry_run=args.plan_only)

    if args.minimal and args.mode == "vendor":
        warn("--minimal has no effect in --mode vendor; use extract mode")

    for command in ("curl", "cabextract", "sha256sum"):
        if not shutil.which(command):
            die(f"required command not found: {command}")

    work = Path(args.work_dir)
    work.mkdir(parents=True, exist_ok=True)
    catalog_dir = work / "catalog"
    download_dir = work / "downloads"
    extract_dir = work / "extract"
    for directory in (catalog_dir, download_dir, extract_dir):
        directory.mkdir(parents=True, exist_ok=True)

    models = fog_models(Path(args.api_script))
    if args.model:
        wanted = {normalized_model(value) for value in args.model}
        models = [model for model in models if normalized_model(model["model"]) in wanted]
    if args.vendor != "All":
        models = [model for model in models if model.get("vendor") == args.vendor]
    if not models:
        die("no FOG inventory models matched the requested filter")

    log(f"driver share: {share}")
    log(f"work dir:    {work}")
    log(f"FOG models:  {len(models)}")
    for model in models:
        log(f"  {model.get('vendor')} / {model['model']} ({model.get('count', 0)} host(s))")

    dell_catalog = catalog_dir / "DriverPackCatalog.cab"
    hp_catalog = catalog_dir / "HPClientDriverPackCatalog.cab"
    packs: list[dict] = []
    if any(model.get("vendor") == "Dell" for model in models):
        download(DELL_CATALOG_URL, dell_catalog)
        extract_catalog(dell_catalog, catalog_dir / "dell")
        packs.extend(parse_dell_catalog(catalog_dir / "dell" / "DriverPackCatalog.xml"))
    if any(model.get("vendor") == "HP" for model in models):
        download(HP_CATALOG_URL, hp_catalog)
        extract_catalog(hp_catalog, catalog_dir / "hp")
        packs.extend(parse_hp_catalog(catalog_dir / "hp" / "HPClientDriverPackCatalog.xml"))
    log(f"catalog candidates: {len(packs)}")

    os_target = DEFAULT_OS if args.os == "Auto" else args.os
    allow_fallback = not args.no_fallback
    resolved: list[tuple[dict, dict]] = []
    failures: list[str] = []
    for model in models:
        pack = select_pack(model, packs, os_target, allow_fallback)
        if not pack:
            failures.append(f"{model.get('vendor')} {model['model']}: no driver pack")
            warn(f"no driver pack for {model.get('vendor')} {model['model']}")
            continue
        resolved.append((model, pack))
        log(
            f"matched {model['model']} -> {pack['vendor']} {pack['release']} "
            f"({pack['date'].date()}, {pack['os_codes'][0]})"
        )

    if not resolved:
        die("no models could be matched to a vendor driver pack")
    if args.plan_only:
        for model, pack in resolved:
            log(f"PLAN {model['model']} -> {share / model_slug(model['model'])}")
        return 1 if failures else 0

    published: list[dict] = []
    for model, pack in resolved:
        slug = model_slug(model["model"])
        target = share / slug
        extension = ".cab" if pack["format"] == "cab" else ".exe"
        download_path = download_dir / f"{slug}-{pack['release']}{extension}"
        try:
            if not download_path.is_file() or args.force:
                log(f"downloading {pack['vendor']} {pack['release']} for {model['model']}")
                download(pack["url"], download_path, size=pack["size"], sha256=pack["sha256"])
            else:
                log(f"using cached download: {download_path}")

            entry = {
                "model": model["model"],
                "vendor": pack["vendor"],
                "folder": slug,
                "pack": pack["release"],
                "version": pack["version"],
                "date": pack["date"].strftime("%Y-%m-%dT%H:%M:%SZ"),
                "url": pack["url"],
                "sha256": pack["sha256"],
                "size": pack["size"],
                "format": pack["format"],
                "os": pack["os_codes"],
                "aliases": sorted(
                    {
                        model["model"],
                        f"{model.get('manufacturer', '').strip()} {model['model']}".strip(),
                    }
                ),
            }

            if args.mode == "vendor":
                target.mkdir(parents=True, exist_ok=True)
                for old in target.glob(f"*{extension}"):
                    old.unlink(missing_ok=True)
                shutil.copy2(download_path, target / download_path.name)
                (target / "pack.json").write_text(
                    json.dumps(entry, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
                )
                chown_tree(target, "jon")
                published.append(entry)
                log(f"published vendor pack to {target / download_path.name}")
                continue

            staging = extract_dir / slug
            count = extract_pack(download_path, staging)
            if count == 0:
                raise RuntimeError(f"no .inf files after extracting {download_path.name}")
            if not args.no_prune:
                count = prune_to_inf_trees(staging)
            if args.minimal:
                count = prune_minimal_noise(staging)
                log(f"minimal profile: {count} INF file(s) after dropping video/audio/.so")
            log(f"extracted {count} INF file(s) for {slug}")
            publish(staging, target, entry, "jon")
            published.append(entry)
            log(f"published {slug} to {target}")
            if not args.keep_downloads:
                download_path.unlink(missing_ok=True)
        except Exception as exc:  # noqa: BLE001 - continue with the next model
            failures.append(f"{model['model']}: {exc}")
            warn(f"failed for {model['model']}: {exc}")

    if published:
        write_manifest(share, published)
        log(f"updated {share / 'manifest.json'} ({len(published)} model(s))")

    if failures:
        warn(f"completed with {len(failures)} failure(s):")
        for failure in failures:
            warn(f"  {failure}")
        return 1
    log(f"done: {len(published)} model pack(s) published")
    return 0


if __name__ == "__main__":
    sys.exit(main())
