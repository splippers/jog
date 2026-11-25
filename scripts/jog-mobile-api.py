#!/usr/bin/env python3
"""JOG mobile companion API.

A small authenticated HTTPS aggregator for the JOG Android app. It runs on the
imaging appliance, reads the existing localhost-only JOG APIs and FOG API with
root-held credentials, and exposes one authenticated JSON endpoint set to the
hidden JOGEMETRY WiFi.

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
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ENV_FILE = os.environ.get("JOG_MOBILE_ENV", "/etc/jog/mobile-api.env")
FOG_ENV = os.environ.get("JOG_FOG_API_ENV", "/etc/jog/fog-api.env")
MODEL_ENV = os.environ.get("JOG_MODEL_API_ENV", "/etc/jog/model-api.env")

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
                interfaces.append({
                    "name": link.get("ifname", ""),
                    "state": link.get("operstate", ""),
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
            add("Imaging NIC " + nic, bool(addr), "addressed" if addr else "no address")

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
                out[key] = result.get("count", 0) if isinstance(result, dict) else 0
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
        "taskName": "JOG mobile",
    }
    response = fog_request("/host/%s/task" % host_id, "POST", payload)
    _config["action_log"]("create_task host=%s type=%s" % (host_id, kind))
    return {"ok": True, "action": "create_task", "hostId": host_id,
            "taskType": kind, "upstream": response}


def cancel_task(task_id):
    if not str(task_id).isdigit():
        raise ApiError("task id must be an integer", 400)
    response = fog_request("/task/%s/cancel" % task_id, "DELETE")
    _config["action_log"]("cancel_task id=%s" % task_id)
    return {"ok": True, "action": "cancel_task", "id": task_id, "upstream": response}


def wake_host(host_id):
    return create_task({"hostId": host_id, "taskType": "wakeup"})


class Handler(BaseHTTPRequestHandler):
    server_version = "JOGMobileAPI/1"

    def _send(self, status, document):
        body = json.dumps(document, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        header = self.headers.get("Authorization", "")
        if not header.lower().startswith("bearer "):
            return False
        return hmac.compare_digest(header[7:].strip(), _config["token"])

    def _dispatch(self, method):
        path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"
        if path == "/healthz" and method == "GET":
            return self._send(200, {"ok": True, "service": "jog-mobile-api"})
        if not path.startswith("/api/v1/"):
            return self._send(404, {"ok": False, "error": "not found"})
        if not self._authorized():
            return self._send(401, {"ok": False, "error": "unauthorized"})

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
                    return self._send(200, audit_log())
                if path == "/api/v1/status":
                    return self._send(200, local_status())

            if method == "POST":
                if path == "/api/v1/tasks":
                    length = int(self.headers.get("Content-Length", "0") or 0)
                    try:
                        body = json.loads(self.rfile.read(length) or b"{}")
                    except ValueError:
                        raise ApiError("invalid JSON body", 400)
                    return self._send(200, create_task(body))
                match = re.fullmatch(r"/api/v1/hosts/(\d+)/wake", path)
                if match:
                    return self._send(200, wake_host(match.group(1)))
                match = re.fullmatch(r"/api/v1/tasks/(\d+)/cancel", path)
                if match:
                    return self._send(200, cancel_task(match.group(1)))

            return self._send(404, {"ok": False, "error": "not found"})
        except ApiError as exc:
            return self._send(exc.status, {"ok": False, "error": str(exc)})
        except Exception as exc:  # noqa: BLE001 - HTTP boundary must stay alive
            return self._send(500, {"ok": False, "error": str(exc)})

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def log_message(self, fmt, *args):
        sys.stderr.write("jog-mobile-api: " + fmt % args + "\n")


def action_log(message):
    sys.stderr.write("jog-mobile-api: ACTION %s %s\n" %
                     (time.strftime("%Y-%m-%dT%H:%M:%S%z"), message))
    sys.stderr.flush()


def main():
    global _config
    env = load_env(ENV_FILE)
    fog_env = load_env(FOG_ENV)
    model_env = load_env(MODEL_ENV)

    token = env.get("JOG_MOBILE_TOKEN", "")
    if not token:
        print("jog-mobile-api: JOG_MOBILE_TOKEN is empty", file=sys.stderr)
        return 1

    cert = env.get("JOG_MOBILE_TLS_CERT", "/etc/jog/mobile-cert.pem")
    key = os.environ.get("JOG_MOBILE_TLS_KEY") or env.get(
        "JOG_MOBILE_TLS_KEY", "/etc/jog/mobile-key.pem")
    if not os.path.exists(cert) or not os.path.exists(key):
        print("jog-mobile-api: TLS cert/key missing", file=sys.stderr)
        return 1

    _config = {
        "token": token,
        "bind": env.get("JOG_MOBILE_BIND", "10.42.0.1"),
        "port": int(env.get("JOG_MOBILE_PORT", "8443")),
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
    }

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=cert, keyfile=key)
    server = ThreadingHTTPServer((_config["bind"], _config["port"]), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print("jog-mobile-api: https://%s:%d" % (_config["bind"], _config["port"]),
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
