#!/usr/bin/env python3
"""HAAR mobile companion API.

A small authenticated HTTPS aggregator for the HAAR Android app. It runs on the
imaging appliance, reads the existing localhost-only HAAR APIs and FOG API with
root-held credentials, and exposes one authenticated JSON endpoint set to the
hidden HAARMETRY WiFi.

Design rules
  * FOG / model API tokens never leave the appliance.
  * Every /api/v1/ request needs Authorization: Bearer <JOG_MOBILE_TOKEN>.
  * FOG is optional: if its tokens are empty, the app still shows local status
    and reports "not configured" instead of failing.
  * Control actions (deploy, capture, wake, cancel) are proxied to FOG. The
    Android app asks for confirmation before calling them.

Env files (root-owned; see config/mobile-api.env.example):
  JOG_MOBILE_ENV     default /etc/jog/mobile-api.env
  JOG_FOG_API_ENV    default /etc/jog/fog-api.env
  JOG_MODEL_API_ENV  default /etc/jog/model-api.env

Standard library only.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import threading
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from enrollment import ApPskManager, EnrollmentError, EnrollmentStore

ENV_FILE = os.environ.get("HAARMETRY_MOBILE_ENV", os.environ.get("JOG_MOBILE_ENV", os.environ.get("JOG_MOBILE_ENV", "/etc/jog/mobile-api.env" if os.path.exists("/etc/jog/mobile-api.env") else "/etc/jog/mobile-api.env")))
FOG_ENV = os.environ.get("JOG_FOG_API_ENV", os.environ.get("JOG_FOG_API_ENV", "/etc/jog/fog-api.env" if os.path.exists("/etc/jog/fog-api.env") else "/etc/jog/fog-api.env"))
MODEL_ENV = os.environ.get("JOG_MODEL_API_ENV", os.environ.get("JOG_MODEL_API_ENV", "/etc/jog/model-api.env" if os.path.exists("/etc/jog/model-api.env") else "/etc/jog/model-api.env"))

TASK_TYPES = {
    "deploy": 1,
    "capture": 2,
    "multicast": 8,
    "wakeup": 14,
}

SERVICES = [
    "jog-imaging-api.service",
    "jog-model-api.service",
    "apache2.service",
    "mariadb.service",
    "dnsmasq.service",
    "FOGScheduler.service",
    "FOGMulticastManager.service",
    "FOGImageReplicator.service",
]


def load_env(path):
    out = {}
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, val = line.split("=", 1)
                    out[key.strip()] = val.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # FOG redirects to the login page when tokens are bad


_opener = urllib.request.build_opener(NoRedirect)
_config = {}
_cache = {}
_cache_lock = threading.Lock()
_enrollment_store = None
_ap_psk_manager = None


def _send_webhook(event, detail=None, ok=True):
    url = (_config.get("webhook_url") or "").strip()
    if not url:
        return
    payload = {
        "event": event,
        "ok": bool(ok),
        "detail": detail or {},
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "source": "jogemetry-mobile-api",
    }
    body = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json", "Accept": "application/json", "User-Agent": "HAAR-Webhook/1"}
    if "discord.com/api/webhooks" in url or "discordapp.com/api/webhooks" in url:
        msg = "[%s] %s %s" % ("OK" if ok else "FAIL", event, json.dumps(detail or {}, ensure_ascii=False)[:1500])
        body = json.dumps({"content": msg[:1900]}).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            resp.read(256)
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write("jogemetry-mobile-api: webhook failed: %s\n" % exc)


AUDIT_LOG = os.environ.get("JOG_AUDIT_LOG", "/var/log/jog/audit.jsonl")


def audit_write(event, detail=None, ok=True):
    detail = detail or {}
    entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event, "ok": bool(ok), "detail": detail, "source": "jogemetry-mobile-api"}
    try:
        os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
        with open(AUDIT_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write("jogemetry-mobile-api: audit write failed: %s\n" % exc)


def notify(event, detail=None, ok=True):
    detail = detail or {}
    audit_write(event, detail, ok)
    try:
        _config["action_log"]("%s %s" % (event, json.dumps(detail, ensure_ascii=False)[:500]))
    except Exception:
        pass
    threading.Thread(target=_send_webhook, args=(event, dict(detail), bool(ok)), daemon=True).start()


class ApiError(Exception):
    def __init__(self, message, status=502):
        super().__init__(message)
        self.status = status


def http_json(url, headers=None, method="GET", payload=None, timeout=6):
    data = None
    hdrs = {"Accept": "application/json"}
    if headers:
        hdrs.update(headers)
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with _opener.open(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        if 300 <= exc.code < 400:
            raise ApiError("FOG rejected the API credentials", 401) from exc
        raise ApiError("Upstream returned HTTP %d" % exc.code, 502) from exc
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise ApiError("Upstream unreachable: %s" % exc, 503) from exc
    try:
        return json.loads(raw) if raw else {}
    except ValueError as exc:
        raise ApiError("Upstream returned invalid JSON", 502) from exc


def cached(key, ttl, producer):
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    value = producer()
    with _cache_lock:
        _cache[key] = (now, value)
    return value


def fog_configured():
    return bool(_config["fog_api_token"] and _config["fog_user_token"])


def fog_request(path, method="GET", payload=None):
    if not fog_configured():
        raise ApiError("FOG API tokens are not configured on the appliance", 503)
    base = _config["fog_url"].rstrip("/")
    headers = {
        "fog-api-token": _config["fog_api_token"],
        "fog-user-token": _config["fog_user_token"],
    }
    return http_json(base + path, headers, method, payload)


def fog_list(kind, per_page=1000):
    result = fog_request("/%s?perPage=%d" % (kind, per_page))
    if isinstance(result, dict):
        return result.get("data", result.get(kind, [])) or []
    return result if isinstance(result, list) else []


def get_imaging():
    return cached("imaging", 3, lambda: http_json(_config["imaging_url"] + "/api/devices"))


def get_models():
    return cached("models", 10, lambda: http_json(
        _config["model_url"] + "/api/models",
        {"Authorization": "Bearer " + _config["model_token"]},
    ))


def run(cmd, timeout=5):
    try:
        proc = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return proc.stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return ""


def local_status():
    def build():
        services = []
        for name in SERVICES:
            state = run("systemctl is-active %s" % name, 3) or "unknown"
            services.append({"name": name, "state": state, "ok": state == "active"})

        uptime = run("cat /proc/uptime", 2).split()[0] if run("cat /proc/uptime", 2) else "0"
        try:
            uptime_seconds = int(float(uptime))
        except ValueError:
            uptime_seconds = 0

        interfaces = []
        raw = run("ip -j address", 3)
        try:
            for link in json.loads(raw or "[]"):
                addresses = [
                    a.get("local", "")
                    for a in (link.get("addr_info") or [])
                    if a.get("family") == "inet"
                ]
                flags = link.get("flags") or []
                interfaces.append({
                    "name": link.get("ifname", ""),
                    "state": "UP" if "UP" in flags else link.get("operstate", ""),
                    "operstate": link.get("operstate", ""),
                    "addresses": addresses,
                })
        except ValueError:
            pass

        ap_clients = 0
        ap = _config["ap_interface"]
        if ap:
            dump = run("iw dev %s station dump" % ap, 3)
            ap_clients = len(re.findall(r"^Station\s", dump, re.MULTILINE))

        disks = []
        for path in _config["storage_paths"]:
            if os.path.isdir(path):
                try:
                    usage = shutil.disk_usage(path)
                    disks.append({
                        "path": path,
                        "total": usage.total,
                        "used": usage.used,
                        "free": usage.free,
                        "percent": round(usage.used * 100.0 / usage.total, 1),
                    })
                except OSError:
                    continue

        imaging_path = _config["imaging_path"]
        imaging_files = []
        if os.path.isdir(imaging_path):
            try:
                imaging_files = sorted(os.listdir(imaging_path))[:200]
            except OSError:
                imaging_files = []

        return {
            "server": {
                "hostname": run("hostname", 2),
                "uptime_seconds": uptime_seconds,
                "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            },
            "services": services,
            "network": {
                "interfaces": interfaces,
                "ap_interface": ap,
                "ap_clients": ap_clients,
                "imaging_nic": _config["imaging_nic"],
            },
            "storage": {"disks": disks, "imaging_files": imaging_files},
        }

    return cached("local", 4, build)


def doctor_checks():
    def build():
        checks = []

        def add(name, ok, detail):
            checks.append({"name": name, "ok": bool(ok), "detail": str(detail)})

        add("FOG API tokens", fog_configured(),
            "present" if fog_configured() else "missing in /etc/jog/fog-api.env")
        add("Model API token", bool(_config["model_token"]),
            "present" if _config["model_token"] else "missing in /etc/jog/model-api.env")
        for path in ("/var/www/html/fog/api/index.php", "/tftpboot", _config["imaging_path"]):
            add("Path " + path, os.path.exists(path), path)

        required = ["jog-imaging-api.service", "jog-model-api.service",
                    "apache2.service", "mariadb.service"]
        for name in required:
            state = run("systemctl is-active %s" % name, 3)
            add("Service " + name, state == "active", state or "unknown")

        nic = _config["imaging_nic"]
        if nic:
            addr = run("ip -4 addr show %s" % nic, 3)
            bridge = ""
            bridge_path = "/sys/class/net/%s/brport/bridge" % nic
            if os.path.exists(bridge_path):
                try:
                    bridge = os.path.basename(os.path.realpath(bridge_path))
                except OSError:
                    bridge = ""
            bridge_addr = ""
            if bridge and bridge != nic:
                bridge_addr = run("ip -4 addr show %s" % bridge, 3)
            ok = bool(addr or bridge_addr)
            detail = "addressed" if addr else ("bridged via %s" % bridge if bridge_addr else "no address")
            add("Imaging NIC " + nic, ok, detail)

        for disk in local_status()["storage"]["disks"]:
            add("Disk space " + disk["path"], disk["percent"] < 90,
                "%.1f%% used" % disk["percent"])
        return {"checks": checks, "ok": all(c["ok"] for c in checks)}

    return cached("doctor", 10, build)


def fog_summary():
    def build():
        if not fog_configured():
            return {"configured": False, "hosts": 0, "images": 0,
                    "error": "FOG API tokens not configured"}
        out = {"configured": True, "hosts": 0, "images": 0, "active_tasks": 0}
        for key, kind in (("hosts", "host"), ("images", "image")):
            try:
                result = fog_request("/%s?perPage=1" % kind)
                count = 0
                if isinstance(result, dict):
                    for count_key in ("recordsTotal", "recordsFiltered", "count"):
                        try:
                            count = int(result.get(count_key, 0))
                            break
                        except (TypeError, ValueError):
                            continue
                    else:
                        count = len(result.get("data") or [])
                out[key] = count
            except ApiError as exc:
                out["error"] = str(exc)
        try:
            imaging = get_imaging()
            out["active_tasks"] = sum((imaging.get("summary") or {}).values())
        except ApiError:
            pass
        return out

    return cached("fog", 8, build)


def audit_log():
    def build():
        if not fog_configured():
            return {"ok": False, "entries": [], "error": "FOG API tokens not configured"}
        try:
            entries = fog_list("tasklog", 25)
        except ApiError as exc:
            return {"ok": False, "entries": [], "error": str(exc)}
        out = []
        for item in entries[:25]:
            if not isinstance(item, dict):
                continue
            out.append({
                "id": item.get("id", ""),
                "host": item.get("taskHostName", item.get("hostName", "")),
                "image": item.get("taskImageName", item.get("imageName", "")),
                "result": item.get("taskResult", item.get("result", "")),
                "time": item.get("taskTime", item.get("createdTime", "")),
                "user": item.get("taskUser", item.get("username", "")),
            })
        return {"ok": True, "entries": out}

    return cached("audit", 15, build)


def mobile_url():
    bind = _config["bind"]
    if bind in ("", "0.0.0.0", "*"):
        bind = "10.42.0.1"
    return "https://%s:%d" % (bind, _config["port"])


def cert_pin():
    cert = _config["tls_cert"]
    try:
        pubkey = subprocess.run(
            ["openssl", "x509", "-in", cert, "-pubkey", "-noout"],
            check=True, capture_output=True
        ).stdout
        der = subprocess.run(
            ["openssl", "pkey", "-pubin", "-outform", "DER"],
            input=pubkey, check=True, capture_output=True
        ).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        raise ApiError("could not derive certificate pin: %s" % exc, 500) from exc
    return base64.b64encode(hashlib.sha256(der).digest()).decode("ascii")


def qr_png(link):
    if not shutil.which("qrencode"):
        raise ApiError("qrencode is not installed on the appliance", 500)
    try:
        proc = subprocess.run(
            ["qrencode", "-s", "6", "-m", "2", "-o", "-", link],
            capture_output=True, timeout=10
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ApiError("QR generation failed: %s" % exc, 500) from exc
    if proc.returncode != 0:
        raise ApiError("QR generation failed: %s" % proc.stderr.decode("utf-8", "replace"), 500)
    return base64.b64encode(proc.stdout).decode("ascii")


def agent_qr_response(agent):
    payload = {
        "v": 1,
        "url": mobile_url(),
        "token": agent["bootstrapToken"],
        "pin": cert_pin(),
        "bootstrap": True,
        "agentId": agent["agentId"],
    }
    if _config["wifi_ssid"]:
        payload["ssid"] = _config["wifi_ssid"]
    if agent.get("bootstrapPassphrase"):
        payload["psk"] = agent["bootstrapPassphrase"]
    elif _config["wifi_psk"]:
        payload["psk"] = _config["wifi_psk"]
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    link = "jogemetry://connect/?d=" + base64.urlsafe_b64encode(
        raw.encode("utf-8")
    ).decode("ascii").rstrip("=")
    return {
        "ok": True,
        "agent": {
            "agentId": agent["agentId"],
            "label": agent["label"],
            "role": agent["role"],
            "expiresAt": agent["expiresAt"],
        },
        "link": link,
        "qrPng": qr_png(link),
    }


def monitor():
    alerts = []
    appliance = {}
    try:
        appliance = cached(
            "appliance-overview", 5,
            lambda: http_json(_config["imaging_url"] + "/api/overview"),
        )
    except ApiError as exc:
        alerts.append("Appliance overview: %s" % exc)
        appliance = {"error": str(exc)}

    vm = {}
    try:
        vm = cached(
            "appliance-vms", 5,
            lambda: http_json(_config["imaging_url"] + "/api/vm/view"),
        )
    except ApiError:
        vm = {"ok": False, "vms": [], "isos": []}

    doctor_path = "/usr/local/sbin/jog-doctor.sh"
    if os.path.exists(doctor_path):
        try:
            proc = subprocess.run(
                [doctor_path], capture_output=True, text=True, timeout=20
            )
            checks = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
            jos = {"ok": proc.returncode == 0, "checks": checks}
        except (OSError, subprocess.SubprocessError) as exc:
            jos = {"ok": False, "checks": ["jog-doctor failed: %s" % exc]}
    else:
        jos = {"ok": False, "checks": ["jog-doctor.sh is missing"]}
    if not jos["ok"]:
        alerts.append("JOS boot chain: doctor check failed")

    safety = appliance.get("safety") or {}
    if safety and safety.get("state") not in (None, "safe"):
        alerts.append("Imaging safety is %s" % safety.get("state"))
    fog_api = appliance.get("fogApi") or {}
    if fog_api and not fog_api.get("configured"):
        alerts.append("FOG API is not configured")

    raw_services = appliance.get("services") or local_status()["services"]
    if isinstance(raw_services, dict):
        services = [
            {"name": name, "state": state, "ok": state == "active"}
            for name, state in raw_services.items()
        ]
    else:
        services = raw_services
    for service in services:
        if service.get("state") != "active":
            alerts.append("%s is %s" % (service.get("name"), service.get("state")))

    storage = appliance.get("storage") or local_status()["storage"]
    for disk in storage.get("disks", []):
        if disk.get("percent", 0) >= 90:
            alerts.append("%s is %.1f%% full" % (disk.get("path"), disk.get("percent")))

    tutorial_path = _config["tutorial_path"]
    try:
        with open(tutorial_path, encoding="utf-8") as handle:
            page = handle.read()
        chapter_count = len(set(re.findall(r'data-chapter="([^"]+)"', page)))
        tutorial = {
            "available": 'data-panel="tutorial"' in page,
            "chapters": chapter_count,
        }
        if not tutorial["available"]:
            alerts.append("Portal tutorial is missing")
    except OSError:
        tutorial = {"available": False, "chapters": 0}
        alerts.append("Portal tutorial is unavailable")

    return {
        "ok": not alerts,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "safety": safety,
        "fogApi": fog_api,
        "services": services,
        "network": appliance.get("network") or local_status()["network"],
        "storage": storage,
        "vm": vm,
        "jos": jos,
        "tutorial": tutorial,
        "alerts": alerts,
    }


def overview():
    result = {"ok": True, "generated": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    result.update(local_status())
    for name, producer in (("imaging", get_imaging), ("models", get_models),
                           ("fog", fog_summary), ("audit", audit_log),
                           ("doctor", doctor_checks)):
        try:
            result[name] = producer()
        except ApiError as exc:
            result[name] = {"ok": False, "error": str(exc)}
    result["capabilities"] = {
        "deploy": fog_configured(), "capture": fog_configured(),
        "wakeup": fog_configured(), "cancel": fog_configured(),
    }
    return result


def create_task(body):
    host_id = body.get("hostId")
    kind = body.get("taskType", "deploy")
    if not str(host_id).isdigit():
        raise ApiError("hostId must be an integer", 400)
    if kind not in TASK_TYPES:
        raise ApiError("unknown taskType: %s" % kind, 400)
    payload = {
        "taskTypeID": TASK_TYPES[kind],
        "shutdown": bool(body.get("shutdown", False)),
        "debug": bool(body.get("debug", False)),
        "wol": bool(body.get("wol", True)),
        "taskName": "HAAR mobile",
    }
    response = fog_request("/host/%s/task" % host_id, "POST", payload)
    _config["action_log"]("create_task host=%s type=%s" % (host_id, kind))
    return {"ok": True, "action": "create_task", "hostId": host_id,
            "taskType": kind, "upstream": response}


def multicast_status():
    return vm_local_json("/api/fog/multicast/status")


def _vm_names(value):
    if value is None:
        return []
    names = [value] if isinstance(value, str) else list(value)
    return [_vm_name(name) for name in names]


def multicast_launch(body):
    if not isinstance(body, dict):
        raise ApiError("JSON object required", 400)
    host_id = str(body.get("hostId", "") or "")
    image_id = str(body.get("imageId", "") or "")
    if not host_id.isdigit() or not image_id.isdigit():
        raise ApiError("hostId and imageId must be integers", 400)
    payload = {
        "hostId": host_id,
        "imageId": image_id,
        "vmNames": _vm_names(body.get("vmNames")),
        "sessionName": str(body.get("sessionName", "") or "HAAR-LIVE"),
        "port": str(body.get("port", "63100") or "63100"),
        "clients": str(body.get("clients", "1") or "1"),
        "start": _boolish(body.get("start", True), "start"),
    }
    result = vm_local_json("/api/fog/multicast/launch-local", "POST", payload)
    _config["action_log"]("multicast_launch host=%s image=%s" % (host_id, image_id))
    return result


def multicast_stop(body):
    if not isinstance(body, dict):
        raise ApiError("JSON object required", 400)
    payload = {"vmNames": _vm_names(body.get("vmNames"))}
    if body.get("sessionId"):
        payload["sessionId"] = str(body["sessionId"])
    result = vm_local_json("/api/fog/multicast/stop-local", "POST", payload)
    _config["action_log"]("multicast_stop")
    return result


def cancel_task(task_id):
    if not str(task_id).isdigit():
        raise ApiError("task id must be an integer", 400)
    response = fog_request("/task/%s/cancel" % task_id, "DELETE")
    _config["action_log"]("cancel_task id=%s" % task_id)
    return {"ok": True, "action": "cancel_task", "id": task_id, "upstream": response}


def wake_host(host_id):
    return create_task({"hostId": host_id, "taskType": "wakeup"})


VM_ACTIONS = {
    "start", "shutdown", "force-off", "reboot", "pause", "resume",
    "autostart-on", "autostart-off", "display", "delete", "detach-iso",
    "attach-iso", "clone",
}
VM_SNAPSHOT_ACTIONS = {"list", "create", "revert", "delete"}
VM_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
FOG_NETWORK_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,40}$")
BOOLEAN_TRUE = {"1", "true", "yes", "on"}
BOOLEAN_FALSE = {"0", "false", "no", "off"}


def _vm_name(name):
    name = str(name or "").strip()
    if not name or not VM_NAME_RE.match(name):
        raise ApiError("invalid vm name", 400)
    return name


def _fog_network_name(value):
    name = str(value or "").strip()
    if not FOG_NETWORK_NAME_RE.match(name):
        raise ApiError("invalid network name", 400)
    return name


def _boolish(value, key):
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        token = value.strip().lower()
        if token in BOOLEAN_TRUE:
            return True
        if token in BOOLEAN_FALSE:
            return False
    raise ApiError("%s must be a boolean" % key, 400)


def _vm_int(body, key, minimum, maximum, required=False):
    if key not in body:
        if required:
            raise ApiError("%s is required" % key, 400)
        return None
    value = body.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ApiError("%s must be an integer" % key, 400)
    if value < minimum or value > maximum:
        raise ApiError("%s must be between %d and %d" % (key, minimum, maximum), 400)
    return value


def vm_local_json(path, method="GET", payload=None, query=None):
    url = _config["imaging_url"].rstrip("/") + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with _opener.open(req, timeout=15) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            doc = json.loads(raw) if raw else {}
        except ValueError:
            doc = {}
        message = doc.get("error") or ("Upstream returned HTTP %d" % exc.code)
        status = exc.code if 400 <= exc.code < 600 else 502
        raise ApiError(message, status) from exc
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise ApiError("Upstream unreachable: %s" % exc, 503) from exc
    try:
        return json.loads(raw) if raw else {}
    except ValueError as exc:
        raise ApiError("Upstream returned invalid JSON", 502) from exc


def replicate_status(name=None):
    name = _vm_name(name or "jog-replicator")
    result = vm_local_json("/api/jog/replicate/status", query={"vm": name})
    return {"ok": bool(result.get("ok", True)), "status": result}


def replicate_action(body):
    action = str(body.get("action", "") or "").strip().lower()
    if action not in ("capture", "deploy"):
        raise ApiError("unsupported replication action", 400)
    name = _vm_name(body.get("vm") or "jog-replicator")
    payload = {"action": action, "vm": name}
    for key in ("username", "password"):
        if key in body and body.get(key) is not None:
            payload[key] = str(body.get(key))
    return vm_local_json("/api/jog/replicate", "POST", payload)


def vm_list():
    result = vm_local_json("/api/vm/local/view")
    return {"ok": bool(result.get("ok", True)),
            "vms": result.get("vms", []),
            "isos": result.get("isos", [])}


def vm_detail(name):
    name = _vm_name(name)
    return vm_local_json("/api/vm/local/detail", query={"name": name})


def vm_console(name):
    name = _vm_name(name)
    return vm_local_json("/api/vm/local/console", query={"name": name})


def vm_hardware_get(name):
    name = _vm_name(name)
    return vm_local_json("/api/vm/local/hardware", "GET", query={"name": name})


def vm_hardware_set(name, body):
    name = _vm_name(name)
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    if "patch" not in body or not isinstance(body.get("patch"), dict):
        raise ApiError("patch must be an object", 400)
    payload = {"name": name, "patch": body.get("patch")}
    _config["action_log"]("vm_hardware_set name=%s" % name)
    return vm_local_json("/api/vm/local/hardware", "POST", payload)


def vm_fog_network_ensure(body):
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    name = _vm_name(body.get("name"))
    _config["action_log"]("vm_fog_network_ensure name=%s" % name)
    return vm_local_json("/api/vm/local/fog-network", "POST", {"name": name})


def vm_fog_capture(name, body):
    name = _vm_name(name)
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    payload = {"name": name}
    if "network" in body and body.get("network") is not None:
        payload["network"] = _fog_network_name(body.get("network"))
    if "start" not in body:
        raise ApiError("start is required", 400)
    payload["start"] = _boolish(body.get("start"), "start")
    _config["action_log"]("vm_fog_capture name=%s" % name)
    return vm_local_json("/api/vm/local/fog-capture", "POST", payload)


def vm_action(name, body):
    name = _vm_name(name)
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    action = str(body.get("action", "")).strip()
    if action not in VM_ACTIONS:
        raise ApiError("unknown action: %s" % action, 400)
    payload = {"name": name, "action": action}
    if "iso" in body and body.get("iso") is not None:
        payload["iso"] = str(body.get("iso"))
    if "cloneName" in body and body.get("cloneName") is not None:
        payload["cloneName"] = _vm_name(body.get("cloneName"))
    _config["action_log"]("vm_action name=%s action=%s" % (name, action))
    return vm_local_json("/api/vm/local/action", "POST", payload)


def vm_snapshots(name, method, body=None):
    name = _vm_name(name)
    if method == "GET":
        return vm_local_json("/api/vm/local/snapshot", "POST",
                             {"action": "list", "name": name})
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    action = str(body.get("action", "")).strip()
    if action not in VM_SNAPSHOT_ACTIONS:
        raise ApiError("unknown snapshot action: %s" % action, 400)
    payload = {"action": action, "name": name}
    if "snapshot" in body and body.get("snapshot") is not None:
        snapshot = str(body.get("snapshot")).strip()
        if not snapshot:
            raise ApiError("snapshot must be a non-empty string", 400)
        payload["snapshot"] = snapshot
    _config["action_log"]("vm_snapshot name=%s action=%s" % (name, action))
    return vm_local_json("/api/vm/local/snapshot", "POST", payload)


def vm_resources(name, body):
    name = _vm_name(name)
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    ram = _vm_int(body, "ramMiB", 256, 262144, required=True)
    vcpus = _vm_int(body, "vcpus", 1, 64, required=True)
    disk_gib = _vm_int(body, "diskGiB", 1, 16384, required=False)
    payload = {"name": name, "ramMiB": ram, "vcpus": vcpus}
    if disk_gib is not None:
        payload["diskGiB"] = disk_gib
    _config["action_log"]("vm_resources name=%s" % name)
    return vm_local_json("/api/vm/local/resources", "POST", payload)


def vm_boot_get(name):
    name = _vm_name(name)
    return vm_local_json("/api/vm/local/boot", "GET", query={"name": name})


def vm_boot_set(name, body):
    name = _vm_name(name)
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    device = str(body.get("device", "")).strip()
    if device not in {"hd", "cdrom", "network"}:
        raise ApiError("device must be one of hd, cdrom, network", 400)
    if "menu" not in body or not isinstance(body.get("menu"), bool):
        raise ApiError("menu must be a boolean", 400)
    payload = {"name": name, "device": device, "menu": body.get("menu")}
    _config["action_log"]("vm_boot_set name=%s device=%s menu=%s" % (name, device, payload["menu"]))
    return vm_local_json("/api/vm/local/boot", "POST", payload)


def vm_networks_list():
    return vm_local_json("/api/vm/local/networks", "GET")


def vm_networks_create(body):
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    name = str(body.get("name", "")).strip()
    mode = str(body.get("mode", "")).strip()
    if not name:
        raise ApiError("name is required", 400)
    if not mode:
        raise ApiError("mode is required", 400)
    payload = {"name": name, "mode": mode}
    for key in ("cidr", "dhcpStart", "dhcpEnd", "bridge"):
        if key in body and body.get(key) is not None:
            payload[key] = body.get(key)
    _config["action_log"]("vm_networks_create name=%s mode=%s" % (name, mode))
    return vm_local_json("/api/vm/local/networks", "POST", payload)


def vm_network_action(name, body):
    name = str(name or "").strip()
    if not name:
        raise ApiError("invalid network name", 400)
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    action = str(body.get("action", "")).strip()
    if action not in {"start", "stop", "delete"}:
        raise ApiError("action must be one of start, stop, delete", 400)
    payload = {"name": name, "action": action}
    _config["action_log"]("vm_network_action name=%s action=%s" % (name, action))
    return vm_local_json("/api/vm/local/network", "POST", payload)


def vm_nics_list(name):
    name = _vm_name(name)
    return vm_local_json("/api/vm/local/nics", "GET", query={"name": name})


def vm_nics_action(name, body):
    name = _vm_name(name)
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    action = str(body.get("action", "")).strip()
    if action not in {"add", "remove", "set-model", "set-network", "set-mac"}:
        raise ApiError("action must be one of add, remove, set-model, set-network, set-mac", 400)
    payload = {"name": name, "action": action}
    for key in ("identifier", "target", "nic", "sourceType", "source", "model", "mac", "newMac"):
        if key in body and body.get(key) is not None:
            payload[key] = body.get(key)
    _config["action_log"]("vm_nics_action name=%s action=%s" % (name, action))
    return vm_local_json("/api/vm/local/nics", "POST", payload)


def vm_disks_list(name):
    name = _vm_name(name)
    return vm_local_json("/api/vm/local/disks", "GET", query={"name": name})


def vm_disks_action(name, body):
    name = _vm_name(name)
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    action = str(body.get("action", "")).strip()
    if action not in {"add", "resize", "remove", "attach", "detach", "set-boot"}:
        raise ApiError("action must be one of add, resize, remove, attach, detach, set-boot", 400)
    payload = {"name": name, "action": action}
    for key in ("target", "sizeGiB", "bus", "format", "path", "deleteFile"):
        if key in body and body.get(key) is not None:
            payload[key] = body.get(key)
    _config["action_log"]("vm_disks_action name=%s action=%s" % (name, action))
    return vm_local_json("/api/vm/local/disks", "POST", payload)


def vm_usb_list():
    return vm_local_json("/api/vm/local/usb", "GET")


def vm_usb_action(name, body):
    name = _vm_name(name)
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    action = str(body.get("action", "")).strip()
    if action not in {"attach", "detach"}:
        raise ApiError("action must be one of attach, detach", 400)
    device = str(body.get("device", "")).strip()
    if not device:
        raise ApiError("device is required", 400)
    payload = {"name": name, "action": action, "device": device}
    _config["action_log"]("vm_usb_action name=%s action=%s device=%s" % (name, action, device))
    return vm_local_json("/api/vm/local/usb", "POST", payload)


def vm_create(body):
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    name = _vm_name(body.get("name"))
    ram = _vm_int(body, "ram", 256, 262144, required=True)
    vcpus = _vm_int(body, "vcpus", 1, 64, required=True)
    disk_gb = _vm_int(body, "diskGb", 1, 16384, required=True)
    iso = str(body.get("iso", "")).strip()
    payload = {
        "name": name, "ram": ram, "vcpus": vcpus, "diskGb": disk_gb, "iso": iso,
    }
    for key in ("virtioIso", "diskBus", "network", "networkType", "osType"):
        if key in body and body.get(key) is not None:
            payload[key] = body.get(key)
    for key in ("secureBoot", "tpm"):
        if key in body and body.get(key) is not None:
            payload[key] = bool(body.get(key))
    _config["action_log"]("vm_create name=%s" % name)
    return vm_local_json("/api/vm/local/create", "POST", payload)


def vm_delete(name):
    name = _vm_name(name)
    _config["action_log"]("vm_delete name=%s" % name)
    return vm_local_json("/api/vm/local/delete", "POST", {"name": name})


def enroll_client(body, peer_ip):
    if not isinstance(body, dict):
        raise ApiError("request body must be an object", 400)
    token = body.get("bootstrapToken")
    try:
        mac = _ap_psk_manager.station_for_ip(peer_ip)
        return {"ok": True, **_enrollment_store.redeem(
            token, mac, _ap_psk_manager
        )}
    except EnrollmentError as exc:
        raise ApiError(str(exc), 403) from exc


class Handler(BaseHTTPRequestHandler):
    server_version = "HAARMETRYMobileAPI/1"

    def _send(self, status, document):
        body = json.dumps(document, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _auth_context(self, path=""):
        header = self.headers.get("Authorization", "")
        if not header.lower().startswith("bearer "):
            return None
        token = header[7:].strip()
        if _config["token"] and hmac.compare_digest(token, _config["token"]):
            return {"role": "admin", "kind": "static"}
        agent = _enrollment_store.authorize(token)
        if agent is not None:
            if isinstance(agent, str):
                agent = {"clientId": agent, "role": "admin"}
            agent.setdefault("kind", "agent")
            agent.setdefault("role", "admin")
            return agent
        if path.startswith("/api/v1/agents") or path in (
            "/api/v1/monitor", "/api/v1/overview", "/api/v1/status"
        ):
            agent_id = _enrollment_store.authorize_bootstrap(token)
            if agent_id is not None:
                return {"role": "bootstrap", "kind": "bootstrap", "agentId": agent_id}
        return None

    def _authorized(self, path=""):
        return self._auth_context(path) is not None

    def _role_allows(self, role, method, path):
        if role in ("admin", "bootstrap"):
            return True
        if role in ("monitor", "viewer", "read-only"):
            return method == "GET"
        if role in ("phone", "tablet", "technician", "operator"):
            if method == "GET":
                return True
            # operators can do operational actions, not agent/admin management
            if path.startswith("/api/v1/agents"):
                return False
            return True
        return method == "GET"

    def _body(self, max_bytes=8192):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length < 1 or length > max_bytes:
            raise ApiError("request body size is invalid", 400)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError as exc:
            raise ApiError("invalid JSON body", 400) from exc
        if not isinstance(body, dict):
            raise ApiError("request body must be an object", 400)
        return body

    def _dispatch(self, method):
        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
        if path == "/healthz" and method == "GET":
            return self._send(200, {"ok": True, "service": "jogemetry-mobile-api"})
        if path in ("/api/v1/enroll", "/api/jogemetry/enroll", "/api/wisp/enroll") and method == "POST":
            try:
                body = self._body()
                return self._send(200, enroll_client(body, self.client_address[0]))
            except ApiError as exc:
                return self._send(exc.status, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001 - HTTP boundary must stay alive
                return self._send(500, {"ok": False, "error": str(exc)})
        # Rebrand aliases: /api/jogemetry/* deprecated 301 -> /api/v1/*; /api/jogemetry/*,/api/wisp/* accepted
        if path.startswith('/api/jogemetry/'):
            newp = '/api/v1/' + path[len('/api/jogemetry/'):]
            self.send_response(301); self.send_header('Location', newp); self.send_header('Content-Length','0'); return self.end_headers()
        if path.startswith('/api/jogemetry/'):
            path = '/api/v1/' + path[len('/api/jogemetry/'):]
        if path.startswith('/api/wisp/'):
            path = '/api/v1/' + path[len('/api/wisp/'):]
        if not path.startswith("/api/v1/"):
            return self._send(404, {"ok": False, "error": "not found"})
        auth = self._auth_context(path)
        if not auth:
            return self._send(401, {"ok": False, "error": "unauthorized"})
        role = str(auth.get("role") or "admin")
        if not self._role_allows(role, method, path):
            return self._send(403, {"ok": False, "error": "forbidden for role %s" % role})

        try:
            if method == "GET":
                if path == "/api/v1/overview":
                    return self._send(200, overview())
                if path == "/api/v1/imaging":
                    return self._send(200, get_imaging())
                if path == "/api/v1/models":
                    return self._send(200, get_models())
                if path == "/api/v1/hosts":
                    return self._send(200, {"ok": True, "hosts": fog_list("host")})
                if path == "/api/v1/images":
                    return self._send(200, {"ok": True, "images": fog_list("image")})
                if path == "/api/v1/audit":
                    fog = audit_log()
                    limit = 200
                    try:
                        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                        limit = max(1, min(int((q.get("limit") or ["200"])[0]), 2000))
                    except Exception:
                        pass
                    local = []
                    try:
                        with open(AUDIT_LOG, encoding="utf-8", errors="replace") as f:
                            lines = f.readlines()[-limit:]
                        for line in lines:
                            line=line.strip()
                            if line:
                                try: local.append(json.loads(line))
                                except Exception: pass
                    except OSError:
                        pass
                    return self._send(200, {"ok": True, "fog": fog, "local": local})
                if path == "/api/v1/multicast":
                    return self._send(200, multicast_status())
                if path in ("/api/v1/replicate", "/api/v1/jog/replicate"):
                    query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                    name = (query.get("vm") or ["jog-replicator"])[0]
                    return self._send(200, replicate_status(name))
                if path == "/api/v1/status":
                    return self._send(200, local_status())
                if path == "/api/v1/monitor":
                    return self._send(200, monitor())
                if path == "/api/v1/agents":
                    return self._send(200, {
                        "ok": True,
                        "agents": _enrollment_store.list_agents(),
                    })
                if path == "/api/v1/vms":
                    return self._send(200, vm_list())
                if path == "/api/v1/vm-networks":
                    return self._send(200, vm_networks_list())
                if path == "/api/v1/usb-devices":
                    return self._send(200, vm_usb_list())
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/hardware", path)
                if match:
                    return self._send(
                        200, vm_hardware_get(urllib.parse.unquote(match.group(1)))
                    )
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/boot", path)
                if match:
                    return self._send(200, vm_boot_get(match.group(1)))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/nics", path)
                if match:
                    return self._send(200, vm_nics_list(match.group(1)))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/disks", path)
                if match:
                    return self._send(200, vm_disks_list(match.group(1)))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/console", path)
                if match:
                    return self._send(200, vm_console(match.group(1)))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/snapshots", path)
                if match:
                    return self._send(200, vm_snapshots(match.group(1), "GET"))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)", path)
                if match:
                    return self._send(200, vm_detail(match.group(1)))

            if method == "POST":
                if path == "/api/v1/tasks":
                    result = create_task(self._body())
                    notify("fog.task.create", {"result": result})
                    return self._send(200, result)
                match = re.fullmatch(r"/api/v1/hosts/(\d+)/wake", path)
                if match:
                    result = wake_host(match.group(1))
                    notify("fog.host.wake", {"hostId": match.group(1), "result": result})
                    return self._send(200, result)
                match = re.fullmatch(r"/api/v1/tasks/(\d+)/cancel", path)
                if match:
                    result = cancel_task(match.group(1))
                    notify("fog.task.cancel", {"taskId": match.group(1), "result": result})
                    return self._send(200, result)
                if path == "/api/v1/vms":
                    return self._send(200, vm_create(self._body()))
                if path == "/api/v1/vm-networks":
                    return self._send(200, vm_networks_create(self._body()))
                if path == "/api/v1/vm-networks/fog-ensure":
                    return self._send(200, vm_fog_network_ensure(self._body()))
                match = re.fullmatch(r"/api/v1/vm-networks/([^/]+)", path)
                if match:
                    return self._send(200, vm_network_action(match.group(1), self._body()))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/hardware", path)
                if match:
                    return self._send(
                        200,
                        vm_hardware_set(
                            urllib.parse.unquote(match.group(1)), self._body()
                        ),
                    )
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/boot", path)
                if match:
                    return self._send(200, vm_boot_set(match.group(1), self._body()))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/nics", path)
                if match:
                    return self._send(200, vm_nics_action(match.group(1), self._body()))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/disks", path)
                if match:
                    return self._send(200, vm_disks_action(match.group(1), self._body()))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/usb", path)
                if match:
                    return self._send(200, vm_usb_action(match.group(1), self._body()))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/action", path)
                if match:
                    return self._send(200, vm_action(match.group(1), self._body()))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/snapshots", path)
                if match:
                    return self._send(200, vm_snapshots(match.group(1), "POST", self._body()))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/resources", path)
                if match:
                    return self._send(200, vm_resources(match.group(1), self._body()))
                match = re.fullmatch(r"/api/v1/vms/([^/]+)/fog-capture", path)
                if match:
                    return self._send(
                        200,
                        vm_fog_capture(
                            urllib.parse.unquote(match.group(1)), self._body()
                        ),
                    )
                if path == "/api/v1/multicast/launch":
                    body = self._body()
                    result = multicast_launch(body)
                    notify("multicast.launch", {"body": body, "result": result})
                    return self._send(200, result)
                if path == "/api/v1/multicast/stop":
                    body = self._body()
                    result = multicast_stop(body)
                    notify("multicast.stop", {"body": body, "result": result})
                    return self._send(200, result)
                if path in ("/api/v1/replicate", "/api/v1/jog/replicate"):
                    body = self._body()
                    result = replicate_action(body)
                    notify("replicate", {"action": body.get("action"), "vm": body.get("vm"), "result": result})
                    return self._send(200, result)
                if path == "/api/v1/agents":
                    body = self._body()
                    try:
                        agent = _enrollment_store.issue_agent(
                            body.get("label", ""),
                            body.get("role", "phone"),
                            _config["wifi_ssid"],
                        )
                    except EnrollmentError as exc:
                        raise ApiError(str(exc), 400) from exc
                    try:
                        _ap_psk_manager.install_bootstrap(
                            _config["wifi_ssid"], agent["bootstrapPassphrase"]
                        )
                    except EnrollmentError as exc:
                        raise ApiError(str(exc), 500) from exc
                    return self._send(200, agent_qr_response(agent))
                match = re.fullmatch(r"/api/v1/agents/([0-9a-fA-F-]{36})/qr", path)
                if match:
                    try:
                        agent = _enrollment_store.reissue_agent(
                            match.group(1), _config["wifi_ssid"]
                        )
                    except EnrollmentError as exc:
                        raise ApiError(str(exc), 400) from exc
                    try:
                        _ap_psk_manager.install_bootstrap(
                            _config["wifi_ssid"], agent["bootstrapPassphrase"]
                        )
                    except EnrollmentError as exc:
                        raise ApiError(str(exc), 500) from exc
                    return self._send(200, agent_qr_response(agent))
                match = re.fullmatch(r"/api/v1/agents/([0-9a-fA-F-]{36})/revoke", path)
                if match:
                    try:
                        changed = _enrollment_store.revoke_agent(
                            match.group(1), _ap_psk_manager
                        )
                    except EnrollmentError as exc:
                        raise ApiError(str(exc), 400) from exc
                    return self._send(200, {
                        "ok": True,
                        "action": "revoke_agent",
                        "agentId": match.group(1),
                        "changed": changed,
                    })

            if method == "DELETE":
                match = re.fullmatch(r"/api/v1/vms/([^/]+)", path)
                if match:
                    return self._send(200, vm_delete(match.group(1)))

            return self._send(404, {"ok": False, "error": "not found"})
        except ApiError as exc:
            return self._send(exc.status, {"ok": False, "error": str(exc)})
        except Exception as exc:  # noqa: BLE001 - HTTP boundary must stay alive
            sys.stderr.write("jogemetry-mobile-api: %s\n" % traceback.format_exc())
            return self._send(500, {"ok": False, "error": str(exc)})

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_DELETE(self):
        self._dispatch("DELETE")

    def log_message(self, fmt, *args):
        sys.stderr.write("jogemetry-mobile-api: " + fmt % args + "\n")


def action_log(message):
    sys.stderr.write("jogemetry-mobile-api: ACTION %s %s\n" %
                     (time.strftime("%Y-%m-%dT%H:%M:%S%z"), message))
    sys.stderr.flush()


def main():
    global _config, _enrollment_store, _ap_psk_manager
    env = load_env(ENV_FILE)
    fog_env = load_env(FOG_ENV)
    model_env = load_env(MODEL_ENV)

    runtime_iface = "/run/jog-jogemetry-iface"
    if os.path.exists(runtime_iface):
        detected_iface = open(runtime_iface, encoding="utf-8").read().strip()
        if detected_iface:
            env["JOG_AP_INTERFACE"] = detected_iface

    try:
        derivation_key = bytes.fromhex(env.get("JOG_ENROLLMENT_KEY", ""))
        _enrollment_store = EnrollmentStore(
            env.get("JOG_ENROLLMENT_DB", "/var/lib/jog-ap/enrollment.sqlite3"),
            derivation_key,
        )
        _ap_psk_manager = ApPskManager(
            env.get("JOG_AP_PSK_FILE", "/var/lib/jog-ap/hostapd.psk"),
            env.get("JOG_AP_INTERFACE", "wlxd037450adc29"),
            env.get("JOG_AP_CTRL_DIR", "/run/hostapd"),
        )
    except (EnrollmentError, OSError, ValueError) as exc:
        print("jogemetry-mobile-api: enrollment setup failed: %s" % exc, file=sys.stderr)
        return 1

    cert = env.get("JOG_MOBILE_TLS_CERT", "/etc/jog/mobile-cert.pem")
    key = os.environ.get("JOG_MOBILE_TLS_KEY", os.environ.get("JOG_MOBILE_TLS_KEY")) or env.get(
        "JOG_MOBILE_TLS_KEY", "/etc/jog/mobile-key.pem")
    if not os.path.exists(cert) or not os.path.exists(key):
        print("jogemetry-mobile-api: TLS cert/key missing", file=sys.stderr)
        return 1

    _config = {
        "token": env.get("JOG_MOBILE_TOKEN", ""),
        "bind": env.get("JOG_MOBILE_BIND", "10.42.0.1"),
        "port": int(env.get("JOG_MOBILE_PORT", "8443")),
        "tls_cert": cert,
        "wifi_ssid": env.get("JOG_WIFI_SSID", "HAARMETRY"),
        "wifi_psk": env.get("JOG_WIFI_PSK", ""),
        "tutorial_path": env.get(
            "JOG_TUTORIAL_PATH", "/usr/local/share/jog/imaging/index.html"
        ),
        "imaging_url": env.get("JOG_IMAGING_URL", "http://127.0.0.1:8088"),
        "model_url": env.get("JOG_MODEL_URL", "http://127.0.0.1:8089"),
        "model_token": model_env.get("JOG_MODEL_API_TOKEN", env.get("JOG_MODEL_TOKEN", "")),
        "fog_url": fog_env.get("JOG_FOG_API_URL", "http://localhost/fog"),
        "fog_api_token": fog_env.get("FOG_API_TOKEN", ""),
        "fog_user_token": fog_env.get("FOG_USER_TOKEN", ""),
        "ap_interface": env.get("JOG_AP_INTERFACE", "wlxd037450adc29"),
        "imaging_nic": env.get("JOG_IMAGING_NIC", "enp2s0"),
        "imaging_path": env.get("JOG_IMAGING_PATH", "/images"),
        "storage_paths": [p for p in env.get(
            "JOG_STORAGE_PATHS", "/,/images").split(",") if p],
        "action_log": action_log,
        "webhook_url": env.get("JOG_WEBHOOK_URL", env.get("JOG_DISCORD_WEBHOOK_URL", "")),
    }

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=cert, keyfile=key)
    server = ThreadingHTTPServer((_config["bind"], _config["port"]), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("jogemetry-mobile-api: https://%s:%d" % (_config["bind"], _config["port"]),
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
