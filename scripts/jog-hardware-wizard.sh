#!/bin/bash
# jog-hardware-wizard.sh: detect this laptop's imaging NIC, uplink and faulty USB hubs, and write the
# machine-specific settings so the rest of the system needs no hand editing.
#
#   sudo jog-hardware-wizard            interactive: shows findings, asks before changing anything
#   sudo jog-hardware-wizard --yes      apply the recommended answers without asking (first boot)
#   sudo jog-hardware-wizard --check    report only, change nothing (exit 1 if config is out of date)
#   sudo jog-hardware-wizard --onboard[=IFACE]
#                                        use an ONBOARD port for imaging (e.g. when the only USB NIC is 100 Mbit/s).
#                                        Explicit opt-in: records JOG_ALLOW_ONBOARD_NIC so the DHCP guard permits
#                                        that one interface, and keeps it out of NetworkManager. The guard's
#                                        "is another DHCP server on this link?" probe still protects the office LAN.
#
# Writes (only these keys, nothing else in the file is read or changed):
#   /etc/jog/jog.env : JOG_USB_IFACE, JOG_IMAGING_NIC, JOG_BACKHAUL_IFACE, JOG_USB_QUIET_HUBS
#   /etc/udev/rules.d/99-jog-imaging-nic.rules  (matches the adapter by MAC, so renames do not matter)
#   /etc/udev/rules.d/99-jog-usb-quiet.rules    (one line per faulty hub)
set -u
ENV_FILE="${JOG_ENV:-/etc/jog/jog.env}"
MODE=ask; ONBOARD=0; ONBOARD_IF=""
for arg in "$@"; do
  case "$arg" in
    --yes) MODE=yes ;; --check) MODE=check ;;
    --onboard) ONBOARD=1 ;; --onboard=*) ONBOARD=1; ONBOARD_IF=${arg#--onboard=} ;;
    *) echo "usage: $0 [--yes|--check] [--onboard[=IFACE]]"; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0 $*" >&2; exit 1; }

say() { printf '%s\n' "$*"; }
confirm() { # confirm "question" -> 0 if yes
  [ "$MODE" = yes ] && return 0
  [ "$MODE" = check ] && return 1
  read -r -p "$1 [Y/n] " a; case "${a:-y}" in y|Y|yes) return 0 ;; *) return 1 ;; esac
}
getenvkey() { [ -r "$ENV_FILE" ] && sed -n -E "s/^$1=(.*)$/\1/p" "$ENV_FILE" | tail -1; }
setenvkey() { # setenvkey KEY VALUE (replace in place or append)
  if grep -q -E "^$1=" "$ENV_FILE"; then sed -i -E "s|^$1=.*|$1=$2|" "$ENV_FILE"; else printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"; fi
}

# ---------- 1. imaging NIC: wired, physical, preferably USB ----------
cands=()
for n in /sys/class/net/*; do
  i=$(basename "$n")
  [ -e "$n/device" ] || continue            # virtual (bridge, veth, tun, lo)
  [ -d "$n/wireless" ] && continue          # Wi-Fi
  [ "$(cat "$n/type" 2>/dev/null)" = 1 ] || continue
  cands+=("$i")
done
usb=(); other=()
for i in "${cands[@]}"; do
  if readlink -f "/sys/class/net/$i/device" | grep -q '/usb'; then usb+=("$i"); else other+=("$i"); fi
done
say "== Wired adapters found"
for i in "${cands[@]}"; do
  kind=onboard; readlink -f "/sys/class/net/$i/device" | grep -q '/usb' && kind=USB
  printf '  %-18s %-7s %s  driver=%s\n' "$i" "$kind" "$(cat /sys/class/net/$i/address)" "$(basename "$(readlink -f /sys/class/net/$i/device/driver 2>/dev/null)")"
done
[ ${#cands[@]} -gt 0 ] || { say "No wired adapter found. Plug in the USB Ethernet adapter and run again."; exit 1; }

current=$(getenvkey JOG_USB_IFACE)
# An onboard port that is in use for the normal network (default route or a non-imaging address) is never a candidate.
in_use() { ip -4 route show default 2>/dev/null | grep -q " dev $1 " || ip -4 addr show dev "$1" 2>/dev/null | grep -q "inet "; }
free_other=(); for i in "${other[@]:-}"; do [ -n "$i" ] && ! in_use "$i" && free_other+=("$i"); done
# Unattended runs (boot): a USB adapter can enumerate late, so give it a moment before concluding it is absent.
if [ "$MODE" = yes ] && [ "$ONBOARD" = 0 ] && [ ${#usb[@]} -eq 0 ]; then
  for _ in $(seq 1 30); do
    for n in /sys/class/net/*; do [ -e "$n/device" ] && [ ! -d "$n/wireless" ] && readlink -f "$n/device" | grep -q '/usb' && usb+=("$(basename "$n")"); done
    [ ${#usb[@]} -gt 0 ] && break; sleep 1
  done
fi
pick=""
if [ "$ONBOARD" = 1 ]; then
  say "Onboard imaging requested: choosing a physical wired port (USB adapters are ignored for imaging)."
  if [ -n "$ONBOARD_IF" ]; then
    printf '%s\n' "${other[@]:-}" | grep -qx "$ONBOARD_IF" || { say "$ONBOARD_IF is not an onboard wired port here (found: ${other[*]:-none})."; exit 1; }
    pick=$ONBOARD_IF
  elif [ ${#other[@]} -eq 1 ]; then pick=${other[0]}
  elif [ ${#other[@]} -gt 1 ] && [ "$MODE" = ask ]; then select pick in "${other[@]}"; do [ -n "$pick" ] && break; done
  else say "Name the port: --onboard=IFACE (found: ${other[*]:-none})."; exit 1; fi
  say "NOTE: $pick will serve DHCP/TFTP to the machines being imaged. Cable it to an isolated switch or"
  say "directly to the client, never to the office LAN. The guard checks for another DHCP server before serving."
  in_use "$pick" && say "NOTE: $pick currently carries the normal network (route/address). It will be taken over for imaging."
elif [ ${#usb[@]} -eq 1 ]; then pick=${usb[0]}
elif [ ${#usb[@]} -gt 1 ]; then
  say "More than one USB adapter; the imaging NIC must be the one cabled to the clients."
  if [ "$MODE" = ask ]; then select pick in "${usb[@]}"; do [ -n "$pick" ] && break; done; else pick=${usb[0]}; fi
elif [ "$MODE" = ask ] && [ ${#free_other[@]} -ge 1 ]; then
  say "No USB adapter present. A spare onboard port can be used (the system keeps it up without carrier)."
  select pick in "${free_other[@]}" "none"; do [ -n "$pick" ] && break; done; [ "$pick" = none ] && pick=""
fi
if [ -z "$pick" ]; then
  say "No suitable imaging adapter found (USB adapter not plugged in or not detected). Configuration left unchanged: ${current:-none}."
  [ "$MODE" = yes ] && exit 0   # unattended (boot): not a unit failure, just nothing to do
  exit 1
fi
mac=$(cat "/sys/class/net/$pick/address")
say "Recommended imaging NIC: $pick ($mac)   configured now: ${current:-none}"

# ---------- 2. uplink ----------
up=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
[ "$up" = "$pick" ] && up=""
[ -n "$up" ] || up=$(for n in /sys/class/net/*/wireless; do [ -d "$n" ] && basename "$(dirname "$n")"; done | head -1)
[ -n "$up" ] || up=$(for i in "${cands[@]}"; do [ "$i" != "$pick" ] && echo "$i"; done | head -1)   # e.g. the 100 Mbit USB NIC
say "Recommended uplink (internet side): ${up:-none found}   configured now: $(getenvkey JOG_BACKHAUL_IFACE)"

# ---------- 3. faulty USB hubs (kernel says ports will not enumerate) ----------
bad=""
while read -r hub; do
  d=/sys/bus/usb/devices/$hub; [ -r "$d/idVendor" ] || continue
  id="$(cat "$d/idVendor"):$(cat "$d/idProduct")"
  readlink -f "/sys/class/net/$pick/device" | grep -q "/$hub/" && { say "  hub $hub ($id) has errors but carries the imaging NIC: leaving it alone"; continue; }
  case " $bad " in *" $id "*) ;; *) bad="$bad $id" ;; esac
  say "  faulty hub: $hub  $id  $(cat "$d/product" 2>/dev/null)"
done < <(journalctl -k -b --no-pager 2>/dev/null | sed -n -E 's/.*usb ([0-9]+-[0-9.]+)-port[0-9]+: (Cannot enable|unable to enumerate).*/\1/p' | sort -u)
bad=${bad# }
[ -n "$bad" ] || bad=$(getenvkey JOG_USB_QUIET_HUBS)
say "USB hubs to switch off: ${bad:-none}"

[ "$MODE" = check ] && { [ "$current" = "$pick" ] && say "Config matches." && exit 0; say "Config is OUT OF DATE (run without --check)."; exit 1; }

confirm "Apply these settings?" || { say "Nothing changed."; exit 0; }

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
cp -a "$ENV_FILE" "$ENV_FILE.pre-wizard.$(date +%s)"
setenvkey JOG_USB_IFACE "$pick"
setenvkey JOG_IMAGING_NIC "$pick"
[ -n "$up" ] && setenvkey JOG_BACKHAUL_IFACE "$up"
setenvkey JOG_USB_QUIET_HUBS "\"$bad\""
if [ "$ONBOARD" = 1 ]; then
  setenvkey JOG_ALLOW_ONBOARD_NIC "$pick"
  mkdir -p /etc/NetworkManager/conf.d
  printf '# Written by jog-hardware-wizard: imaging NIC is an onboard port, keep NetworkManager off it.\n[keyfile]\nunmanaged-devices=interface-name:%s\n' "$pick" > /etc/NetworkManager/conf.d/99-jog-unmanaged.conf
  systemctl reload NetworkManager 2>/dev/null || true
else
  sed -i -E '/^JOG_ALLOW_ONBOARD_NIC=/d' "$ENV_FILE"
  rm -f /etc/NetworkManager/conf.d/99-jog-unmanaged.conf
fi

cat > /etc/udev/rules.d/99-jog-imaging-nic.rules <<EOF
# Written by jog-hardware-wizard. Matches by MAC so the interface name does not matter.
SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="$mac", TAG+="systemd", ENV{SYSTEMD_WANTS}+="jog-force-imaging-nic-up.service"
EOF
: > /etc/udev/rules.d/99-jog-usb-quiet.rules
for id in $bad; do
  printf 'SUBSYSTEM=="usb", ACTION=="add", ATTR{idVendor}=="%s", ATTR{idProduct}=="%s", RUN+="/usr/local/sbin/jog-usb-quiet.sh"\n' "${id%:*}" "${id#*:}" >> /etc/udev/rules.d/99-jog-usb-quiet.rules
done
udevadm control --reload
systemctl --no-block restart jog-force-imaging-nic-up.service 2>/dev/null || true
[ -n "$bad" ] && systemctl --no-block restart jog-usb-quiet.service 2>/dev/null || true
systemctl --no-block restart jog-render-dnsmasq.service 2>/dev/null || true
say "Done. Imaging NIC $pick ($mac); uplink ${up:-unchanged}; quiet hubs: ${bad:-none}."
