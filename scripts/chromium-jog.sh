#!/bin/bash
set -e
exec 2>>"${JOG_KIOSK_LOG:-/tmp/jog-kiosk-$(id -un).log}"

LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/jog-chromium.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

# Multi-tab Chromium on X11 (ozone/x11) for reliable kiosk on Intel iGPU laptops.
# Requires /etc/jog/jog.env with JOG_FOG_URL and optional JOG_STATUS_URL.

JOG_ENV="${JOG_ENV:-/etc/jog/jog.env}"
[[ -f "$JOG_ENV" ]] || exit 0
# shellcheck disable=SC1090
source "$JOG_ENV"

if command -v openbox >/dev/null 2>&1 && ! pgrep -x openbox >/dev/null 2>&1; then
  openbox --sm-disable >/dev/null 2>&1 &
fi

: "${JOG_FOG_URL:=http://localhost/fog/management/}"
: "${JOG_FOG_TASKS_URL:=}"
: "${JOG_STATUS_URL:=http://127.0.0.1:8088/jog/status/index.html}"
: "${JOG_IMAGING_URL:=http://127.0.0.1:8088/}"
: "${JOG_CHROMIUM_RESTART:=1}"

CHROME="${CHROME:-}"
for c in chromium chromium-browser google-chrome; do
  if command -v "$c" >/dev/null 2>&1; then
    CHROME="$c"
    break
  fi
done
[[ -n "$CHROME" ]] || exit 0

# Always use X11 — avoids Wayland/Ozone issues when the desktop defaults to Wayland for other users.
CH_FLAGS=(
  --ozone-platform=x11
  --no-first-run
  --no-default-browser-check
  --disable-session-crashed-bubble
  --disable-infobars
  --start-fullscreen
  --new-window
)

screen_geometry() {
  local line token
  while read -r line; do
    [[ "$line" == *" connected"* ]] || continue
    for token in $line; do
      if [[ "$token" =~ ^[0-9]+x[0-9]+ ]]; then
        printf '%s' "${token%%+*}"
        return
      fi
    done
  done < <(xrandr --current 2>/dev/null)
}

SCREEN_GEOMETRY=$(screen_geometry)
if [[ "$SCREEN_GEOMETRY" =~ ^([0-9]+)x([0-9]+)$ ]]; then
  CH_FLAGS+=(--window-position=0,0 "--window-size=$((BASH_REMATCH[1] + 1)),$((BASH_REMATCH[2] + 1))")
fi

# Optional extra flags from jog.env (space-separated)
if [[ -n "${JOG_CHROMIUM_EXTRA_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CH_FLAGS+=(${JOG_CHROMIUM_EXTRA_FLAGS})
fi

run_once() {
  local -a TABS
  TABS=()
  [[ -n "$JOG_IMAGING_URL" ]] && TABS+=( "$JOG_IMAGING_URL" )
  TABS+=( "$JOG_FOG_URL" )
  if [[ -n "${JOG_FOG_TASKS_URL:-}" && "${JOG_FOG_TASKS_URL}" != "${JOG_FOG_URL}" ]]; then
    TABS+=( "$JOG_FOG_TASKS_URL" )
  fi
  TABS+=( "$JOG_STATUS_URL" )
  GDK_BACKEND=x11 "$CHROME" "${CH_FLAGS[@]}" "${TABS[@]}"
}

if [[ "${JOG_CHROMIUM_RESTART}" == "1" ]]; then
  while true; do
    run_once || true
    sleep 5
  done
else
  run_once
fi
