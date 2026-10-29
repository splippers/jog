#!/usr/bin/env python3
"""JOG live imaging view: tiny local API + static file server for the kiosk page.

GET /api/devices   normalized imaging state (from FOG's task API, or generated demo data)
GET /              kiosk/imaging/ static files

The FOG API tokens are read here, server-side, from JOG_FOG_API_ENV (default /etc/jog/fog-api.env) and never
reach the browser. Binds to 127.0.0.1 only. Standard library only, so it runs on a stock Ubuntu appliance.

  jog-imaging-api.py            serve live data
  jog-imaging-api.py --demo     serve generated demo devices (no FOG needed; for design and testing)
"""
import argparse, json, math, os, random, sys, time, urllib.request, urllib.error
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ENV_FILE = os.environ.get("JOG_FOG_API_ENV", "/etc/jog/fog-api.env")
STATIC = os.environ.get("JOG_IMAGING_STATIC", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "kiosk", "imaging"))


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


def pick(d, *keys, default=None):
    """First present, non-empty value among several possible FOG field names."""
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


def phase_of(state_name):
    s = (state_name or "").lower()
    if "progress" in s:
        return "imaging"
    if "queue" in s or "check" in s:
        return "queued"
    if "complete" in s:
        return "complete"
    if "cancel" in s or "fail" in s:
        return "failed"
    return "queued"


def normalize_task(t):
    host = t.get("host") if isinstance(t.get("host"), dict) else {}
    image = t.get("image") if isinstance(t.get("image"), dict) else {}
    ttype = t.get("type") if isinstance(t.get("type"), dict) else {}
    state = t.get("state") if isinstance(t.get("state"), dict) else {}
    state_name = pick(state, "name", default=pick(t, "stateName", default=""))
    type_name = pick(ttype, "name", default=pick(t, "typeName", default="Task"))
    return {
        "id": pick(t, "id", "taskID"),
        "host": pick(host, "name", default=pick(t, "hostName", "name", default="unknown host")),
        "mac": pick(host, "primac", "mac", default=pick(t, "mac", default="")),
        "image": pick(image, "name", default=pick(t, "imageName", default="")),
        "kind": type_name,
        "state": state_name,
        "phase": phase_of(state_name),
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
        return None  # FOG answers bad or missing tokens with a redirect to the login page


_opener = urllib.request.build_opener(_NoRedirect)


def fetch_live():
    env = load_env(ENV_FILE)
    base = env.get("JOG_FOG_API_URL", "http://localhost/fog").rstrip("/")
    api, user = env.get("FOG_API_TOKEN", ""), env.get("FOG_USER_TOKEN", "")
    if not api or not user:
        return {"ok": False, "error": "FOG API tokens not configured (%s)" % ENV_FILE, "devices": []}
    req = urllib.request.Request(base + "/task/active", headers={"fog-api-token": api, "fog-user-token": user, "Accept": "application/json"})
    try:
        with _opener.open(req, timeout=6) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        if 300 <= e.code < 400:
            return {"ok": False, "error": "FOG rejected the API tokens or the API is disabled (Settings > API System)", "devices": []}
        return {"ok": False, "error": "FOG API returned HTTP %d" % e.code, "devices": []}
    except (urllib.error.URLError, OSError, ValueError) as e:
        return {"ok": False, "error": "FOG API unreachable: %s" % e, "devices": []}
    tasks = data.get("data", data.get("tasks", data)) if isinstance(data, dict) else data
    devices = [normalize_task(t) for t in (tasks or []) if isinstance(t, dict)]
    return {"ok": True, "devices": devices}


_demo_start = time.time()
_DEMO = [
    ("LT-SITE01-ABC1234", "Win11 Standard", "Deploy", 1.00, 0),
    ("LT-SITE01-ABD2211", "Win11 Standard", "Deploy", 0.80, 20),
    ("DT-SITE01-XYZ5678", "Win11 Engineering", "Deploy", 0.55, 90),
    ("LT-SITE01-QRS9001", "Win11 Standard", "Deploy", 0.90, 150),
    ("LT-SITE01-MNO4410", "Win11 Standard", "Deploy", 0.70, 260),
    ("LT-SITE01-JKL1032", "Win11 Standard", "Multicast", 1.20, 500),
    ("DT-SITE01-TUV7714", "Win11 Engineering", "Deploy", 0.60, 900),
]


def fetch_demo():
    t = time.time() - _demo_start
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


class Handler(SimpleHTTPRequestHandler):
    demo = False

    def __init__(self, *a, **kw):
        super().__init__(*a, directory=STATIC, **kw)

    def do_GET(self):
        if self.path.split("?")[0] == "/api/devices":
            res = fetch_demo() if self.demo else fetch_live()
            res["devices"].sort(key=lambda d: ({"imaging": 0, "queued": 1, "failed": 2, "complete": 3}.get(d["phase"], 4), -d["percent"]))
            res["summary"] = summarize(res["devices"])
            res["updated"] = int(time.time())
            res["mode"] = "demo" if self.demo else "live"
            body = json.dumps(res).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def log_message(self, fmt, *args):
        sys.stderr.write("jog-imaging-api: " + fmt % args + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--port", type=int, default=int(os.environ.get("JOG_IMAGING_PORT", "8088")))
    a = ap.parse_args()
    Handler.demo = a.demo
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print("jog-imaging-api on http://127.0.0.1:%d (%s)" % (a.port, "demo" if a.demo else "live"), file=sys.stderr)
    srv.serve_forever()


if __name__ == "__main__":
    main()
