#!/bin/bash
set -euo pipefail
exec 2>>/tmp/mist_error.log

# mist-post-fog-setup.sh — apply the corporate profile after FOG is installed.
#
# Called by mist-fog-install-once.sh when native FOG finishes, and by
# mist-provision-stack.sh when the FOG marker already exists.
#
#   JOG_DRIVER_SHARE_ENABLE=1   -> mist-driver-share.sh --apply
#   JOG_MODEL_API_ENABLE=1      -> mist-model-api-setup.sh --apply
#   JOG_AUTOJOIN_ENABLE=1       -> mist-autojoin-setup.sh --apply
#   JOG_MULTICAST_TUNE=1        -> mist-multicast-tune.sh --apply
#   JOG_PROVISIONING_ENABLE=1   -> mist-install-provisioner.sh
#
# Each step is independent: one failure does not stop the others.

log()  { echo "[mist-post-fog-setup] $*"; }
warn() { echo "[mist-post-fog-setup] WARN: $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

[[ -f /etc/mist/mist.env ]] || { log "no /etc/mist/mist.env; nothing to do"; exit 0; }
set -a
# shellcheck disable=SC1091
source /etc/mist/mist.env
set +a

if [[ "${MIST_DRIVER_SHARE_ENABLE:-${JOG_DRIVER_SHARE_ENABLE:-0}}" == "1" ]]; then
  if [[ -x /usr/local/sbin/mist-driver-share.sh ]]; then
    log "applying the driver share"
    /usr/local/sbin/mist-driver-share.sh --apply || warn "driver share apply failed"
  else
    warn "mist-driver-share.sh is not installed"
  fi
fi

if [[ "${MIST_MODEL_API_ENABLE:-${JOG_MODEL_API_ENABLE:-0}}" == "1" ]]; then
  if [[ -x /usr/local/sbin/mist-model-api-setup.sh ]]; then
    log "installing the read-only FOG model API"
    /usr/local/sbin/mist-model-api-setup.sh --apply || warn "model API setup failed"
  else
    warn "mist-model-api-setup.sh is not installed"
  fi
fi

if [[ "${MIST_AUTOJOIN_ENABLE:-${JOG_AUTOJOIN_ENABLE:-0}}" == "1" ]]; then
  if [[ -x /usr/local/sbin/mist-autojoin-setup.sh ]]; then
    log "installing the JOS multicast auto-join endpoint"
    /usr/local/sbin/mist-autojoin-setup.sh --apply || warn "auto-join endpoint setup failed"
  else
    warn "mist-autojoin-setup.sh is not installed"
  fi
fi

if [[ "${MIST_MULTICAST_TUNE:-${JOG_MULTICAST_TUNE:-0}}" == "1" ]]; then
  if [[ -x /usr/local/sbin/mist-multicast-tune.sh ]]; then
    log "applying the multicast profile"
    /usr/local/sbin/mist-multicast-tune.sh --apply || warn "multicast tune failed"
  else
    warn "mist-multicast-tune.sh is not installed"
  fi
fi

if [[ "${MIST_PROVISIONING_ENABLE:-${JOG_PROVISIONING_ENABLE:-0}}" == "1" ]]; then
  if [[ -x /usr/local/sbin/mist-install-provisioner.sh ]]; then
    log "installing the Windows provisioning payload"
    /usr/local/sbin/mist-install-provisioner.sh || warn "provisioner install failed"
  else
    warn "mist-install-provisioner.sh is not installed"
  fi
fi

log "done"
