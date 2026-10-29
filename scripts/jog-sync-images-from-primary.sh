#!/bin/bash
set -euo pipefail
exec 2>>/tmp/jog_error.log

# Pull /images from primary JOG over SSH (edge / warm-spare nodes).
# Requires: rsync, SSH key or password auth to JOG_PRIMARY_SSH.

CLUSTER_ENV="${CLUSTER_ENV:-/etc/jog/cluster.env}"
[[ -f "$CLUSTER_ENV" ]] || { echo "Missing $CLUSTER_ENV"; exit 1; }
# shellcheck disable=SC1090
source "$CLUSTER_ENV"

: "${JOG_PRIMARY_SSH:?Set JOG_PRIMARY_SSH in $CLUSTER_ENV}"
: "${JOG_LOCAL_IMAGES_DIR:=/images}"

install -d "$JOG_LOCAL_IMAGES_DIR"

exec rsync -aHAX --numeric-ids --info=progress2 \
  "${JOG_PRIMARY_SSH}:/images/" \
  "${JOG_LOCAL_IMAGES_DIR}/"
