#!/usr/bin/env python3
"""Create a HAARMETRY enrollment QR for pairing an Android client.

The QR encodes a `jogemetry://connect/?d=...` deep link. Scanning it with the
phone camera opens the Haarmetry app and fills in the API URL and bearer
token, so no secret is ever baked into the APK and nobody has to paste a
128-character token by hand.

The link is a credential: treat the QR PNG like the token file. Generate it
on the appliance, and delete it after the client has enrolled.

Usage:
  sudo jog-qr                      # writes /tmp/jogemetry-connect.png
  sudo jog-qr --terminal           # prints the QR in the terminal
  sudo jog-qr --link-only          # prints just the deep link
  sudo jog-qr --output /path/qr.png
  sudo jog-qr --check              # validate inputs, print summary only
"""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys

DEFAULT_ENV = "/etc/jog/mobile-api.env"
DEFAULT_CERT = "/etc/jog/mobile-cert.pem"
DEFAULT_OUTPUT = "/tmp/jogemetry-connect.png"


def read_env(path):
    values = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                value = value.strip()
                if len(value) > 1 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                values[key.strip()] = value
    except OSError as exc:
        raise SystemExit("ERROR: cannot read %s: %s" % (path, exc))
    return values


def spki_pin(cert_path):
    """SHA-256 of the certificate's SubjectPublicKeyInfo, base64 encoded.

    This is the same value pinned in the app's network_security_config.xml.
    Including it in the QR lets the app show/confirm which appliance issued
    the link; the app's build-time pin remains authoritative.
    """
    try:
        pubkey = subprocess.run(
            ["openssl", "x509", "-in", cert_path, "-pubkey", "-noout"],
            check=True, capture_output=True
        ).stdout
        der = subprocess.run(
            ["openssl", "pkey", "-pubin", "-outform", "DER"],
            input=pubkey, check=True, capture_output=True
        ).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise SystemExit("ERROR: cannot derive SPKI pin from %s: %s" % (cert_path, exc))
    return base64.b64encode(hashlib.sha256(der).digest()).decode("ascii")


def build_payload(args):
    env = read_env(args.env)
    token = env.get("JOG_MOBILE_TOKEN", "").strip()
    if not token:
        raise SystemExit(
            "ERROR: JOG_MOBILE_TOKEN is empty in %s" % args.env
        )

    if args.url:
        url = args.url
    else:
        bind = env.get("JOG_MOBILE_BIND", "10.42.0.1").strip()
        port = env.get("JOG_MOBILE_PORT", "8443").strip()
        if bind in ("", "0.0.0.0", "*"):
            bind = "10.42.0.1"
        url = "https://%s:%s" % (bind, port)

    cert_path = args.cert or env.get("JOG_MOBILE_TLS_CERT", DEFAULT_CERT)
    payload = {
        "v": 1,
        "url": url,
        "token": token,
        "pin": spki_pin(cert_path),
    }

    # WiFi details are optional. Add JOG_WIFI_SSID / JOG_WIFI_PSK to the env
    # file if clients should also be told how to reach the hidden AP.
    if not args.no_wifi:
        ssid = env.get("JOG_WIFI_SSID", "").strip()
        psk = env.get("JOG_WIFI_PSK", "").strip()
        if ssid:
            payload["ssid"] = ssid
        if psk:
            payload["psk"] = psk

    return payload


def encode_link(payload):
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    data = base64.urlsafe_b64encode(raw.encode("utf-8")).decode("ascii").rstrip("=")
    return "jogemetry://connect/?d=" + data


def render_qr(link, output, terminal):
    try:
        if terminal:
            subprocess.run(
                ["qrencode", "-t", "ANSIUTF8", "-s", "1", link], check=True
            )
            return
        cmd = ["qrencode", "-s", "6", "-m", "2"]
        if output == "-":
            cmd += ["-o", "-"]
        else:
            cmd += ["-o", output]
        cmd.append(link)
        subprocess.run(cmd, check=True)
    except FileNotFoundError:
        raise SystemExit("ERROR: qrencode is not installed (apt install qrencode)")
    except subprocess.CalledProcessError as exc:
        raise SystemExit("ERROR: qrencode failed: %s" % exc)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", default=DEFAULT_ENV)
    parser.add_argument("--cert", default=None)
    parser.add_argument("--url", default=None, help="override the API base URL")
    parser.add_argument("--output", default=DEFAULT_OUTPUT,
                        help="PNG path, or - for PNG on stdout")
    parser.add_argument("--terminal", action="store_true",
                        help="print an ANSI QR instead of writing a PNG")
    parser.add_argument("--link-only", action="store_true",
                        help="print only the deep link")
    parser.add_argument("--json", action="store_true",
                        help="print the decoded payload as JSON")
    parser.add_argument("--reveal", action="store_true",
                        help="with --json, include the real token")
    parser.add_argument("--no-wifi", action="store_true",
                        help="omit optional WiFi credentials")
    parser.add_argument("--check", action="store_true",
                        help="validate inputs and print a summary only")
    args = parser.parse_args()

    payload = build_payload(args)
    link = encode_link(payload)

    if args.link_only:
        print(link)
        return
    if args.json:
        shown = dict(payload)
        if not args.reveal:
            shown["token"] = "<redacted>"
        print(json.dumps(shown, indent=2))
        return
    if args.check:
        print("OK  url=%s  pin=%s  token=%d chars  wifi=%s" % (
            payload["url"], payload["pin"], len(payload["token"]),
            "yes" if "ssid" in payload else "no"))
        return

    render_qr(link, args.output, args.terminal)
    if not args.terminal and args.output != "-":
        os.chmod(args.output, 0o600)
        print("QR written to %s (mode 0600)" % args.output)
    print("Scan with the phone camera, or paste this link in Settings:")
    print(link)
    print("This link contains the bearer token. Delete the QR after enrolling.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
