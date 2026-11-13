#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log

# jog-post-fog-setup.sh — apply the corporate profile after FOG is installed.
#
# Called by jog-fog-install-once.sh when native FOG finishes, and by
# jog-provision-stack.sh when the FOG marker already exists.
#
#   JOG_DRIVER_SHARE_ENABLE=1   -> jog-driver-share.sh --apply
#   JOG_MODEL_API_ENABLE=1      -> jog-model-api-setup.sh --apply
#   JOG_AUTOJOIN_ENABLE=1       -> jog-autojoin-setup.sh --apply
#   JOG_MULTICAST_TUNE=1        -> jog-multicast-tune.sh --apply
#   JOG_PROVISIONING_ENABLE=1   -> jog-install-provisioner.sh
#
# Each step is independent: one failure does not stop the others.

log()  { echo "[jog-post-fog-setup] $*"; }
warn() { echo "[jog-post-fog-setup] WARN: $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

[[ -f /etc/jog/jog.env ]] || { log "no /etc/jog/jog.env; nothing to do"; exit 0; }
set -a
# shellcheck disable=SC1091
source /etc/jog/jog.env
set +a

if [[ "${JOG_DRIVER_SHARE_ENABLE:-0}" == "1" ]]; then
  if [[ -x /usr/local/sbin/jog-driver-share.sh ]]; then
    log "applying the driver share"
    /usr/local/sbin/jog-driver-share.sh --apply || warn "driver share apply failed"
  else
    warn "jog-driver-share.sh is not installed"
  fi
fi

if [[ "${JOG_MODEL_API_ENABLE:-0}" == "1" ]]; then
  if [[ -x /usr/local/sbin/jog-model-api-setup.sh ]]; then
    log "installing the read-only FOG model API"
    /usr/local/sbin/jog-model-api-setup.sh --apply || warn "model API setup failed"
  else
    warn "jog-model-api-setup.sh is not installed"
  fi
fi

if [[ "${JOG_AUTOJOIN_ENABLE:-0}" == "1" ]]; then
  if [[ -x /usr/local/sbin/jog-autojoin-setup.sh ]]; then
    log "installing the JOS multicast auto-join endpoint"
    /usr/local/sbin/jog-autojoin-setup.sh --apply || warn "auto-join endpoint setup failed"
  else
    warn "jog-autojoin-setup.sh is not installed"
  fi
fi

if [[ "${JOG_MULTICAST_TUNE:-0}" == "1" ]]; then
  if [[ -x /usr/local/sbin/jog-multicast-tune.sh ]]; then
    log "applying the multicast profile"
    /usr/local/sbin/jog-multicast-tune.sh --apply || warn "multicast tune failed"
  else
    warn "jog-multicast-tune.sh is not installed"
  fi
fi

if [[ "${JOG_PROVISIONING_ENABLE:-0}" == "1" ]]; then
  if [[ -x /usr/local/sbin/jog-install-provisioner.sh ]]; then
    log "installing the Windows provisioning payload"
    /usr/local/sbin/jog-install-provisioner.sh || warn "provisioner install failed"
  else
    warn "jog-install-provisioner.sh is not installed"
  fi
fi

log "done"
