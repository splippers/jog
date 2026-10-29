#!/bin/bash
set -e
exec 2>>/tmp/jog_error.log

# Multi-tab Chromium on X11 (ozone/x11) for reliable kiosk on Intel iGPU laptops.
# Requires /etc/jog/jog.env with JOG_FOG_URL and optional JOG_STATUS_URL.

JOG_ENV="${JOG_ENV:-/etc/jog/jog.env}"
[[ -f "$JOG_ENV" ]] || exit 0
# shellcheck disable=SC1090
source "$JOG_ENV"

: "${JOG_FOG_URL:=http://localhost/fog/management/}"
: "${JOG_FOG_TASKS_URL:=}"
: "${JOG_STATUS_URL:=file:///var/lib/jog/status/index.html}"
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
  --disable-session-crashed-bubble
  --disable-infobars
  --start-maximized
  --new-window
)

# Optional extra flags from jog.env (space-separated)
if [[ -n "${JOG_CHROMIUM_EXTRA_FLAGS:-}" ]]; then
  # shellcheck disable=SC2206
  CH_FLAGS+=(${JOG_CHROMIUM_EXTRA_FLAGS})
fi

run_once() {
  local -a TABS
  TABS=( "$JOG_FOG_URL" )
  if [[ -n "${JOG_FOG_TASKS_URL:-}" && "${JOG_FOG_TASKS_URL}" != "${JOG_FOG_URL}" ]]; then
    TABS+=( "$JOG_FOG_TASKS_URL" )
  fi
  TABS+=( "$JOG_STATUS_URL" )
  GDK_BACKEND=x11 "$CHROME" "${CH_FLAGS[@]}" "${TABS[@]}"
}

if [[ "${JOG_CHROMIUM_RESTART}" == "1" ]]; then
  while true; do
    run_once || true
    sleep 2
  done
else
  run_once
fi
