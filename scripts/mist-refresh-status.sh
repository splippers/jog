#!/bin/bash
set -e
exec 2>>/tmp/mist_error.log

# Writes a minimal HTML dashboard for the Chromium kiosk (extra tab).

OUT_DIR="${MIST_STATUS_DIR:-${MIST_STATUS_DIR:-${JOG_STATUS_DIR:-/var/lib/mist/status}}}"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/index.html"
ln -sf index.html "$OUT_DIR/index"
TMP="${OUT}.tmp"
BATTERY_HELPER="${MIST_BATTERY_HELPER:-${MIST_BATTERY_HELPER:-${JOG_BATTERY_HELPER:-/usr/local/sbin/mist-battery.sh}}}"

battery_html() {
  local raw=""
  if [[ -x $BATTERY_HELPER ]]; then
    raw=$("$BATTERY_HELPER" 2>/dev/null || true)
  fi
  if [[ -z $raw ]]; then
    echo "<p class=\"battery-note\">Battery not detected.</p>"
    return
  fi
  printf '%s' "$raw" | python3 -c '
import html, json, sys

def e(v):
    return html.escape("" if v is None else str(v))

def fmt(v, suffix=""):
    return "-" if v is None or v == "" else e(v) + suffix

def fixed(v, digits=1):
    try:
        return ("%." + str(digits) + "f") % float(v)
    except (TypeError, ValueError):
        return "-"

try:
    b = json.load(sys.stdin)
except Exception:
    b = {}

if not isinstance(b, dict) or not b.get("present"):
    print("<p class=\"battery-note\">Battery not detected.</p>")
    raise SystemExit(0)

pct = b.get("percentage")
try:
    p = float(pct)
except (TypeError, ValueError):
    p = None
level = "-" if p is None else "%.0f%%" % p
width = 0.0 if p is None else max(0.0, min(100.0, p))
bar_class = "" if p is None or p >= 60 else " fair" if p >= 30 else " poor"
print("<div class=\"battery-level\"><span class=\"battery-bar" + bar_class + "\"><i style=\"width:" + ("%.1f" % width) + "%\"></i></span><strong>" + level + "</strong></div>")

health = b.get("healthPercent")
label = str(b.get("healthLabel") or "Unknown")
try:
    health_text = "%.1f%% %s" % (float(health), label) if health is not None else "-"
except (TypeError, ValueError):
    health_text = label
hclass = label.lower() if label.lower() in ("good", "fair", "poor") else ""

state = b.get("state")
state_text = fmt(str(state).replace("-", " ").title() if state else "-")
device = " ".join([e(x) for x in (b.get("vendor"), b.get("model")) if x])

remaining = b.get("timeToEmpty") or b.get("timeToFull")
time_text = fmt(remaining)
if remaining:
    time_text += " to empty" if b.get("timeToEmpty") else " to full"

rows = [
    ("Level", level, ""),
    ("Health", health_text, hclass),
    ("State", state_text, ""),
    ("Model", device or "-", ""),
    ("Cycles", fmt(b.get("cycles")), ""),
    ("Time remaining", time_text, ""),
    ("Energy full / design", fixed(b.get("energyFullWh")) + " / " + fixed(b.get("energyDesignWh")) + " Wh", ""),
    ("Warning", fmt(b.get("warning")), "poor" if any(x in str(b.get("warning") or "").lower() for x in ("low", "critical")) else ""),
]
print("<div class=\"battery-kv\">")
for key, value, cls in rows:
    attr = " class=\"" + cls + "\"" if cls else ""
    print("<div><span>" + e(key) + "</span><span" + attr + ">" + value + "</span></div>")
print("</div>")
' || echo "<p class=\"battery-note\">Battery data unavailable.</p>"
}

{
  echo "<!DOCTYPE html><html><head><meta charset='utf-8'><meta http-equiv='refresh' content='10'>"
  echo "<title>MIST status</title><style>body{font-family:system-ui;margin:1rem;}pre{white-space:pre-wrap;background:#111;color:#eee;padding:1rem;border-radius:8px;}.battery-level{display:flex;align-items:center;gap:10px;margin:.5rem 0 1rem}.battery-bar{display:inline-block;width:240px;height:10px;border-radius:999px;background:#0b1118;border:1px solid #263544;overflow:hidden}.battery-bar i{display:block;height:100%;background:#35d1a4}.battery-bar.fair i{background:#ffc857}.battery-bar.poor i{background:#ff6b6b}.battery-kv{display:grid;max-width:560px;gap:6px}.battery-kv>div{display:flex;justify-content:space-between;gap:16px;border-bottom:1px dashed #263544;padding-bottom:5px}.battery-kv>div>span:first-child{color:#9db0c2}.good{color:#35d1a4}.fair{color:#ffc857}.poor{color:#ff6b6b}.battery-note{color:#ffc857}</style></head><body>"
  echo "<h1>MIST — imaging link + host</h1><p>Auto-refresh every 10s.</p>"

  echo "<h2>Addresses</h2><pre>"
  ip -br addr 2>/dev/null || true
  echo "</pre><h2>Routes</h2><pre>"
  ip route 2>/dev/null || true
  echo "</pre><h2>Battery</h2>"
  battery_html
  echo "<h2>dnsmasq</h2><pre>"
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
