#!/bin/bash
set -euo pipefail
export TERM="${TERM:-linux}"
clear
printf 'Brume replicator first boot\n\n'
printf 'This Brume system is being specialized. Answer the prompts below.\n\n'
export JOG_REPO="${Brume_REPO:-${JOG_REPO:-/opt/Brume/haar}}"
/usr/local/sbin/haar-install-wizard.sh
rm -f /etc/haar/replicator.generic
systemctl disable --now haar-replicator-first-boot.service || true
sync
