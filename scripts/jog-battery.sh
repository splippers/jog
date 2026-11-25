#!/bin/bash
set -u
export LC_ALL=C

UPOWER=${JOG_BATTERY_UPOWER:-/usr/bin/upower}
SYSFS_PS=${JOG_BATTERY_SYSFS:-/sys/class/power_supply}
UPDATED=$(date +%s)

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

jstr() {
  if [[ -z ${1:-} ]]; then printf 'null'; else printf '"%s"' "$(json_escape "$1")"; fi
}

jnum() {
  if [[ -z ${1:-} ]]; then printf 'null'; else printf '%s' "$1"; fi
}

trim() {
  local v=${1:-}
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

rawnum() {
  local v
  v=$(trim "${1:-}")
  v=${v%%[[:space:]]*}
  v=${v%\%}
  if [[ $v =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then printf '%s' "$v"; fi
}

round1() {
  local v
  v=$(rawnum "${1:-}")
  if [[ -n $v ]]; then printf '%.1f' "$v"; fi
}

sysread() {
  local v=""
  if [[ -r ${1:-} ]]; then v=$(<"$1"); v=${v//$'\r'/}; v=${v//$'\n'/}; fi
  printf '%s' "$v"
}

scaled() {
  local v
  v=$(rawnum "${1:-}")
  if [[ -n $v ]]; then awk -v v="$v" -v s="${2:-1000000}" 'BEGIN { if (s > 0) printf "%.4f", v / s }'; fi
}

norm_state() {
  local v=${1,,}
  case $v in
    ""|unknown) printf '' ;;
    not-charging) printf 'not-charging' ;;
    *full*) printf 'fully-charged' ;;
    *discharg*) printf 'discharging' ;;
    *charg*) printf 'charging' ;;
    empty) printf 'empty' ;;
    *) printf '%s' "$v" ;;
  esac
}

up_detail=""
up_dev=""
up_present=""
devices=""
if [[ -x $UPOWER ]]; then
  devices=$($UPOWER -e 2>/dev/null || true)
  while IFS= read -r dev; do
    case $dev in
      *battery_*) up_dev=$dev; break ;;
    esac
  done <<< "$devices"
  if [[ -n $up_dev ]]; then
    up_detail=$($UPOWER -i "$up_dev" 2>/dev/null || true)
  fi
fi

percentage=""
state=""
health=""
cycles=""
model=""
vendor=""
serial=""
energy=""
energy_full=""
energy_design=""
time_empty=""
time_full=""
warning=""
technology=""
voltage=""

while IFS= read -r line; do
  line=$(trim "$line")
  [[ $line == *:* ]] || continue
  key=${line%%:*}
  val=$(trim "${line#*:}")
  case $key in
    vendor) [[ -z $vendor ]] && vendor=$val ;;
    model) [[ -z $model ]] && model=$val ;;
    serial) [[ -z $serial ]] && serial=$val ;;
    state) [[ -z $state ]] && state=$(norm_state "$val") ;;
    warning-level) [[ -z $warning ]] && warning=$val ;;
    energy) [[ -z $energy ]] && energy=$(rawnum "$val") ;;
    energy-full) [[ -z $energy_full ]] && energy_full=$(rawnum "$val") ;;
    energy-full-design) [[ -z $energy_design ]] && energy_design=$(rawnum "$val") ;;
    capacity) [[ -z $health ]] && health=$(rawnum "$val") ;;
    time\ to\ empty) [[ -z $time_empty ]] && time_empty=$val ;;
    time\ to\ full) [[ -z $time_full ]] && time_full=$val ;;
    percentage) [[ -z $percentage ]] && percentage=$(rawnum "$val") ;;
    technology) [[ -z $technology ]] && technology=$val ;;
    charge-cycles) [[ -z $cycles ]] && cycles=$(rawnum "$val") ;;
    voltage) [[ -z $voltage ]] && voltage=$(rawnum "$val") ;;
    present) [[ $val == yes || $val == true ]] && up_present=1 || up_present=0 ;;
  esac
done <<< "$up_detail"

sysbat=""
s_percentage=""
s_state=""
s_cycles=""
s_model=""
s_vendor=""
s_serial=""
s_energy=""
s_energy_full=""
s_energy_design=""
s_technology=""
s_voltage=""
s_charge=""
s_present=""
for bat in "$SYSFS_PS"/BAT*; do
  [[ -e $bat ]] || continue
  btype=$(sysread "$bat/type")
  bpresent=$(sysread "$bat/present")
  if [[ -n $btype && ${btype,,} != battery ]]; then continue; fi
  if [[ -n $bpresent && $bpresent != 1 && ${bpresent,,} != true ]]; then continue; fi
  sysbat=$bat
  s_present=$bpresent
  s_percentage=$(sysread "$bat/capacity")
  s_state=$(norm_state "$(sysread "$bat/status")")
  s_cycles=$(sysread "$bat/cycle_count")
  s_model=$(sysread "$bat/model_name")
  s_vendor=$(sysread "$bat/manufacturer")
  s_serial=$(sysread "$bat/serial_number")
  s_energy=$(scaled "$(sysread "$bat/energy_now")")
  s_energy_full=$(scaled "$(sysread "$bat/energy_full")")
  s_energy_design=$(scaled "$(sysread "$bat/energy_full_design")")
  s_technology=$(sysread "$bat/technology")
  s_voltage=$(scaled "$(sysread "$bat/voltage_now")")
  s_charge=$(sysread "$bat/charge_now")
  break
done

if [[ -z $energy && -z $s_energy && -n $s_charge && -n $s_voltage ]]; then
  s_energy=$(awk -v c="$s_charge" -v v="$s_voltage" 'BEGIN { if (c + 0 > 0) printf "%.4f", c * v / 1000000 }')
fi

source="none"
if [[ -n $up_detail ]]; then source="upower"; elif [[ -n $sysbat ]]; then source="sysfs"; fi

present=false
if [[ $up_present == 1 ]]; then
  present=true
elif [[ -n $up_detail && $up_present == 0 ]]; then
  present=false
elif [[ -n $sysbat ]]; then
  present=true
fi

[[ -z $state ]] && state=$s_state
[[ -z $cycles ]] && cycles=$(rawnum "$s_cycles")
[[ -z $model ]] && model=$s_model
[[ -z $vendor ]] && vendor=$s_vendor
[[ -z $serial ]] && serial=$s_serial
[[ -z $energy ]] && energy=$s_energy
[[ -z $energy_full ]] && energy_full=$s_energy_full
[[ -z $energy_design ]] && energy_design=$s_energy_design
[[ -z $technology ]] && technology=$s_technology
[[ -z $voltage ]] && voltage=$s_voltage

if [[ -z $percentage ]]; then
  if [[ -n $energy && -n $energy_full ]]; then
    percentage=$(awk -v a="$energy" -v b="$energy_full" 'BEGIN { if (b + 0 > 0) printf "%.1f", a / b * 100 }')
  else
    percentage=$(rawnum "$s_percentage")
  fi
fi
percentage=$(round1 "$percentage")

if [[ -z $health && -n $energy_full && -n $energy_design ]]; then
  health=$(awk -v a="$energy_full" -v b="$energy_design" 'BEGIN { if (b + 0 > 0) printf "%.1f", a / b * 100 }')
fi
if [[ -z $health ]]; then health=$(rawnum "$s_percentage"); fi
health=$(round1 "$health")

health_label="Unknown"
if [[ -n $health ]]; then
  health_label=$(awk -v h="$health" 'BEGIN { if (h + 0 >= 80) print "Good"; else if (h + 0 >= 60) print "Fair"; else print "Poor" }')
fi

if [[ -z $warning ]]; then
  warn_pct=$percentage
  [[ -z $warn_pct ]] && warn_pct=$(rawnum "$s_percentage")
  if [[ -n $warn_pct ]]; then
    warning=$(awk -v p="$warn_pct" 'BEGIN { if (p + 0 <= 5) print "critical"; else if (p + 0 <= 20) print "low"; else print "none" }')
  else
    warning="unknown"
  fi
fi

ok=false
if [[ $present == true && ( -n $percentage || -n $energy || -n $state ) ]]; then ok=true; fi
if [[ $present != true ]]; then
  source="none"
  percentage=""
  state=""
  health=""
  health_label="Unknown"
  cycles=""
  model=""
  vendor=""
  serial=""
  energy=""
  energy_full=""
  energy_design=""
  time_empty=""
  time_full=""
  warning="no battery detected"
  technology=""
  voltage=""
fi

printf '{"ok":%s,"present":%s,"percentage":%s,"state":%s,"healthPercent":%s,"healthLabel":%s,"cycles":%s,"model":%s,"vendor":%s,"serial":%s,"energyWh":%s,"energyFullWh":%s,"energyDesignWh":%s,"timeToEmpty":%s,"timeToFull":%s,"warning":%s,"technology":%s,"voltage":%s,"source":%s,"updated":%s}\n' \
  "$ok" "$present" "$(jnum "$percentage")" "$(jstr "$state")" "$(jnum "$health")" "$(jstr "$health_label")" \
  "$(jnum "$cycles")" "$(jstr "$model")" "$(jstr "$vendor")" "$(jstr "$serial")" \
  "$(jnum "$energy")" "$(jnum "$energy_full")" "$(jnum "$energy_design")" \
  "$(jstr "$time_empty")" "$(jstr "$time_full")" "$(jstr "$warning")" "$(jstr "$technology")" \
  "$(jnum "$voltage")" "$(jstr "$source")" "$UPDATED"
