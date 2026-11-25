#!/bin/bash
set -euo pipefail
out=/run/jog-vnc-targets
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
while IFS= read -r vm; do
  [[ -z "$vm" ]] && continue
  disp=$(virsh vncdisplay "$vm" 2>/dev/null | head -1 | tr -d '\r' | xargs) || continue
  [[ -z "$disp" ]] && continue
  host=127.0.0.1 port=
  if [[ "$disp" =~ ^([0-9.]+|\[[0-9a-fA-F:]+\]):([0-9]+)$ ]]; then host=${BASH_REMATCH[1]}; port=$((5900+${BASH_REMATCH[2]})); 
  elif [[ "$disp" =~ ^:([0-9]+)$ ]]; then port=$((5900+${BASH_REMATCH[1]})); fi
  [[ -n "$port" ]] || continue
  printf '%s: %s:%s\n' "$vm" "$host" "$port" >> "$tmp"
done < <(virsh list --all --name 2>/dev/null || true)
install -m 0600 "$tmp" "$out"
