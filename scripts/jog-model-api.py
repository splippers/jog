#!/usr/bin/env python3
"""JOG model inventory API.

Reads the FOG database on the appliance and exposes the distinct hardware
models that have checked in. The Windows driver-sync script uses this instead
of talking to MySQL directly or scraping the FOG web UI.

  jog-model-api.py --serve          # systemd service (default)
  jog-model-api.py --once           # print the JSON once and exit
  jog-model-api.py --check          # verify the DB connection and token

GET /healthz       liveness, no token
GET /api/models    model inventory, Authorization: Bearer <token>

Configuration: /etc/jog/model-api.env (0600 root:fogproject)
  JOG_MODEL_API_BIND=0.0.0.0
  JOG_MODEL_API_PORT=8089
  JOG_MODEL_API_TOKEN=<random token>
  JOG_MODEL_API_DB_CNF=/etc/jog/model-api.my.cnf

The DB credentials stay in a MySQL option file readable only by root and the
service account. The HTTP API never accepts SQL or a model name from a caller.
"""
import argparse
import hmac
import json
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ENV_FILE = os.environ.get("JOG_MODEL_API_ENV", "/etc/jog/model-api.env")
DEFAULT_CNF = os.environ.get("JOG_MODEL_API_DB_CNF", "/etc/jog/model-api.my.cnf")
SCHEMA_VERSION = 1


def load_env(path):
    values = {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def model_slug(value):
    """Match the Windows provisioner's ConvertTo-JOGSlug output."""
    return re.sub(r"[^A-Z0-9]+", "-", (value or "").upper()).strip("-")


def vendor_name(manufacturer):
    name = (manufacturer or "").strip()
    low = name.lower()
    if low.startswith("dell"):
        return "Dell"
    if low.startswith("hp") or "hewlett" in low:
        return "HP"
    if low.startswith("lenovo"):
        return "Lenovo"
    return name or "Unknown"


def query_models(cnf):
    """Return the distinct inventory models, newest FOG inventory only."""
    if not cnf or not os.path.isfile(cnf):
        raise RuntimeError(f"MySQL option file not found: {cnf}")
    sql = """
SET SESSION group_concat_max_len = 1000000;
SELECT
    i.iSysman,
    i.iSysproduct,
    i.iSysversion,
    i.iMbproductname,
    COUNT(DISTINCT h.hostID) AS host_count,
    GROUP_CONCAT(DISTINCT h.hostName ORDER BY h.hostName SEPARATOR ',') AS host_names
FROM inventory i
JOIN hosts h ON h.hostID = i.iHostID
WHERE (i.iDeleteDate IS NULL OR i.iDeleteDate = '0000-00-00 00:00:00')
  AND TRIM(i.iSysproduct) <> ''
GROUP BY i.iSysman, i.iSysproduct, i.iSysversion, i.iMbproductname
ORDER BY i.iSysman, i.iSysproduct;
"""
    command = [
        "mysql",
        f"--defaults-extra-file={cnf}",
        "--batch",
        "--skip-column-names",
        "--raw",
        "-e",
        sql,
    ]
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("mysql client is not installed") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("FOG database query timed out") from exc
    if result.returncode != 0:
        detail = (result.stderr or "").strip().splitlines()
        raise RuntimeError(detail[-1] if detail else "FOG database query failed")

    models = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < 6:
            continue
        manufacturer, model, version, product, count, host_names = fields[:6]
        model = model.strip()
        if not model:
            continue
        try:
            host_count = int(count)
        except ValueError:
            host_count = 0
        hosts = [name for name in host_names.split(",") if name]
        models.append(
            {
                "manufacturer": manufacturer.strip(),
                "model": model,
                "version": version.strip(),
                "product": product.strip(),
                "vendor": vendor_name(manufacturer),
                "slug": model_slug(model),
                "count": host_count,
                "hosts": hosts,
            }
        )
    return models


def build_document(cnf):
    models = query_models(cnf)
    return {
        "ok": True,
        "schema": SCHEMA_VERSION,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "count": len(models),
        "models": models,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "JOGModelAPI/1"
    token = ""
    cnf = DEFAULT_CNF

    def _send_json(self, status, document):
        body = json.dumps(document, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if not self.token:
            return False
        header = self.headers.get("Authorization", "")
        if not header.lower().startswith("bearer "):
            return False
        return hmac.compare_digest(header[7:].strip(), self.token)

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/healthz":
            self._send_json(200, {"ok": True, "service": "jog-model-api"})
            return
        if path != "/api/models":
            self._send_json(404, {"ok": False, "error": "not found"})
            return
        if not self._authorized():
            self._send_json(401, {"ok": False, "error": "unauthorized"})
            return
        try:
            self._send_json(200, build_document(self.cnf))
        except Exception as exc:  # noqa: BLE001 - the HTTP boundary reports the error
            self._send_json(503, {"ok": False, "error": str(exc)})

    def log_message(self, fmt, *args):
        sys.stderr.write(
            "%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), fmt % args)
        )


def main():
    parser = argparse.ArgumentParser(description="JOG FOG model inventory API")
    parser.add_argument("--serve", action="store_true", help="run the HTTP service (default)")
    parser.add_argument("--once", action="store_true", help="print the model JSON once")
    parser.add_argument("--check", action="store_true", help="verify the DB and token")
    parser.add_argument("--env-file", default=ENV_FILE)
    parser.add_argument("--db-cnf", default=DEFAULT_CNF)
    parser.add_argument("--bind", default="")
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()

    env = load_env(args.env_file)
    cnf = args.db_cnf or env.get("JOG_MODEL_API_DB_CNF", DEFAULT_CNF)
    token = env.get("JOG_MODEL_API_TOKEN", "")

    if args.once:
        print(json.dumps(build_document(cnf), indent=2, ensure_ascii=False))
        return 0

    if args.check:
        try:
            document = build_document(cnf)
        except Exception as exc:  # noqa: BLE001
            print(f"jog-model-api: ERROR: {exc}", file=sys.stderr)
            return 1
        print(f"jog-model-api: OK: {document['count']} model(s)")
        if not token:
            print("jog-model-api: ERROR: JOG_MODEL_API_TOKEN is empty", file=sys.stderr)
            return 1
        return 0

    if not token:
        print("jog-model-api: ERROR: JOG_MODEL_API_TOKEN is empty", file=sys.stderr)
        return 1

    bind = args.bind or env.get("JOG_MODEL_API_BIND", "0.0.0.0")
    port = args.port or int(env.get("JOG_MODEL_API_PORT", "8089"))
    Handler.token = token
    Handler.cnf = cnf
    server = ThreadingHTTPServer((bind, port), Handler)
    print(f"jog-model-api: listening on {bind}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
