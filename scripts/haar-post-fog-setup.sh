#!/bin/bash
set -euo pipefail
exec 2>>/tmp/haar_error.log

# haar-post-fog-setup.sh — apply the corporate profile after FOG is installed.
#
# Called by haar-fog-install-once.sh when native FOG finishes, and by
# haar-provision-stack.sh when the FOG marker already exists.
#
#   JOG_DRIVER_SHARE_ENABLE=1   -> haar-driver-share.sh --apply
#   JOG_MODEL_API_ENABLE=1      -> haar-model-api-setup.sh --apply
#   JOG_AUTOJOIN_ENABLE=1       -> haar-autojoin-setup.sh --apply
#   JOG_MULTICAST_TUNE=1        -> haar-multicast-tune.sh --apply
#   JOG_PROVISIONING_ENABLE=1   -> haar-install-provisioner.sh
#
# Each step is independent: one failure does not stop the others.

log()  { echo "[haar-post-fog-setup] $*"; }
warn() { echo "[haar-post-fog-setup] WARN: $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

[[ -f /etc/haar/haar.env ]] || { log "no /etc/haar/haar.env; nothing to do"; exit 0; }
set -a
# shellcheck disable=SC1091
source /etc/haar/haar.env
set +a

if [[ "${Brume_DRIVER_SHARE_ENABLE:-${JOG_DRIVER_SHARE_ENABLE:-0}}" == "1" ]]; then
  if [[ -x /usr/local/sbin/haar-driver-share.sh ]]; then
    log "applying the driver share"
    /usr/local/sbin/haar-driver-share.sh --apply || warn "driver share apply failed"
  else
    warn "haar-driver-share.sh is not installed"
  fi
fi

if [[ "${Brume_MODEL_API_ENABLE:-${JOG_MODEL_API_ENABLE:-0}}" == "1" ]]; then
  if [[ -x /usr/local/sbin/haar-model-api-setup.sh ]]; then
    log "installing the read-only FOG model API"
    /usr/local/sbin/haar-model-api-setup.sh --apply || warn "model API setup failed"
  else
    warn "haar-model-api-setup.sh is not installed"
  fi
fi

if [[ "${Brume_AUTOJOIN_ENABLE:-${JOG_AUTOJOIN_ENABLE:-0}}" == "1" ]]; then
  if [[ -x /usr/local/sbin/haar-autojoin-setup.sh ]]; then
    log "installing the JOS multicast auto-join endpoint"
    /usr/local/sbin/haar-autojoin-setup.sh --apply || warn "auto-join endpoint setup failed"
  else
    warn "haar-autojoin-setup.sh is not installed"
  fi
fi

if [[ "${Brume_MULTICAST_TUNE:-${JOG_MULTICAST_TUNE:-0}}" == "1" ]]; then
  if [[ -x /usr/local/sbin/haar-multicast-tune.sh ]]; then
    log "applying the multicast profile"
    /usr/local/sbin/haar-multicast-tune.sh --apply || warn "multicast tune failed"
  else
    warn "haar-multicast-tune.sh is not installed"
  fi
fi

if [[ "${Brume_PROVISIONING_ENABLE:-${JOG_PROVISIONING_ENABLE:-0}}" == "1" ]]; then
  if [[ -x /usr/local/sbin/haar-install-provisioner.sh ]]; then
    log "installing the Windows provisioning payload"
    /usr/local/sbin/haar-install-provisioner.sh || warn "provisioner install failed"
  else
    warn "haar-install-provisioner.sh is not installed"
  fi
fi

log "done"
