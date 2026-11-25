#!/bin/bash
# jog-usb-quiet.sh: switch off every port of a known-bad USB 2.0 hub so the kernel stops retrying
# enumeration ("Cannot enable. Maybe the USB cable is bad?"). The Latitude rig's combo hub has a
# faulty USB 2.0 half (Terminus 1a40:0801); its USB 3.0 half (VIA 2109:0817, on the other bus) works
# and is untouched. Override the list with JOG_USB_QUIET_HUBS="vid:pid vid:pid" in /etc/jog/jog.env.
set -u
[ -r /etc/jog/jog.env ] && . /etc/jog/jog.env
HUBS=${JOG_USB_QUIET_HUBS:-1a40:0801}
n=0
for dev in /sys/bus/usb/devices/*; do
  [ -r "$dev/idVendor" ] && [ -r "$dev/idProduct" ] || continue
  id="$(cat "$dev/idVendor"):$(cat "$dev/idProduct")"
  case " $HUBS " in *" $id "*) ;; *) continue ;; esac
  b=$(basename "$dev")
  for p in "$dev/$b:1.0/$b"-port*; do
    [ -w "$p/disable" ] || continue
    if [ "$(cat "$p/disable")" != 1 ]; then echo 1 > "$p/disable" && n=$((n+1)); fi
  done
done
logger -t jog-usb-quiet "disabled $n unused port(s) on hubs: $HUBS"
exit 0
