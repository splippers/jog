#!/bin/bash
set -e
exec 2>>/tmp/jog_error.log

# Writes a minimal HTML dashboard for the Chromium kiosk (extra tab).

OUT_DIR="${JOG_STATUS_DIR:-/var/lib/jog/status}"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/index.html"
TMP="${OUT}.tmp"

{
  echo "<!DOCTYPE html><html><head><meta charset='utf-8'><meta http-equiv='refresh' content='10'>"
  echo "<title>JOG status</title><style>body{font-family:system-ui;margin:1rem;}pre{white-space:pre-wrap;background:#111;color:#eee;padding:1rem;border-radius:8px;}</style></head><body>"
  echo "<h1>JOG — imaging link + host</h1><p>Auto-refresh every 10s.</p>"

  echo "<h2>Addresses</h2><pre>"
  ip -br addr 2>/dev/null || true
  echo "</pre><h2>Routes</h2><pre>"
  ip route 2>/dev/null || true
  echo "</pre><h2>dnsmasq</h2><pre>"
  systemctl is-active dnsmasq 2>/dev/null || true
  systemctl status dnsmasq --no-pager -l 2>/dev/null | head -n 20 || true
  echo "</pre><h2>FOG services (native /opt/fog)</h2><pre>"
  for u in apache2 mariadb tftpd-hpa; do
    echo -n "$u: "
    systemctl is-active "$u" 2>/dev/null || echo "(stopped or not installed)"
  done
  echo ""
  ss -ltnp 2>/dev/null | grep -E ':80|:443' | head -n 10 || true
  echo "</pre><h2>Listening UDP (69 TFTP / imaging-related)</h2><pre>"
  ss -lunp 2>/dev/null | head -n 40 || true
  echo "</pre></body></html>"
} >"$TMP"
mv -f "$TMP" "$OUT"
