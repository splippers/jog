#!/usr/bin/env python3
import argparse
import ipaddress
import json
import math
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ENV_FILE = os.environ.get("JOG_FOG_API_ENV", os.environ.get("JOG_FOG_API_ENV", "/etc/jog/fog-api.env" if os.path.exists("/etc/jog/fog-api.env") else "/etc/jog/fog-api.env"))
JOG_ENV_FILE = os.environ.get("JOG_ENV_FILE", os.environ.get("JOG_ENV_FILE", "/etc/jog/jog.env" if os.path.exists("/etc/jog/jog.env") else "/etc/jog/jog.env"))
STATIC = os.environ.get("JOG_IMAGING_STATIC", os.environ.get("JOG_IMAGING_STATIC", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kiosk", "imaging")))
HELPER = os.environ.get("JOG_PORTAL_HELPER", os.environ.get("JOG_PORTAL_HELPER", "/usr/local/sbin/jog-portal-network.sh" if os.path.exists("/usr/local/sbin/jog-portal-network.sh") else "/usr/local/sbin/jog-portal-network.sh"))
BUILD_STATUS_FILE = os.environ.get("JOG_REPLICATOR_BUILD_STATUS", os.environ.get("JOG_REPLICATOR_BUILD_STATUS", "/var/www/html/jog-replicator-build.status" if os.path.exists("/var/www/html/jog-replicator-build.status") else "/var/www/html/jog-replicator-build.status"))

VM_NAME_RE = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{0,63}")
SNAPSHOT_RE = re.compile(r"[A-Za-z0-9_.-]{1,63}")
VM_ACTIONS = {
    "start", "shutdown", "force-off", "forceoff", "destroy", "reboot",
    "pause", "suspend", "resume", "autostart-on", "autostart-off",
    "detach-iso", "attach-iso", "clone", "display", "delete",
}
SNAPSHOT_ACTIONS = {"list", "create", "revert", "restore", "delete"}
VM_ISO_ROOTS = ("/var/lib/libvirt/isos", "/opt/jog/isos", "/srv/isos", "/home/jog/jog-iso-staging")
LOCAL_HOSTS = ("127.0.0.1", "::1", "::ffff:127.0.0.1")


class ApiError(Exception):
    def __init__(self, message, status=502):
        super().__init__(message)
        self.status = status


def load_env(path):
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    out[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


_WEBHOOK_ENV = None


def _webhook_url():
    global _WEBHOOK_ENV
    if _WEBHOOK_ENV is None:
        env = load_env(JOG_ENV_FILE)
        env.update({k: v for k, v in os.environ.items() if k.startswith("JOG_") or k.startswith("JOG_")})
        _WEBHOOK_ENV = env
    return (_WEBHOOK_ENV.get("JOG_WEBHOOK_URL") or _WEBHOOK_ENV.get("JOG_DISCORD_WEBHOOK_URL") or _WEBHOOK_ENV.get("JOG_WEBHOOK_URL") or _WEBHOOK_ENV.get("JOG_DISCORD_WEBHOOK_URL") or "").strip()


AUDIT_LOG = os.environ.get("JOG_AUDIT_LOG", os.environ.get("JOG_AUDIT_LOG", "/var/log/jog/audit.jsonl" if os.path.isdir("/var/log/jog") else "/var/log/jog/audit.jsonl"))


def audit_write(event, detail=None, ok=True):
    detail = detail or {}
    entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event, "ok": bool(ok), "detail": detail, "source": "jog-imaging-api"}
    try:
        os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
        with open(AUDIT_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write("jog-imaging-api: audit write failed: %s\n" % exc)


def preflight(kind, vm=None, host_id=None, image_id=None):
    checks = []
    def add(name, ok, detail, fix=""):
        checks.append({"name": name, "ok": bool(ok), "detail": detail, "fix": fix})
    # services
    for svc in ("dnsmasq.service", "jog-imaging-api.service", "jog-mobile-api.service", "jog-jogemetry-dnsmasq.service"):
        r = subprocess.run(["systemctl", "is-active", svc], capture_output=True, text=True)
        st = r.stdout.strip() or r.stderr.strip() or "unknown"
        # dnsmasq may be inactive when imaging nic down; report but don't hard fail if alt exists
        ok = st == "active"
        add(f"service:{svc}", ok, st, f"sudo systemctl restart {svc}")
    # DHCP safety
    try:
        env = load_env(JOG_ENV_FILE)
        nic = env.get("JOG_IMAGING_NIC", env.get("JOG_IMAGING_NIC", "enx34298f79151f"))
        conf = "/etc/dnsmasq.d/99-jog-imaging.conf"
        txt = open(conf, encoding="utf-8", errors="replace").read() if os.path.exists(conf) else ""
        ok = f"interface={nic}" in txt and "dhcp-range=" in txt
        add("dhcp:scoped", ok, f"interface={nic}", "sudo jog-render-dnsmasq.sh && sudo systemctl restart dnsmasq")
    except Exception as e:
        add("dhcp:scoped", False, str(e))
    # TFTP/UEFI
    for p in ("/tftpboot/ipxe.pxe", "/tftpboot/ubuntu-signed/shimx64.efi", "/tftpboot/grub/grub.cfg"):
        add(f"boot:{os.path.basename(p)}", os.path.exists(p), p, "Reinstall HAAR imaging boot files")
    # FOG
    try:
        fog = fog_request("GET", "/system/info")
        add("fog:api", True, "reachable")
    except Exception as e:
        add("fog:api", False, str(e), "Check /etc/jog/fog-api.env (or /etc/jog/fog-api.env compat) and FOG service")
    # VM checks
    if vm:
        r = subprocess.run(["virsh", "dominfo", vm], capture_output=True, text=True)
        add(f"vm:{vm}", r.returncode == 0, "present" if r.returncode==0 else r.stderr.strip()[:200], "Create/select VM")
        if r.returncode == 0:
            macs = re.findall(r"<mac\s+address=['\"]([^'\"]+)['\"]", subprocess.run(["virsh","dumpxml","--domain",vm],capture_output=True,text=True).stdout, re.I)
            add(f"vm:{vm}:mac", bool(macs), ",".join(macs) or "no mac", "Add NIC to VM")
    if host_id:
        try:
            row = fog_request("GET", f"/host/{host_id}")
            ok = bool(row)
            add(f"fog:host:{host_id}", ok, "found" if ok else "missing")
        except Exception as e:
            add(f"fog:host:{host_id}", False, str(e))
    if image_id:
        try:
            row = fog_request("GET", f"/image/{image_id}")
            ok = bool(row)
            add(f"fog:image:{image_id}", ok, "found" if ok else "missing")
        except Exception as e:
            add(f"fog:image:{image_id}", False, str(e))
    # disk space
    try:
        st = os.statvfs("/images") if os.path.exists("/images") else os.statvfs("/")
        free_gib = (st.f_bavail * st.f_frsize) / (1024**3)
        add("storage:/images", free_gib > 10, f"{free_gib:.1f} GiB free", "Free disk space on /images")
    except Exception as e:
        add("storage:/images", False, str(e))
    ok = all(c["ok"] for c in checks)
    return {"ok": ok, "kind": kind, "checks": checks}


def notify(event, detail=None, ok=True):
    url = _webhook_url()
    detail = detail or {}
    audit_write(event, detail, ok)
    sys.stderr.write("jog-imaging-api: ACTION %s %s\n" % (event, json.dumps(detail, ensure_ascii=False)[:400]))
    sys.stderr.flush()
    if not url:
        return
    def send():
        payload = {"event": event, "ok": bool(ok), "detail": detail, "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "source": "jog-imaging-api"}
        body = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json", "Accept": "application/json", "User-Agent": "HAAR-Webhook/1"}
        if "discord.com/api/webhooks" in url or "discordapp.com/api/webhooks" in url:
            body = json.dumps({"content": ("[%s] %s %s" % ("OK" if ok else "FAIL", event, json.dumps(detail, ensure_ascii=False)[:1500]))[:1900]}).encode("utf-8")
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=8) as resp:
                resp.read(256)
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write("jog-imaging-api: webhook failed: %s\n" % exc)
    threading.Thread(target=send, daemon=True).start()


def pick(d, *keys, default=None):
    for k in keys:
        v = d.get(k) if isinstance(d, dict) else None
        if v not in (None, ""):
            return v
    return default


def num(v, default=0.0):
    try:
        return float(str(v).strip().rstrip("%"))
    except (TypeError, ValueError):
        return default


TASK_STATE_LABELS = {
    "1": "Queued",
    "2": "Checked In",
    "3": "In-Progress",
    "4": "Complete",
    "5": "Cancelled",
    "6": "Failed",
}

TASK_TYPE_LABELS = {
    "1": "Deploy",
    "2": "Capture",
    "8": "Multi-Cast",
    "12": "All Snapins",
    "14": "Wake-Up",
}

MULTICAST_STATE_LABELS = {
    "0": "Disabled",
    "1": "Queued",
    "2": "Checked In",
    "3": "In Progress",
    "4": "Complete",
    "5": "Failed",
}


def phase_of(state_name):
    s = (state_name or "").lower()
    if "progress" in s or "imaging" in s:
        return "imaging"
    if "queue" in s or "check" in s or "pending" in s:
        return "queued"
    if "complete" in s or "success" in s:
        return "complete"
    if "cancel" in s or "fail" in s or "error" in s:
        return "failed"
    return "queued"


def friendly_task_host(t, host):
    name = pick(host, "name", default=pick(t, "hostName", default=""))
    if name:
        return name
    raw = str(pick(t, "name", default="") or "").strip()
    name = re.sub(r"^\s*-\s*", "", raw)
    name = re.sub(r"\s+\d{4}-\d{2}-\d{2}.*$", "", name).strip()
    return name or raw or "unknown host"


def normalize_task(t):
    host = t.get("host") if isinstance(t.get("host"), dict) else {}
    image = t.get("image") if isinstance(t.get("image"), dict) else {}
    ttype = t.get("type") if isinstance(t.get("type"), dict) else {}
    state = t.get("state") if isinstance(t.get("state"), dict) else {}
    state_raw = str(pick(state, "name", "id", default=pick(t, "stateName", "stateID", default="")) or "").strip()
    type_raw = str(pick(ttype, "name", "id", default=pick(t, "typeName", "typeID", default="")) or "").strip()
    state_name = TASK_STATE_LABELS.get(state_raw, state_raw) or "Unknown"
    type_name = TASK_TYPE_LABELS.get(type_raw, type_raw) or "Task"
    phase = phase_of(state_name)
    return {
        "id": pick(t, "id", "taskID"),
        "host": friendly_task_host(t, host),
        "mac": pick(host, "primac", "mac", default=pick(t, "mac", default="")),
        "image": pick(image, "name", default=pick(t, "imageName", default="")),
        "kind": type_name,
        "state": state_name,
        "phase": phase,
        "canCancel": phase in ("queued", "imaging"),
        "percent": max(0.0, min(100.0, num(pick(t, "percent", "pct", "taskPercent", "percentText", default=0)))),
        "rate": str(pick(t, "bpm", "rate", "taskBPM", default="")),
        "elapsed": str(pick(t, "timeElapsed", "elapsed", default="")),
        "remaining": str(pick(t, "timeRemaining", "remaining", default="")),
        "copied": str(pick(t, "dataCopied", "copied", default="")),
        "total": str(pick(t, "dataTotal", "total", default="")),
        "started": pick(t, "createdTime", "checkInTime", "createTime", default=""),
    }


def summarize(devices):
    s = {"queued": 0, "imaging": 0, "complete": 0, "failed": 0}
    for d in devices:
        s[d["phase"]] = s.get(d["phase"], 0) + 1
    return s


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def fog_settings():
    env = load_env(ENV_FILE)
    base = env.get("JOG_FOG_API_URL", "http://localhost/fog").rstrip("/")
    return base, env.get("FOG_API_TOKEN", ""), env.get("FOG_USER_TOKEN", "")


def fog_request(method, path, payload=None, params=None):
    base, api, user = fog_settings()
    if not api or not user:
        raise ApiError("FOG API tokens are not configured (%s)" % ENV_FILE, 503)
    headers = {"fog-api-token": api, "fog-user-token": user, "Accept": "application/json"}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    url = base + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with _opener.open(req, timeout=8) as r:
            text = r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        if 300 <= e.code < 400:
            raise ApiError("FOG rejected the API tokens or the API is disabled (Settings > API System)", 502)
        raise ApiError("FOG API returned HTTP %d: %s" % (e.code, detail), 502)
    except (urllib.error.URLError, OSError) as e:
        raise ApiError("FOG API unreachable: %s" % e, 502)
    if not text.strip():
        return {"ok": True}
    try:
        return json.loads(text)
    except ValueError:
        return {"ok": True, "raw": text[:2000]}


def fog_rows(resp, *keys):
    if isinstance(resp, list):
        return resp
    if isinstance(resp, dict):
        for k in keys:
            v = resp.get(k)
            if isinstance(v, list):
                return v
        data = resp.get("data")
        if isinstance(data, list):
            return data
        if isinstance(data, dict):
            for k in keys:
                v = data.get(k)
                if isinstance(v, list):
                    return v
    return []


def extract_id(obj):
    if isinstance(obj, dict):
        for k in ("id", "ID", "taskID", "insertID", "hostID", "imageID"):
            v = obj.get(k)
            if v not in (None, "", 0, "0"):
                return str(v)
        for v in obj.values():
            found = extract_id(v)
            if found:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = extract_id(v)
            if found:
                return found
    return None


def normalize_host(h):
    return {
        "id": pick(h, "id", "hostID"),
        "name": pick(h, "name", "hostName", default="unnamed"),
        "mac": pick(h, "primac", "mac", default=""),
        "description": pick(h, "description", default=""),
        "image": pick(h, "image", "imageName", default=""),
        "task": pick(h, "task", "taskName", default=""),
    }


def normalize_image(i):
    return {
        "id": pick(i, "id", "imageID"),
        "name": pick(i, "name", "imageName", default="unnamed"),
        "path": pick(i, "path", default=""),
        "format": pick(i, "format", default=""),
        "size": pick(i, "size", default=""),
        "enabled": pick(i, "isEnabled", "enabled", default=""),
    }


def normalize_session(s):
    state_raw = str(pick(s, "state", "stateID", default="") or "").strip()
    return {
        "id": pick(s, "id", "sessionID", "msID"),
        "name": pick(s, "name", default="unnamed"),
        "image": pick(s, "image", "imageName", default=""),
        "clients": pick(s, "sessclients", "clients", default=""),
        "port": pick(s, "port", default=""),
        "state": MULTICAST_STATE_LABELS.get(state_raw, state_raw) or "Unknown",
        "stateId": state_raw,
        "percent": max(0.0, min(100.0, num(pick(s, "percent", default=0)))),
        "logpath": pick(s, "logpath", default=""),
        "interface": pick(s, "interface", default=""),
        "started": pick(s, "starttime", default=""),
        "completed": pick(s, "completetime", default=""),
        "senderPid": pick(s, "senderpid", default=""),
    }


def fog_image_path(image_id):
    for image in fog_rows(fog_request("GET", "/image/list"), "images"):
        if str(pick(image, "id")) == str(image_id):
            return str(pick(image, "path", default=pick(image, "name", default="")) or "")
    return ""


def fog_session_payload(image_id, body):
    payload = {
        "name": str(body.get("name", "") or body.get("sessionName", "") or "HAAR multicast"),
        "port": str(body.get("port", "63100") or "63100"),
        "clients": "-2",
        "sessclients": str(body.get("clients", "1") or "1"),
        "interface": str(body.get("interface", "br-fog") or "br-fog"),
        "isDD": "1",
        "state": str(body.get("state", "1") or "1"),
        "stateID": str(body.get("state", "1") or "1"),
        "image": str(image_id),
        "logpath": str(body.get("logpath", "") or fog_image_path(image_id)),
        "maxwait": str(body.get("maxwait", "180") or "180"),
        "storagegroupID": str(body.get("storagegroupID", "1") or "1"),
    }
    if not payload["logpath"]:
        raise ApiError("Could not resolve FOG image path", 502)
    return payload


def fetch_live():
    resp = fog_request("GET", "/task/active")
    tasks = fog_rows(resp, "tasks", "data")
    devices = [normalize_task(t) for t in tasks if isinstance(t, dict)]
    return {"ok": True, "devices": devices}


_start = time.time()
_DEMO = [
    ("LT-SITE01-ABC1234", "Win11 Standard", "Deploy", 1.00, 0),
    ("LT-SITE01-ABD2211", "Win11 Standard", "Deploy", 0.80, 20),
    ("DT-SITE01-XYZ5678", "Win11 Engineering", "Deploy", 0.55, 90),
    ("LT-SITE01-QRS9001", "Win11 Standard", "Deploy", 0.90, 150),
    ("LT-SITE01-MNO4410", "Win11 Standard", "Deploy", 0.70, 260),
    ("LT-SITE01-JKL1032", "Win11 Engineering", "Multicast", 1.20, 500),
    ("DT-SITE01-TUV7714", "Win11 Engineering", "Deploy", 0.60, 900),
]
_DEMO_HOSTS = [
    {"id": 1, "name": "LT-SITE01-ABC1234", "mac": "00:1b:44:11:3a:b7", "description": "Demo host", "image": "Win11 Standard"},
    {"id": 2, "name": "DT-SITE01-XYZ5678", "mac": "00:1b:44:11:3a:b8", "description": "Demo host", "image": "Win11 Engineering"},
]
_DEMO_IMAGES = [
    {"id": 5, "name": "Win11 Standard", "path": "Win11-NOV26", "format": "5", "size": "38 GB", "enabled": "1"},
    {"id": 6, "name": "Win11 Engineering", "path": "Win11-ENG-NOV26", "format": "5", "size": "42 GB", "enabled": "1"},
]
_DEMO_SESSIONS = [
    {"id": 9, "name": "room-a-Win11 Standard", "image": "Win11 Standard", "clients": "-2", "port": "9300", "state": "3"},
]


def fetch_demo():
    t = time.time() - _start
    devices = []
    for i, (host, image, kind, speed, lag) in enumerate(_DEMO):
        p = ((t - lag) * speed * 1.4) % 130
        if t < lag:
            phase, pct, state = "queued", 0.0, "Queued"
        elif p >= 100:
            phase, pct, state = "complete", 100.0, "Complete"
        else:
            phase, pct, state = "imaging", p, "In-Progress"
        if host.endswith("9001") and p > 62 and t > lag:
            phase, state = "failed", "Failed"
        done = pct / 100.0
        total_gb = 38.0
        devices.append({
            "id": 1000 + i, "host": host, "mac": "00:1b:44:%02x:%02x:%02x" % (i * 7 % 256, i * 31 % 256, i * 53 % 256),
            "image": image, "kind": kind, "state": state, "phase": phase, "percent": round(pct, 1),
            "rate": "%.1f GB/min" % (4.2 * speed) if phase == "imaging" else "",
            "elapsed": "%d:%02d" % (max(0, t - lag) // 60, max(0, t - lag) % 60) if t >= lag else "",
            "remaining": "%d min" % max(1, math.ceil((1 - done) * 9 / speed)) if phase == "imaging" else "",
            "copied": "%.1f GB" % (done * total_gb) if t >= lag else "", "total": "%.0f GB" % total_gb if t >= lag else "",
            "started": "",
        })
    return {"ok": True, "devices": devices}


def sysread(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def interface_ips(name):
    try:
        p = subprocess.run(["ip", "-j", "-4", "addr", "show", "dev", name], capture_output=True, text=True, timeout=3)
        rows = json.loads(p.stdout or "[]")
        ips = []
        for row in rows if isinstance(rows, list) else []:
            for a in row.get("addr_info", []):
                if a.get("family") == "inet" and a.get("local"):
                    ips.append("%s/%s" % (a.get("local"), a.get("prefixlen", "")))
        return ips
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def list_interfaces():
    env = load_env(JOG_ENV_FILE)
    roles = {
        "imaging": env.get("JOG_USB_IFACE", ""),
        "backhaul": env.get("JOG_BACKHAUL_IFACE", ""),
        "hotspot": env.get("JOG_HOTSPOT_IFACE", ""),
    }
    root = "/sys/class/net"
    out = []
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return out
    for name in names:
        if name == "lo":
            continue
        base = os.path.join(root, name)
        wireless = os.path.exists(os.path.join(base, "wireless")) or os.path.exists(os.path.join(base, "phy80211"))
        dev = os.path.realpath(os.path.join(base, "device"))
        usb = os.path.isdir(dev) and "/usb" in dev.lower()
        driver = ""
        if os.path.isdir(os.path.join(dev, "driver")):
            driver = os.path.basename(os.path.realpath(os.path.join(dev, "driver")))
        iface_type = sysread(os.path.join(base, "type"), "")
        try:
            admin_up = bool(int(sysread(os.path.join(base, "flags"), "0"), 16) & 1)
        except ValueError:
            admin_up = False
        operstate = sysread(os.path.join(base, "operstate"), "unknown")
        out.append({
            "name": name,
            "address": sysread(os.path.join(base, "address")),
            "state": "UP" if admin_up else operstate,
            "operstate": operstate,
            "carrier": sysread(os.path.join(base, "carrier"), ""),
            "type": iface_type,
            "wireless": wireless,
            "usb": usb,
            "driver": driver,
            "ips": interface_ips(name),
            "role": next((r for r, n in roles.items() if n == name), ""),
            "imagingOk": iface_type == "1" and not wireless and usb,
            "hotspotOk": wireless and usb,
            "backhaulOk": name != roles["imaging"] and name != roles["hotspot"] and (iface_type == "1" or wireless),
        })
    return out


def local_safety():
    env = load_env(JOG_ENV_FILE)
    iface = env.get("JOG_USB_IFACE", "")
    usb = False
    wireless = False
    if iface:
        base = "/sys/class/net/%s" % iface
        dev = os.path.realpath(os.path.join(base, "device"))
        usb = os.path.isdir(dev) and "/usb" in dev.lower()
        wireless = os.path.exists(os.path.join(base, "wireless")) or os.path.exists(os.path.join(base, "phy80211"))
    dhcp_iface = iface
    bridge_path = "/sys/class/net/%s/brport/bridge" % iface if iface else ""
    if bridge_path and os.path.exists(bridge_path):
        try:
            dhcp_iface = os.path.basename(os.path.realpath(bridge_path)) or iface
        except OSError:
            dhcp_iface = iface
    conf = sysread("/etc/dnsmasq.d/99-jog-imaging.conf")
    lines = [line.strip() for line in conf.splitlines() if line.strip() and not line.strip().startswith("#")]
    interface_names = [line.split("=", 1)[1].strip() for line in lines if line.startswith("interface=")]
    no_dhcp = [line.split("=", 1)[1].strip() for line in lines if line.startswith("no-dhcp-interface=")]
    dhcp_enabled = (
        bool(dhcp_iface)
        and dhcp_iface in interface_names
        and dhcp_iface not in no_dhcp
        and any(line.startswith("dhcp-range=") for line in lines)
    )
    state = "safe" if iface and usb and not wireless and dhcp_enabled else "review"
    return {
        "imagingInterface": iface,
        "usbEthernet": usb,
        "wireless": wireless,
        "dhcpEnabled": dhcp_enabled,
        "state": state,
    }


def service_status(names):
    out = {}
    for name in names:
        try:
            p = subprocess.run(["systemctl", "is-active", name], capture_output=True, text=True, timeout=3)
            out[name] = p.stdout.strip() or "unknown"
        except (OSError, subprocess.SubprocessError):
            out[name] = "unknown"
    return out


def network_overview():
    env = load_env(JOG_ENV_FILE)
    interfaces = list_interfaces()
    default_route = {}
    try:
        r = subprocess.run(["ip", "-j", "route", "show", "default"], capture_output=True, text=True, timeout=3)
        routes = json.loads(r.stdout or "[]")
        if routes:
            d = routes[0]
            default_route = {"iface": d.get("dev", ""), "gateway": d.get("gateway", ""), "metric": d.get("metric", "")}
    except Exception:
        pass
    dns = []
    try:
        for line in open('/etc/resolv.conf', encoding='utf-8', errors='replace'):
            line=line.strip()
            if line.startswith('nameserver '):
                dns.append(line.split()[1])
    except OSError:
        pass
    ssid = ""
    signal = ""
    active_iface = default_route.get("iface", "")
    try:
        r = subprocess.run(["iwgetid", "-r"], capture_output=True, text=True, timeout=2)
        ssid = r.stdout.strip()
    except Exception:
        pass
    try:
        r = subprocess.run(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,DEVICE", "dev", "wifi"], capture_output=True, text=True, timeout=3)
        for line in r.stdout.splitlines():
            parts=line.split(':')
            if parts and parts[0]=='*':
                if len(parts)>1 and not ssid: ssid=parts[1]
                if len(parts)>2: signal=parts[2]+'%'
                if len(parts)>3: active_iface = active_iface or parts[3]
    except Exception:
        pass
    summary = {
        "defaultInterface": default_route.get("iface",""),
        "gateway": default_route.get("gateway",""),
        "ssid": ssid,
        "signal": signal,
        "dns": ", ".join(dns[:3]),
        "ip": "",
    }
    for iface in interfaces:
        if iface.get("name") == summary["defaultInterface"] and iface.get("ips"):
            summary["ip"] = iface["ips"][0]
            break
    return {"ok": True, "summary": summary, "interfaces": interfaces, "defaultRoute": default_route, "dns": dns}


def battery_payload():
    helper = os.environ.get("JOG_BATTERY_HELPER", os.environ.get("JOG_BATTERY_HELPER", "/usr/local/sbin/jog-battery.sh" if os.path.exists("/usr/local/sbin/jog-battery.sh") else "/usr/local/sbin/jog-battery.sh"))
    try:
        p = subprocess.run([helper], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise ApiError("Battery helper unavailable", 502)
    if p.returncode != 0:
        raise ApiError(helper_error_message(p.stdout, p.stderr, "Battery helper failed")[:500], 502)
    lines = [line.strip() for line in p.stdout.splitlines() if line.strip().startswith("{")]
    if not lines:
        raise ApiError("Battery helper returned no data", 502)
    try:
        data = json.loads(lines[-1])
    except ValueError:
        raise ApiError("Invalid battery data", 502)
    if not isinstance(data, dict):
        raise ApiError("Invalid battery data", 502)
    return data


def devices_payload(demo):
    try:
        res = fetch_demo() if demo else fetch_live()
    except ApiError as e:
        res = {"ok": True, "devices": [], "warning": str(e)}
    res["devices"].sort(key=lambda d: ({"imaging": 0, "queued": 1, "failed": 2, "complete": 3}.get(d["phase"], 4), -d["percent"]))
    res["summary"] = summarize(res["devices"])
    res["updated"] = int(time.time())
    res["mode"] = "demo" if demo else "live"
    return res


def fog_list(kind, search="", demo=False):
    if demo:
        if kind == "hosts":
            rows = _DEMO_HOSTS
        elif kind == "images":
            rows = _DEMO_IMAGES
        else:
            rows = _DEMO_SESSIONS
        if search:
            rows = [r for r in rows if search.lower() in json.dumps(r).lower()]
        return {"ok": True, "rows": rows, "mode": "demo"}
    paths = {
        "hosts": "/host/list",
        "images": "/image/list",
        "sessions": "/multicastsession/list",
        "tasks": "/task/list",
    }
    try:
        resp = fog_request("GET", paths[kind], params={"search": search} if search and kind == "hosts" else None)
    except ApiError as e:
        return {"ok": True, "rows": [], "warning": str(e), "mode": "live"}
    rows = fog_rows(resp, kind, "data")
    if kind == "hosts":
        rows = [normalize_host(r) for r in rows if isinstance(r, dict)]
    elif kind == "images":
        rows = [normalize_image(r) for r in rows if isinstance(r, dict)]
    elif kind == "sessions":
        rows = [normalize_session(r) for r in rows if isinstance(r, dict)]
    elif kind == "tasks":
        rows = [normalize_task(r) for r in rows if isinstance(r, dict)]
    return {"ok": True, "rows": rows, "mode": "live"}


def require_root(body):
    username = str(body.get("username", "") or "").strip()
    password = str(body.get("password", "") or "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", username):
        raise ApiError("Enter a valid administrator username", 400)
    if not password:
        raise ApiError("Enter the administrator sudo password", 400)
    return username, password


def helper_error_message(out, err, fallback):
    for stream in (err, out):
        lines = [line.strip() for line in stream.splitlines() if line.strip().startswith("{")]
        for line in reversed(lines):
            try:
                data = json.loads(line)
            except ValueError:
                continue
            if isinstance(data, dict) and data.get("error"):
                return str(data["error"])
    lines = [line.strip() for line in err.splitlines() if line.strip()]
    return lines[-1] if lines else fallback


def run_privileged(username, password, args, timeout=120):
    inner = "sudo -S -H -p '' " + " ".join([shlex.quote(HELPER)] + [shlex.quote(str(a)) for a in args])
    try:
        p = subprocess.run(
            ["/bin/su", "-", username, "-c", inner],
            input=(password + "\n" + password + "\n").encode(),
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise ApiError("Privileged command timed out", 504)
    out = p.stdout.decode("utf-8", "replace")
    err = p.stderr.decode("utf-8", "replace").replace(password, "***")
    if p.returncode != 0:
        msg = helper_error_message(out, err, "Privileged command failed")
        raise ApiError(msg[:500], 403)
    lines = [l.strip() for l in out.splitlines() if l.strip().startswith("{")]
    if lines:
        try:
            return normalize_helper_result(json.loads(lines[-1]))
        except ValueError:
            pass
    return normalize_helper_result({"ok": True, "output": out[-4000:]})


def run_local(args, timeout=30):
    try:
        p = subprocess.run(
            ["sudo", "-n", "-H", HELPER] + [str(a) for a in args],
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        raise ApiError("Helper command timed out", 504)
    out = p.stdout.decode("utf-8", "replace")
    err = p.stderr.decode("utf-8", "replace")
    if p.returncode != 0:
        msg = helper_error_message(out, err, "Helper command failed")
        raise ApiError(msg[:500], 403)
    lines = [l.strip() for l in out.splitlines() if l.strip().startswith("{")]
    if lines:
        try:
            return normalize_helper_result(json.loads(lines[-1]))
        except ValueError:
            pass
    return normalize_helper_result({"ok": True, "output": out[-4000:]})


def normalize_helper_result(data):
    if isinstance(data, dict) and isinstance(data.get("ok"), str):
        data["ok"] = data["ok"].strip().lower() in ("true", "1", "yes")
    return data


def record_build_status(query):
    vm = str((query.get("vm") or [""])[0]).strip()
    phase = str((query.get("phase") or [""])[0]).strip().lower()
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.-]{0,63}", vm):
        raise ApiError("Invalid build VM", 400)
    if not re.fullmatch(r"[a-z0-9_-]{1,32}", phase):
        raise ApiError("Invalid build phase", 400)
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    message = "%s %s %s" % (stamp, vm, phase)
    os.makedirs(os.path.dirname(BUILD_STATUS_FILE), exist_ok=True)
    with open(BUILD_STATUS_FILE, "w") as handle:
        handle.write(message + "\n")
    return {"ok": True, "status": message}


def jog_replicate_status(name):
    return run_local(["replicate", "status", name])


def valid_vm_name(value):
    name = str(value or "").strip()
    if not VM_NAME_RE.fullmatch(name):
        raise ApiError("Invalid VM name", 400)
    return name


def valid_snapshot_name(value):
    name = str(value or "").strip()
    if not SNAPSHOT_RE.fullmatch(name):
        raise ApiError("Invalid checkpoint name", 400)
    return name


def valid_vm_action(value):
    action = str(value or "").strip()
    if action not in VM_ACTIONS:
        raise ApiError("Unsupported VM action", 400)
    return action


def valid_snapshot_action(value):
    action = str(value or "").strip()
    if action not in SNAPSHOT_ACTIONS:
        raise ApiError("Unsupported checkpoint action", 400)
    return action


def valid_iso_path(value):
    path = str(value or "").strip()
    if not path or not os.path.isabs(path) or not path.lower().endswith(".iso") or ".." in path.split("/"):
        raise ApiError("Select a valid ISO path", 400)
    real = os.path.realpath(path)
    if not os.path.isfile(real):
        raise ApiError("ISO not found: %s" % os.path.basename(path), 400)
    if not any(real == root or real.startswith(root + os.sep) for root in VM_ISO_ROOTS):
        raise ApiError("ISO must be inside an approved ISO directory", 400)
    return path


def truthy(value):
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def valid_vm_size(value, low, high, label):
    text = str(value or "").strip()
    if not re.fullmatch(r"\d+", text) or not low <= int(text) <= high:
        raise ApiError("%s must be %d-%d" % (label, low, high), 400)
    return text


def vm_create_args(body):
    name = valid_vm_name(body.get("name"))
    ram = valid_vm_size(body.get("ram"), 2048, 65536, "RAM (MiB)")
    vcpus = valid_vm_size(body.get("vcpus"), 1, 32, "vCPUs")
    disk = valid_vm_size(body.get("diskGb", body.get("disk")), 20, 4096, "Disk (GiB)")
    iso_value = body.get("iso")
    if iso_value is None:
        iso_value = body.get("windowsIso")
    iso_value = str(iso_value or "").strip()
    iso = valid_iso_path(iso_value) if iso_value else ""
    virtio_raw = body.get("virtioIso")
    if virtio_raw is None:
        virtio_raw = "/var/lib/libvirt/isos/virtio-win.iso" if iso else ""
    virtio_value = str(virtio_raw or "").strip()
    virtio = valid_iso_path(virtio_value) if virtio_value else ""
    bus = str(body.get("diskBus") or "virtio").strip()
    if bus not in ("virtio", "sata", "nvme"):
        raise ApiError("Unsupported disk bus", 400)
    network = str(body.get("network") or "fog-capture").strip()
    network_type = str(body.get("networkType") or body.get("nicType") or "network").strip().lower()
    if network_type not in ("network", "bridge"):
        raise ApiError("Invalid NIC source type", 400)
    if network_type == "network":
        if not re.fullmatch(r"[A-Za-z0-9_.-]{1,40}", network):
            raise ApiError("Invalid virtual network", 400)
    elif not re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", network):
        raise ApiError("Invalid host bridge", 400)
    secure = "1" if truthy(body.get("secureBoot", "1")) else "0"
    tpm = "1" if truthy(body.get("tpm", "1")) else "0"
    start = "1" if truthy(body.get("start", "1")) else "0"
    return ["vm", "create", name, ram, vcpus, disk, iso, virtio, bus, network, secure, tpm, start, network_type]


def vm_action_args(body):
    name = valid_vm_name(body.get("name"))
    action = valid_vm_action(body.get("action"))
    args = ["vm", "action", name, action]
    if action == "attach-iso":
        args.append(valid_iso_path(body.get("iso") or body.get("extra")))
    elif action == "clone":
        args.append(valid_vm_name(body.get("clone") or body.get("cloneName") or body.get("extra")))
    return args


def vm_snapshot_args(body):
    action = valid_snapshot_action(body.get("action"))
    name = valid_vm_name(body.get("name"))
    args = ["vm", "snapshot", action, name]
    if action != "list":
        args.append(valid_snapshot_name(body.get("checkpoint") or body.get("snapshot")))
    return args


def vm_resources_args(body):
    name = valid_vm_name(body.get("name"))
    ram = valid_vm_size(body.get("ram"), 2048, 65536, "RAM (MiB)")
    vcpus = valid_vm_size(body.get("vcpus"), 1, 32, "vCPUs")
    args = ["vm", "resources", name, ram, vcpus]
    disk = str(body.get("diskGb", body.get("disk")) or "").strip()
    if disk:
        args.append(valid_vm_size(disk, 20, 4096, "Disk (GiB)"))
    return args


VM_BOOT_DEVICES = {"hd", "cdrom", "network"}
NET_MODES = {"isolated", "nat", "bridge"}
NIC_ACTIONS = {"add", "remove", "set-model", "set-network", "set-mac"}
NIC_MODELS = {"e1000", "e1000e", "virtio", "rtl8139", "vmxnet3", "ne2k_pci"}
DISK_ACTIONS = {"add", "resize", "remove", "attach", "detach", "set-boot"}
DISK_BUSES = {"virtio", "sata", "ide", "scsi", "nvme"}
DISK_FORMATS = {"qcow2", "raw"}
USB_ACTIONS = {"attach", "detach"}
MAC_RE = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
NET_NAME_RE = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{0,31}")
BRIDGE_RE = re.compile(r"[A-Za-z0-9_.:-]{1,15}")
CIDR_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}/([0-9]|[12]\d|3[0-2])$")
DISK_TARGET_RE = re.compile(r"^(sd[a-z]{1,2}|vd[a-z]{1,2}|nvme[0-9]+n[0-9]+|xvd[a-z]{1,2})$")
USB_DEVICE_RE = re.compile(r"^usb_[0-9]+(?:_[0-9]+)+$")
IMAGE_ROOT = "/var/lib/libvirt/images"


def valid_choice(value, choices, label):
    text = str(value or "").strip()
    if text not in choices:
        raise ApiError("Unsupported " + label, 400)
    return text


def valid_boot_device(value):
    return valid_choice(value, VM_BOOT_DEVICES, "boot device")


def valid_menu(value):
    if isinstance(value, bool):
        return "1" if value else "0"
    text = str(value if value is not None else "").strip().lower()
    if text in ("1", "true", "yes", "on"):
        return "1"
    if text in ("0", "false", "no", "off"):
        return "0"
    raise ApiError("Boot menu must be 0 or 1", 400)


def valid_net_name(value):
    name = str(value or "").strip()
    if not NET_NAME_RE.fullmatch(name):
        raise ApiError("Invalid virtual switch name", 400)
    return name


def valid_ipv4(value, label, required=False):
    text = str(value or "").strip()
    if not text:
        if required:
            raise ApiError(label + " is required", 400)
        return ""
    try:
        ipaddress.IPv4Address(text)
    except ValueError:
        raise ApiError("Invalid " + label, 400)
    return text


def valid_cidr(value, required=False):
    text = str(value or "").strip()
    if not text:
        if required:
            raise ApiError("CIDR is required", 400)
        return ""
    if not CIDR_RE.fullmatch(text):
        raise ApiError("CIDR must be an IPv4 network such as 192.168.100.0/24", 400)
    try:
        ipaddress.IPv4Network(text, strict=True)
    except ValueError:
        raise ApiError("CIDR must use the network address with host bits set to zero", 400)
    return text


def valid_bridge(value, required=False):
    text = str(value or "").strip()
    if not text:
        if required:
            raise ApiError("Host bridge is required", 400)
        return ""
    if not BRIDGE_RE.fullmatch(text):
        raise ApiError("Invalid host bridge name", 400)
    return text


def valid_mac(value, label="MAC address"):
    text = str(value or "").strip()
    if not MAC_RE.fullmatch(text):
        raise ApiError("Invalid " + label, 400)
    return text


def valid_nic_identifier(value):
    text = str(value or "").strip()
    if not text or len(text) > 64 or not re.fullmatch(r"[A-Za-z0-9:._-]+", text):
        raise ApiError("Select a NIC by MAC address or target", 400)
    return text


def valid_nic_source_type(value):
    return valid_choice(value, {"network", "bridge"}, "NIC source type")


def valid_disk_target(value, allow_none=False):
    text = str(value or "").strip()
    if allow_none and text.lower() in ("none", ""):
        return "none"
    if not DISK_TARGET_RE.fullmatch(text):
        raise ApiError("Invalid disk target", 400)
    return text


def valid_disk_path(value, required=False, require_file=False):
    text = str(value or "").strip()
    if not text:
        if required:
            raise ApiError("Disk image path is required", 400)
        return ""
    if not os.path.isabs(text) or ".." in text.split("/"):
        raise ApiError("Disk image must be inside " + IMAGE_ROOT, 400)
    real = os.path.realpath(text)
    if not (real == IMAGE_ROOT or real.startswith(IMAGE_ROOT + os.sep)):
        raise ApiError("Disk image must be inside " + IMAGE_ROOT, 400)
    if require_file and not os.path.isfile(real):
        raise ApiError("Disk image not found", 400)
    return text


def valid_usb_device(value):
    device = str(value or "").strip()
    if not USB_DEVICE_RE.fullmatch(device):
        raise ApiError("Invalid USB device", 400)
    return device


def vm_boot_args(body, read_only=False):
    name = valid_vm_name(body.get("name"))
    if read_only:
        return ["vm", "boot", name]
    device = valid_boot_device(body.get("device"))
    menu = valid_menu(body.get("menu", "1"))
    return ["vm", "boot", name, device, menu]


def vm_network_create_args(body):
    name = valid_net_name(body.get("name"))
    mode = valid_choice(body.get("mode"), NET_MODES, "virtual switch mode")
    cidr = valid_cidr(body.get("cidr"), required=mode != "bridge")
    start = valid_ipv4(body.get("dhcpStart"), "DHCP start address")
    end = valid_ipv4(body.get("dhcpEnd"), "DHCP end address")
    bridge = valid_bridge(body.get("bridge"), required=mode == "bridge")
    if (start or end) and not (start and end):
        raise ApiError("Provide both DHCP start and end or leave both blank", 400)
    if start and end:
        if mode == "bridge":
            raise ApiError("Bridge networks do not provide libvirt DHCP", 400)
        network = ipaddress.IPv4Network(cidr, strict=True)
        first = ipaddress.IPv4Address(start)
        last = ipaddress.IPv4Address(end)
        if first not in network or last not in network or first > last:
            raise ApiError("DHCP range must be inside the CIDR and in ascending order", 400)
    return ["vm", "network", "create", name, mode, cidr, start, end, bridge]


def vm_network_action_args(body):
    name = valid_net_name(body.get("name"))
    action = valid_choice(body.get("action"), {"start", "stop", "delete"}, "virtual switch action")
    return ["vm", "network", action, name]


def vm_nic_args(body, read_only=False):
    name = valid_vm_name(body.get("name"))
    if read_only:
        return ["vm", "nics", name]
    action = valid_choice(body.get("action"), NIC_ACTIONS, "NIC action")
    ident = valid_nic_identifier(pick(body, "identifier", "target", "mac", "nic"))
    args = ["vm", "nic", name, action, ident]
    if action == "add":
        source_type = valid_nic_source_type(body.get("sourceType"))
        source = str(body.get("source") or "").strip()
        if not source:
            raise ApiError("NIC source is required", 400)
        if source_type == "network":
            source = valid_net_name(source)
        else:
            source = valid_bridge(source, required=True)
        model = valid_choice(body.get("model", "e1000e"), NIC_MODELS, "NIC model")
        args.extend([source_type, source, model])
        if body.get("mac") not in (None, ""):
            args.append(valid_mac(body.get("mac")))
    elif action == "set-model":
        args.append(valid_choice(body.get("model"), NIC_MODELS, "NIC model"))
    elif action == "set-network":
        source_type = valid_nic_source_type(body.get("sourceType"))
        source = str(body.get("source") or "").strip()
        if not source:
            raise ApiError("NIC source is required", 400)
        if source_type == "network":
            source = valid_net_name(source)
        else:
            source = valid_bridge(source, required=True)
        args.extend([source_type, source])
    elif action == "set-mac":
        args.append(valid_mac(pick(body, "newMac", "mac"), "new MAC address"))
    return args


def vm_disk_args(body, read_only=False):
    name = valid_vm_name(body.get("name"))
    if read_only:
        return ["vm", "disks", name]
    action = valid_choice(body.get("action"), DISK_ACTIONS, "disk action")
    if action == "add":
        size = valid_vm_size(body.get("sizeGiB"), 1, 4096, "Disk size (GiB)")
        bus = valid_choice(body.get("bus", "virtio"), DISK_BUSES, "disk bus")
        fmt = valid_choice(body.get("format", "qcow2"), DISK_FORMATS, "disk format")
        return ["vm", "disk", name, "add", size, bus, fmt]
    if action == "resize":
        target = valid_disk_target(body.get("target"))
        size = valid_vm_size(body.get("sizeGiB"), 1, 4096, "Disk size (GiB)")
        return ["vm", "disk", name, "resize", target, size]
    if action == "remove":
        target = valid_disk_target(body.get("target"))
        delete = "1" if truthy(body.get("deleteFile")) else "0"
        return ["vm", "disk", name, "remove", target, delete]
    if action == "attach":
        path = valid_disk_path(pick(body, "path", "file"), required=True, require_file=True)
        target = valid_disk_target(body.get("target"))
        bus = valid_choice(body.get("bus", "virtio"), DISK_BUSES, "disk bus")
        return ["vm", "disk", name, "attach", path, target, bus]
    if action == "detach":
        return ["vm", "disk", name, "detach", valid_disk_target(body.get("target"))]
    return ["vm", "disk", name, "set-boot", valid_disk_target(body.get("target"), allow_none=True)]


def vm_usb_args(body, name=None):
    if name is None:
        return ["vm", "usb"]
    target = valid_vm_name(name)
    action = valid_choice(body.get("action"), USB_ACTIONS, "USB action")
    device = valid_usb_device(body.get("device"))
    return ["vm", "usb", target, action, device]


HW_SECTIONS = {
    "machine": {"type", "firmware", "secureBoot", "tpm"},
    "cpu": {"model", "customModel", "sockets", "cores", "threads", "features"},
    "memory": {"ramMiB", "currentMiB", "balloonEnabled"},
    "video": {"model", "vramMiB", "heads", "accel3d"},
    "audio": {"model"},
    "input": {"tablet", "mouse", "keyboard"},
    "usbController": {"model"},
    "graphics": {"type", "listen", "port"},
    "rng": {"enabled", "model"},
    "watchdog": {"enabled", "model", "action"},
    "boot": {"order", "menu"},
}
HW_CHOICES = {
    "machine.type": {"q35", "i440fx"},
    "machine.firmware": {"uefi", "bios"},
    "machine.tpm": {"2.0", "1.2", "none"},
    "cpu.model": {"host-model", "host-passthrough", "qemu64", "custom"},
    "video.model": {"qxl", "bochs", "virtio", "vmware"},
    "audio.model": {"none", "ich9", "ac97", "ich6", "usb", "virtio", "spice"},
    "usbController.model": {"xhci", "ehci", "piix3-uhci", "none"},
    "graphics.type": {"vnc", "spice", "none"},
    "rng.model": {"random", "hwrng", "virtio"},
    "watchdog.model": {"i6300esb", "ib700", "diag288", "itco"},
    "watchdog.action": {"none", "pause", "poweroff", "reset", "shutdown", "halt", "dump"},
}
HW_BOOL_KEYS = {
    "machine.secureBoot", "memory.balloonEnabled", "video.accel3d",
    "input.tablet", "input.mouse", "input.keyboard", "rng.enabled",
    "watchdog.enabled", "boot.menu",
}
HW_INT_RANGES = {
    "cpu.sockets": (1, 64), "cpu.cores": (1, 64), "cpu.threads": (1, 64),
    "memory.ramMiB": (256, 262144), "memory.currentMiB": (256, 262144),
    "video.vramMiB": (1, 256), "video.heads": (1, 4), "graphics.port": (0, 65535),
}


def valid_hardware_patch(value):
    patch = value
    if isinstance(patch, str):
        try:
            patch = json.loads(patch)
        except ValueError:
            raise ApiError("Hardware patch must be valid JSON", 400)
    if not isinstance(patch, dict):
        raise ApiError("Hardware patch must be a JSON object", 400)
    unknown = sorted(set(patch) - set(HW_SECTIONS))
    if unknown:
        raise ApiError("Unsupported hardware section: " + ", ".join(unknown), 400)
    for section, data in patch.items():
        if not isinstance(data, dict):
            raise ApiError("Hardware section " + section + " must be an object", 400)
        extra = sorted(set(data) - HW_SECTIONS[section])
        if extra:
            raise ApiError("Unsupported " + section + " field: " + ", ".join(extra), 400)
        for key, item in data.items():
            full = section + "." + key
            if full in HW_CHOICES and str(item or "").strip() not in HW_CHOICES[full]:
                raise ApiError("Unsupported " + full, 400)
            if full in HW_BOOL_KEYS and not isinstance(item, bool):
                raise ApiError(full + " must be true or false", 400)
            if full in HW_INT_RANGES:
                low, high = HW_INT_RANGES[full]
                if isinstance(item, bool) or not re.fullmatch(r"\d+", str(item).strip()) or not low <= int(item) <= high:
                    raise ApiError(full + " must be " + str(low) + "-" + str(high), 400)
            if full == "cpu.customModel" and not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", str(item or "").strip()):
                raise ApiError("Invalid CPU custom model", 400)
            if full == "graphics.listen" and not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", str(item or "").strip()):
                raise ApiError("Invalid graphics listen address", 400)
            if full == "boot.order":
                if not isinstance(item, list) or not 1 <= len(item) <= 3:
                    raise ApiError("Boot order must be one to three devices", 400)
                if any(str(entry or "").strip() not in VM_BOOT_DEVICES for entry in item) or len(set(item)) != len(item):
                    raise ApiError("Boot order must list unique hd, cdrom or network devices", 400)
            if full == "cpu.features":
                if not isinstance(item, list) or len(item) > 32:
                    raise ApiError("CPU features must be a list", 400)
                for feature in item:
                    if not isinstance(feature, dict) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", str(feature.get("name", "") or "")):
                        raise ApiError("Invalid CPU feature", 400)
                    if str(feature.get("policy", "") or "").strip() not in ("force", "require", "optional", "disable", "forbid"):
                        raise ApiError("Invalid CPU feature policy", 400)
    return patch


def vm_hardware_args(body, read_only=False):
    name = valid_vm_name(body.get("name"))
    if read_only:
        return ["vm", "hardware", name]
    patch = valid_hardware_patch(body.get("patch", body.get("hardware")))
    return ["vm", "hardware-apply", name, json.dumps(patch, sort_keys=True)]


def vm_fog_network_args(body):
    name = str(body.get("name") or "fog-capture").strip()
    return ["vm", "fog-network", "ensure", valid_net_name(name)]


def vm_fog_capture_args(body):
    name = valid_vm_name(body.get("name"))
    network = str(body.get("network") or "fog-capture").strip()
    start = "1" if truthy(body.get("start")) else "0"
    return ["vm", "fog-capture", name, valid_net_name(network), start]


def local_view():
    listing = run_local(["vm", "list"])
    vms = []
    for row in listing.get("vms", []):
        vm = dict(row)
        name = row.get("name")
        if name:
            detail = run_local(["vm", "detail", name])
            if isinstance(detail.get("vm"), dict):
                vm.update(detail["vm"])
        vms.append(vm)
    isos = run_local(["vm", "isos"]).get("isos", [])
    return {"ok": True, "vms": vms, "isos": isos}


def local_detail(name):
    result = run_local(["vm", "detail", valid_vm_name(name)])
    result.setdefault("ok", True)
    return result


def local_console(name):
    result = run_local(["vm", "console", valid_vm_name(name)])
    result.setdefault("ok", True)
    return result


def create_fog_task(body):
    host_id = str(body.get("hostId", "") or "")
    image_id = str(body.get("imageId", "") or "")
    kind = str(body.get("kind", "deploy") or "deploy")
    if not host_id or not image_id:
        raise ApiError("Select a host and an image", 400)
    type_ids = {"deploy": 1, "capture": 2, "multicast": 8}
    if kind not in type_ids:
        raise ApiError("Unknown task type", 400)
    payload = {"taskTypeID": type_ids[kind], "imageID": image_id, "shutdown": bool(body.get("shutdown", False))}
    resp = fog_request("POST", "/host/%s/task" % urllib.parse.quote(host_id), payload)
    task_id = extract_id(resp)
    result = {"ok": True, "taskId": task_id, "kind": kind, "response": resp}
    if kind == "multicast":
        session = fog_session_payload(image_id, body)
        sresp = fog_request("POST", "/multicastsession/create", session)
        session_id = extract_id(sresp)
        if session_id and task_id:
            fog_request("POST", "/multicastsessionassociation/create", {"msID": session_id, "taskID": task_id})
        result["sessionId"] = session_id
    return result


def multicast_status():
    sessions = fog_list("sessions").get("rows", [])
    tasks = fog_list("tasks").get("rows", [])
    associations = {}
    try:
        assoc_resp = fog_request("GET", "/multicastsessionassociation/list")
        for row in fog_rows(assoc_resp, "associations", "data"):
            sid = str(pick(row, "msID", "sessionID", default=""))
            tid = str(pick(row, "taskID", "id", default=""))
            if sid and tid:
                associations.setdefault(sid, []).append(tid)
    except ApiError:
        pass
    task_by_id = {str(t.get("id")): t for t in tasks}
    for session in sessions:
        sid = str(session.get("id") or "")
        matched = [task_by_id[tid] for tid in associations.get(sid, []) if tid in task_by_id]
        if not matched:
            matched = [t for t in tasks if t.get("kind") == "Multi-Cast" and t.get("image", "").lower() == str(session.get("image", "")).lower()]
        session["clients"] = [{
            "id": t.get("id"),
            "host": t.get("host"),
            "state": t.get("state"),
            "phase": t.get("phase"),
            "percent": t.get("percent"),
            "rate": t.get("rate"),
            "elapsed": t.get("elapsed"),
            "remaining": t.get("remaining"),
            "copied": t.get("copied"),
            "total": t.get("total"),
        } for t in matched]
        session["ready"] = all(c.get("phase") == "complete" for c in session["clients"]) and bool(session["clients"])
    lines = []
    try:
        with open("/opt/fog/log/multicast.log", "r", errors="replace") as handle:
            lines = handle.readlines()[-80:]
    except OSError:
        pass
    active = [s for s in sessions if str(s.get("stateId")) in ("1", "2", "3")]
    return {
        "ok": True,
        "sessions": sessions,
        "active": len(active),
        "clients": sum(len(s.get("clients", [])) for s in active),
        "throughput": sum(num(c.get("rate")) for s in active for c in s.get("clients", [])),
        "logs": [line.rstrip() for line in lines[-30:]],
    }


def multicast_launch(body, username, password):
    image_id = str(body.get("imageId", "") or "")
    if not image_id:
        raise ApiError("Select an image", 400)
    host_ids = body.get("hostIds") or ([body["hostId"]] if body.get("hostId") else [])
    if isinstance(host_ids, str):
        host_ids = [host_ids]
    host_ids = [str(h) for h in host_ids if str(h).strip()]
    if not host_ids:
        raise ApiError("Select at least one host", 400)
    hosts = {str(pick(h, "id")): h for h in fog_rows(fog_request("GET", "/host/list"), "hosts")}
    vm_names = body.get("vmNames") or []
    if isinstance(vm_names, str):
        vm_names = [vm_names]
    vm_names = [valid_vm_name(n) for n in vm_names]
    prepared = []
    for index, host_id in enumerate(host_ids):
        host = hosts.get(host_id, {})
        vm_name = vm_names[index] if index < len(vm_names) else str(pick(host, "name", default=""))
        vm_name = valid_vm_name(vm_name)
        run_local(["vm", "fog-capture", vm_name, "fog-capture", "0"], timeout=180)
        prepared.append({"hostId": host_id, "vm": vm_name})
    session = fog_session_payload(image_id, {"name": body.get("sessionName", ""), "port": body.get("port", "63100"), "clients": len(host_ids), "maxwait": body.get("maxwait", "180")})
    sresp = fog_request("POST", "/multicastsession/create", session)
    session_id = extract_id(sresp)
    task_ids = []
    for host_id in host_ids:
        resp = fog_request("POST", "/host/%s/task" % urllib.parse.quote(host_id), {"taskTypeID": 8, "imageID": image_id, "shutdown": bool(body.get("shutdown", True))})
        task_id = extract_id(resp)
        if task_id:
            task_ids.append(task_id)
            if session_id:
                fog_request("POST", "/multicastsessionassociation/create", {"msID": session_id, "taskID": task_id})
    run_local(["fog-task-default"], timeout=60)
    started = []
    if bool(body.get("start", True)):
        for item in prepared:
            run_local(["vm", "action", item["vm"], "start"], timeout=180)
            started.append(item["vm"])
    return {"ok": True, "sessionId": session_id, "taskIds": task_ids, "prepared": prepared, "started": started, "session": session}


def multicast_stop(body, username, password, local=False):
    session_ids = []
    if body.get("sessionId"):
        session_ids = [str(body["sessionId"])]
    else:
        session_ids = [str(s.get("id")) for s in fog_list("sessions").get("rows", []) if s.get("id")]
    stopped_sessions = []
    for sid in session_ids:
        try:
            fog_request("DELETE", "/multicastsession/%s/delete" % urllib.parse.quote(sid))
            stopped_sessions.append(sid)
        except ApiError:
            pass
    stopped_tasks = []
    for task in fog_list("tasks").get("rows", []):
        tid = str(task.get("id") or "")
        if task.get("kind") == "Multi-Cast" and tid and task.get("phase") not in ("complete", "failed"):
            try:
                if local:
                    run_local(["fog-task-delete", tid])
                else:
                    run_privileged(username, password, ["fog-task-delete", tid])
                stopped_tasks.append(tid)
            except ApiError:
                pass
    vm_names = body.get("vmNames") or []
    if isinstance(vm_names, str):
        vm_names = [vm_names]
    stopped_vms = []
    for vm_name in vm_names:
        try:
            run_local(["vm", "action", valid_vm_name(vm_name), "shutdown"], timeout=180)
            stopped_vms.append(vm_name)
        except ApiError:
            pass
    try:
        run_local(["fog-task-default"], timeout=60)
    except ApiError:
        pass
    return {"ok": True, "sessions": stopped_sessions, "tasks": stopped_tasks, "vms": stopped_vms}


def storage_mode_payload(query=None):
    """Read the Haar-side storage-mode ledger from the FOG service endpoint.

    JOS writes it at boot: captures flag the image with the BIOS mode its
    drivers were captured under, deploys check that flag against the target
    mode and the JOS modules staged in the running initrd. The endpoint is
    advisory, so this payload is safe to expose read-only to the kiosk.
    """
    path = os.environ.get("JOG_STORAGE_MODE_FILE", "/var/lib/jog/storage-modes.json")
    raw = {"images": {}, "hosts": {}}
    try:
        with open(path, encoding="utf-8") as handle:
            loaded = json.load(handle)
        if isinstance(loaded, dict):
            raw.update(loaded)
    except (OSError, ValueError):
        pass

    images = raw.get("images") if isinstance(raw.get("images"), dict) else {}
    hosts = raw.get("hosts") if isinstance(raw.get("hosts"), dict) else {}
    q = query or {}

    def qv(key):
        values = q.get(key) or []
        return str(values[0]).strip() if values else ""

    def image_mode(imgid, name):
        keys = []
        if imgid:
            keys.append("id:" + str(imgid))
        if name:
            keys.append("name:" + str(name).lower())
        for key in keys:
            entry = images.get(key)
            if isinstance(entry, dict) and entry.get("mode"):
                return str(entry["mode"]).upper()
        return "unknown"

    target = qv("mode").upper()
    imgid = qv("imgid")
    name = qv("image") or qv("imagename")
    support_override = qv("support")
    wanted_mac = qv("mac").lower()

    candidates = []
    if wanted_mac:
        candidates.append((wanted_mac, hosts.get(wanted_mac, {})))
    else:
        candidates.extend(hosts.items())
    if not candidates and (target or imgid or name):
        candidates.append(("", {}))

    checks = []
    for mac, host in candidates:
        host = host if isinstance(host, dict) else {}
        mode = target or str(host.get("mode", "")).upper()
        support = support_override or str(host.get("support", "")) or "unknown"
        host_image_id = imgid or str(host.get("imageID", ""))
        host_image_name = name or str(host.get("imageName", ""))
        detected_image = image_mode(host_image_id, host_image_name)
        ok = True
        detail = "matching driver mode"
        if not mode or mode == "UNKNOWN":
            ok, detail = False, "storage mode not detected"
        elif support.startswith("missing:"):
            ok, detail = False, "JOS module missing: " + support.split(":", 1)[1]
        elif detected_image == "unknown":
            ok, detail = False, "image has no recorded storage mode"
        elif detected_image != mode:
            ok, detail = False, "image drivers captured for a different mode"
        checks.append({
            "mac": mac or None,
            "mode": mode or "UNKNOWN",
            "imageMode": detected_image,
            "image": host_image_name or None,
            "imageID": host_image_id or None,
            "josSupport": support,
            "ok": ok,
            "detail": detail,
        })

    return {
        "ok": True,
        "file": path,
        "images": images,
        "hosts": hosts,
        "checks": checks,
    }


class Handler(SimpleHTTPRequestHandler):
    demo = False

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=STATIC, **kw)

    def json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def status_page(self):
        status_dir = os.environ.get("JOG_STATUS_DIR", os.environ.get("JOG_STATUS_DIR", "/var/lib/jog/status"))
        path = os.path.join(status_dir, "index.html")
        if not os.path.isfile(path):
            subprocess.run(["/usr/local/bin/jog-refresh-status.sh"], timeout=30, check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            body = open(path, "rb").read()
        except OSError as e:
            return self.json({"ok": False, "error": "status page unavailable: %s" % e}, 404)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def route(self):
        return urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)

    def query(self):
        return urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)

    def body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > 1048576:
            return {}
        try:
            data = json.loads(self.rfile.read(length).decode())
            return data if isinstance(data, dict) else {}
        except (ValueError, UnicodeDecodeError):
            return {}

    def guarded(self, fn):
        try:
            self.json(fn())
        except ApiError as e:
            self.json({"ok": False, "error": str(e)}, e.status)
        except Exception as e:
            self.json({"ok": False, "error": str(e)}, 500)

    def do_GET(self):
        path = self.route()
        q = self.query()
        if path.startswith("/api/vm/local/") and self.client_address[0] not in LOCAL_HOSTS:
            return self.json({"ok": False, "error": "Local VM endpoints are loopback only"}, 403)
        if path in ("/api/fog/multicast/launch-local", "/api/fog/multicast/stop-local") and self.client_address[0] not in LOCAL_HOSTS:
            return self.json({"ok": False, "error": "Local multicast endpoints are loopback only"}, 403)
        if path == "/api/session":
            return self.json({"ok": True, "mode": "demo" if self.demo else "live", "adminUser": (lambda e: e.get("JOG_ADMIN_USER") or e.get("JOG_ADMIN_USER","haaradmin"))(load_env(JOG_ENV_FILE))})
        if path == "/api/devices":
            return self.guarded(lambda: devices_payload(self.demo))
        if path == "/api/battery":
            return self.guarded(battery_payload)
        if path == "/api/network/overview":
            return self.guarded(network_overview)
        if path == "/api/overview":
            def overview():
                res = devices_payload(self.demo)
                res["safety"] = local_safety()
                res["services"] = service_status(["dnsmasq", "jog-imaging-api", "apache2", "mariadb", "tftpd-hpa", "jog-jogemetry-hotspot", "jog-jogemetry-dnsmasq"])
                base, api, user = fog_settings()
                res["fogApi"] = {"configured": bool(api and user), "url": base}
                res["network"] = network_overview()
                return res
            return self.guarded(overview)
        if path == "/api/network/interfaces":
            return self.guarded(lambda: {"ok": True, "interfaces": list_interfaces()})
        if path == "/api/storage-mode":
            return self.guarded(lambda: storage_mode_payload(q))
        if path == "/api/vm/view":
            return self.guarded(local_view)
        if path == "/api/vm/local/view":
            return self.guarded(local_view)
        if path == "/api/vm/local/detail":
            name = (q.get("name") or [""])[0]
            return self.guarded(lambda: local_detail(name))
        if path == "/api/vm/local/isos":
            return self.guarded(lambda: run_local(["vm", "isos"]))
        if path == "/api/vm/local/console":
            name = (q.get("name") or [""])[0]
            return self.guarded(lambda: local_console(name))
        if path == "/api/vm/local/boot":
            name = (q.get("name") or [""])[0]
            return self.guarded(lambda: run_local(vm_boot_args({"name": name}, read_only=True)))
        if path == "/api/vm/local/networks":
            return self.guarded(lambda: run_local(["vm", "networks"]))
        if path == "/api/vm/local/nics":
            name = (q.get("name") or [""])[0]
            return self.guarded(lambda: run_local(vm_nic_args({"name": name}, read_only=True)))
        if path == "/api/vm/local/disks":
            name = (q.get("name") or [""])[0]
            return self.guarded(lambda: run_local(vm_disk_args({"name": name}, read_only=True)))
        if path == "/api/vm/local/usb":
            return self.guarded(lambda: run_local(vm_usb_args({}), timeout=60))
        if path == "/api/vm/local/hardware":
            name = (q.get("name") or [""])[0]
            return self.guarded(lambda: run_local(vm_hardware_args({"name": name}, read_only=True)))
        if path == "/api/network/status":
            return self.json({"ok": False, "error": "Use POST with sudo credentials"}, 400)
        if path in ("/api/fog/hosts", "/api/fog/images", "/api/fog/sessions", "/api/fog/tasks/history"):
            kind = {"hosts": "hosts", "images": "images", "sessions": "sessions", "history": "tasks"}[path.rsplit("/", 1)[1]]
            search = (q.get("search", [""])[0] or "").strip()
            return self.guarded(lambda: fog_list(kind, search, self.demo))
        if path == "/api/fog/multicast/status":
            return self.guarded(multicast_status)
        if path in ("/api/jog/replicate/status", "/api/jog/replicate/status"):
            name = (q.get("vm") or ["jog-replicator"])[0]
            name = valid_vm_name(name)
            return self.guarded(lambda: jog_replicate_status(name))
        if path in ("/api/jog/build-status", "/api/jog/build-status"):
            return self.guarded(lambda: record_build_status(q))
        if path == "/api/audit":
            limit = int(q.get("limit", ["200"])[0] or 200)
            limit = max(1, min(limit, 2000))
            entries = []
            try:
                with open(AUDIT_LOG, encoding="utf-8", errors="replace") as f:
                    lines = f.readlines()[-limit:]
                for line in lines:
                    line = line.strip()
                    if line:
                        try: entries.append(json.loads(line))
                        except Exception: pass
            except OSError:
                pass
            return self.json({"ok": True, "entries": entries, "path": AUDIT_LOG})
        if path == "/api/preflight":
            kind = (q.get("kind") or ["generic"])[0]
            vm = (q.get("vm") or [""])[0] or None
            host_id = (q.get("hostId") or [""])[0] or None
            image_id = (q.get("imageId") or [""])[0] or None
            return self.guarded(lambda: preflight(kind, vm, host_id, image_id))
        if path in ("/jog/status", "/jog/status/", "/jog/status/index", "/jog/status/index.html", "/jog/status", "/jog/status/", "/jog/status/index", "/jog/status/index.html"):
            return self.status_page()
        super().do_GET()

    def do_POST(self):
        path = self.route()
        body = self.body()

        def root_args():
            return require_root(body)

        if path.startswith("/api/vm/local/") and self.client_address[0] not in LOCAL_HOSTS:
            return self.json({"ok": False, "error": "Local VM endpoints are loopback only"}, 403)
        if path in ("/api/fog/multicast/launch-local", "/api/fog/multicast/stop-local") and self.client_address[0] not in LOCAL_HOSTS:
            return self.json({"ok": False, "error": "Local multicast endpoints are loopback only"}, 403)
        if path == "/api/vm/local/action":
            return self.guarded(lambda: run_local(vm_action_args(body), timeout=180))
        if path == "/api/vm/local/snapshot":
            return self.guarded(lambda: run_local(vm_snapshot_args(body), timeout=180))
        if path == "/api/vm/local/resources":
            return self.guarded(lambda: run_local(vm_resources_args(body), timeout=180))
        if path == "/api/vm/local/create":
            return self.guarded(lambda: run_local(vm_create_args(body), timeout=300))
        if path == "/api/vm/local/delete":
            def local_delete():
                name = valid_vm_name(body.get("name"))
                return run_local(["vm", "action", name, "delete"], timeout=180)
            return self.guarded(local_delete)
        if path == "/api/vm/local/boot":
            return self.guarded(lambda: run_local(vm_boot_args(body), timeout=120))
        if path == "/api/vm/local/networks":
            return self.guarded(lambda: run_local(vm_network_create_args(body), timeout=120))
        if path == "/api/vm/local/network":
            return self.guarded(lambda: run_local(vm_network_action_args(body), timeout=120))
        if path == "/api/vm/local/nics":
            return self.guarded(lambda: run_local(vm_nic_args(body), timeout=120))
        if path == "/api/vm/local/disks":
            return self.guarded(lambda: run_local(vm_disk_args(body), timeout=180))
        if path == "/api/vm/local/usb":
            return self.guarded(lambda: run_local(vm_usb_args(body, body.get("name")), timeout=120))
        if path == "/api/vm/local/hardware":
            return self.guarded(lambda: run_local(vm_hardware_args(body), timeout=180))
        if path == "/api/vm/local/fog-network":
            return self.guarded(lambda: run_local(vm_fog_network_args(body), timeout=120))
        if path == "/api/vm/local/fog-capture":
            return self.guarded(lambda: run_local(vm_fog_capture_args(body), timeout=180))
        if path == "/api/auth/sudo-check":
            def check():
                u, p = root_args()
                return run_privileged(u, p, ["status"], timeout=30)
            return self.guarded(check)
        if path == "/api/vm/state":
            def vm_state():
                u, p = root_args()
                vms = run_privileged(u, p, ["vm", "list"])
                isos = run_privileged(u, p, ["vm", "isos"])
                return {"ok": True, "vms": vms.get("vms", []), "isos": isos.get("isos", [])}
            return self.guarded(vm_state)
        if path in ("/api/vm/list", "/api/vm/isos"):
            def vm_read():
                u, p = root_args()
                return run_privileged(u, p, ["vm", path.rsplit("/", 1)[1]])
            return self.guarded(vm_read)
        if path == "/api/vm/create":
            def vm_create_api():
                u, p = root_args()
                args = vm_create_args(body)
                return run_privileged(u, p, args, timeout=300)
            return self.guarded(vm_create_api)
        if path == "/api/vm/action":
            def vm_action_api():
                u, p = root_args()
                args = vm_action_args(body)
                return run_privileged(u, p, args, timeout=180)
            return self.guarded(vm_action_api)
        if path == "/api/vm/checkpoint":
            def vm_checkpoint_api():
                u, p = root_args()
                args = vm_snapshot_args(body)
                return run_privileged(u, p, args, timeout=180)
            return self.guarded(vm_checkpoint_api)
        if path == "/api/vm/resources":
            def vm_resources_api():
                u, p = root_args()
                args = vm_resources_args(body)
                return run_privileged(u, p, args, timeout=180)
            return self.guarded(vm_resources_api)
        if path == "/api/fog/run":
            def fog_run_now():
                u, p = root_args()
                kind = str(body.get("kind", "") or "").strip().lower()
                host_id = str(body.get("hostId", "") or "").strip()
                image_id = str(body.get("imageId", "") or "").strip()
                vm_name = str(body.get("vmName", "") or "").strip()
                network = str(body.get("network", "fog-capture") or "fog-capture").strip()
                shutdown = "1" if body.get("shutdown", True) else "0"
                if kind not in ("deploy", "capture"):
                    raise ApiError("Run now supports deploy or capture only", 400)
                if not host_id.isdigit() or not image_id.isdigit() or not vm_name:
                    raise ApiError("Select a host, image and VM", 400)
                result = run_privileged(u, p, ["fog-run", kind, host_id, image_id, vm_name, network, shutdown], timeout=240)
                notify("fog.run", {"kind": kind, "hostId": host_id, "imageId": image_id, "vm": vm_name, "result": result})
                return result
            return self.guarded(fog_run_now)
        if path == "/api/fog/delete":
            def delete_record():
                u, p = root_args()
                kind = str(body.get("kind", "") or "")
                ident = str(body.get("id", "") or "")
                if kind not in ("hosts", "sessions", "tasks") or not ident.isdigit():
                    raise ApiError("Unsupported delete request", 400)
                if self.demo:
                    return {"ok": True, "demo": True}
                if kind == "tasks":
                    return run_privileged(u, p, ["fog-task-delete", ident])
                endpoint = {"hosts": "/host/%s/delete", "sessions": "/multicastsession/%s/delete"}[kind] % ident
                resp = fog_request("DELETE", endpoint)
                return {"ok": True, "response": resp}
            return self.guarded(delete_record)
        if path == "/api/fog/hosts":
            def add_host():
                u, p = root_args()
                name = str(body.get("name", "") or "").strip()
                mac = str(body.get("mac", "") or "").strip()
                if not name or not mac:
                    raise ApiError("Host name and MAC are required", 400)
                if self.demo:
                    return {"ok": True, "demo": True, "id": "demo"}
                resp = fog_request("POST", "/host/create", {"name": name, "description": str(body.get("description", "") or "Created by HAAR portal"), "macs": [mac]})
                return {"ok": True, "id": extract_id(resp), "response": resp}
            return self.guarded(add_host)
        if path == "/api/fog/images":
            def add_image():
                u, p = root_args()
                name = str(body.get("name", "") or "").strip()
                image_path = str(body.get("path", "") or name).strip()
                if not name:
                    raise ApiError("Image name is required", 400)
                if self.demo:
                    return {"ok": True, "demo": True, "id": "demo"}
                payload = {"name": name, "path": image_path, "format": 5, "compress": 6, "isEnabled": 1}
                resp = fog_request("POST", "/image/create", payload)
                return {"ok": True, "id": extract_id(resp), "response": resp}
            return self.guarded(add_image)
        if path == "/api/fog/tasks":
            def task():
                u, p = root_args()
                if self.demo:
                    return {"ok": True, "demo": True, "taskId": "demo"}
                return create_fog_task(body)
            return self.guarded(task)
        if path == "/api/fog/multicast/launch-local":
            return self.guarded(lambda: multicast_launch(body, "", ""))
        if path == "/api/fog/multicast/stop-local":
            return self.guarded(lambda: multicast_stop(body, "", "", local=True))
        if path == "/api/fog/multicast/launch":
            def launch():
                u, p = root_args()
                if self.demo:
                    return {"ok": True, "demo": True, "sessionId": "demo"}
                result = multicast_launch(body, u, p)
                notify("multicast.launch", {"hostId": body.get("hostId"), "imageId": body.get("imageId"), "result": result})
                return result
            return self.guarded(launch)
        if path == "/api/fog/multicast/stop":
            def stop():
                u, p = root_args()
                if self.demo:
                    return {"ok": True, "demo": True}
                result = multicast_stop(body, u, p)
                notify("multicast.stop", {"result": result})
                return result
            return self.guarded(stop)
        if path in ("/api/jog/replicate", "/api/jog/replicate"):
            def replicate():
                u, p = root_args()
                action = str(body.get("action", "") or "").strip().lower()
                if action not in ("capture", "deploy"):
                    raise ApiError("Unsupported replication action", 400)
                name = valid_vm_name(body.get("vm") or "jog-replicator")
                if self.demo:
                    return {"ok": True, "demo": True, "action": action, "vm": name}
                result = run_privileged(u, p, ["replicate", action, name])
                notify("replicate", {"action": action, "vm": name, "result": result})
                return result
            return self.guarded(replicate)
        if path == "/api/fog/sessions":
            def session():
                u, p = root_args()
                image_id = str(body.get("imageId", "") or "")
                if not image_id:
                    raise ApiError("Select an image", 400)
                if self.demo:
                    return {"ok": True, "demo": True}
                payload = fog_session_payload(image_id, body)
                resp = fog_request("POST", "/multicastsession/create", payload)
                return {"ok": True, "id": extract_id(resp), "response": resp}
            return self.guarded(session)
        if path.startswith("/api/network/"):
            actions = {
                "/api/network/imaging": "network imaging",
                "/api/network/backhaul": "network backhaul",
                "/api/network/hotspot": "network hotspot",
                "/api/network/check": "network check",
                "/api/network/hotspot-clients": "network hotspot-clients",
            }
            if path not in actions:
                return self.json({"ok": False, "error": "Unknown network action"}, 404)
            def network():
                u, p = root_args()
                parts = actions[path].split()
                if path == "/api/network/imaging":
                    parts += [str(body.get(k, "") or "") for k in ("iface", "ip", "prefix", "start", "end", "netmask", "router", "bootfile")]
                elif path == "/api/network/backhaul":
                    parts += [str(body.get(k, "") or "") for k in ("iface", "mode", "address", "prefix", "gateway", "dns", "ssid", "password", "hidden")]
                elif path == "/api/network/hotspot":
                    parts += [str(body.get(k, "") or "") for k in ("iface", "ssid", "passphrase", "channel", "ip", "prefix", "start", "end")]
                elif path == "/api/network/hotspot-clients":
                    parts += [str(body.get("iface", "") or "")]
                return run_privileged(u, p, parts)
            return self.guarded(network)
        if path == "/api/system/service":
            def service_action():
                u, p = root_args()
                name = str(body.get("name", "") or "")
                action = str(body.get("action", "") or "")
                if name not in ("dnsmasq", "jog-imaging-api", "apache2", "mariadb", "tftpd-hpa", "jog-jogemetry-hotspot", "jog-jogemetry-dnsmasq") or action not in ("start", "stop", "restart"):
                    raise ApiError("Unsupported service action", 400)
                return run_privileged(u, p, ["service", name, action])
            return self.guarded(service_action)
        if path == "/api/system/logs":
            def logs():
                u, p = root_args()
                unit = str(body.get("unit", "") or "jog-imaging-api")
                allowed = ("jog-imaging-api", "dnsmasq", "apache2", "mariadb", "tftpd-hpa", "jog-jogemetry-hotspot", "jog-jogemetry-dnsmasq")
                if unit not in allowed:
                    raise ApiError("Unsupported log source", 400)
                return run_privileged(u, p, ["logs", unit])
            return self.guarded(logs)
        if path == "/api/safety/check":
            def safety():
                u, p = root_args()
                iface = str(body.get("iface", "") or load_env(JOG_ENV_FILE).get("JOG_USB_IFACE", ""))
                ip = str(body.get("ip", "") or load_env(JOG_ENV_FILE).get("JOG_IMAGING_IP", ""))
                return run_privileged(u, p, ["safety", "check", iface, ip])
            return self.guarded(safety)
        if path == "/api/drivers/check":
            def drivers():
                u, p = root_args()
                return run_privileged(u, p, ["drivers", "check"])
            return self.guarded(drivers)
        return self.json({"ok": False, "error": "Unknown API action"}, 404)

    def do_DELETE(self):
        path = self.route()
        body = self.body()
        m = re.fullmatch(r"/api/fog/(hosts|sessions|tasks)/(\d+)", path)
        if not m:
            return self.json({"ok": False, "error": "Unknown delete action"}, 404)
        if self.demo:
            return self.json({"ok": True, "demo": True})
        def delete():
            u, p = require_root(body)
            kind, ident = m.group(1), m.group(2)
            if kind == "tasks":
                return run_privileged(u, p, ["fog-task-delete", ident])
            endpoint = {"hosts": "/host/%s/delete", "sessions": "/multicastsession/%s/delete"}[kind] % ident
            resp = fog_request("DELETE", endpoint)
            return {"ok": True, "response": resp}
        return self.guarded(delete)

    def log_message(self, fmt, *args):
        sys.stderr.write("jog-portal: " + fmt % args + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--port", type=int, default=int(os.environ.get("JOG_IMAGING_PORT", os.environ.get("JOG_IMAGING_PORT", "8088"))))
    a = ap.parse_args()
    Handler.demo = a.demo
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print("jog-portal on http://127.0.0.1:%d (%s)" % (a.port, "demo" if a.demo else "live"), file=sys.stderr)
    srv.serve_forever()


if __name__ == "__main__":
    main()
