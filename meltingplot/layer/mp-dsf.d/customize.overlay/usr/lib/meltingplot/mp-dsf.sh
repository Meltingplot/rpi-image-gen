# Shared helpers for the DSF side of a Meltingplot printer computer. POSIX sh,
# sourced after mp-common.sh.
#
# The update path keeps asking two questions: is the printer doing anything,
# and will the bootloader start the running slot again. Both are answered
# here and nowhere else, so the restart gate and the firmware update cannot
# disagree about either.

# Overridable so the logic can be exercised on a build host with stubs.
MP_CODECONSOLE=${MP_CODECONSOLE:-/opt/dsf/bin/CodeConsole}
MP_SLOT_TRYBOOT=${MP_SLOT_TRYBOOT:-/usr/bin/rpi-slot-tryboot}
MP_AUTOBOOT=${MP_AUTOBOOT:-/bootfs/autoboot.txt}
MP_OTA_STATE=${MP_OTA_STATE:-/bootfs/ota_state}

# The machine status as RepRapFirmware reports it: idle, processing, paused,
# updating and so on. Asked through DuetControlServer with M409, which is what
# Duet Web Control does too. Prints nothing when the control server cannot be
# reached or gives no answer; callers must read that as "not idle".
mp_dcs_status() {
   _json=$("$MP_CODECONSOLE" -c 'M409 K"state.status"' 2>/dev/null) || return 0
   printf '%s\n' "$_json" | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        result = json.loads(line).get("result")
    except ValueError:
        continue
    if isinstance(result, str):
        print(result)
        break
' 2>/dev/null || true
}

# The partition named by the [all] section of a tryboot configuration, which
# is the one the bootloader starts when nothing says otherwise. Reads stdin.
mp_default_boot_partition() {
   tr -d '\r' | awk -F= '
      /^\[/ { section = $0 }
      section == "[all]" && $1 == "boot_partition" { print $2; exit }'
}

# True when the running slot is committed: autoboot.txt already names it as
# the default, so a reset comes back here. During a tryboot, before the update
# connector or an operator commits the slot, this is false.
mp_slot_committed() {
   [ -r "$MP_AUTOBOOT" ] || return 1
   _have=$(mp_default_boot_partition < "$MP_AUTOBOOT")
   _want=$("$MP_SLOT_TRYBOOT" 2>/dev/null | mp_default_boot_partition)
   [ -n "$_want" ] && [ "$_have" = "$_want" ]
}

# State of the Raspberry Pi Connect update connector, from the file it keeps
# across a reboot. Empty when no update is in flight.
mp_ota_state() {
   [ -r "$MP_OTA_STATE" ] || return 0
   sed -n -e 's/\r$//' -e 's/^state=//p' "$MP_OTA_STATE" | head -n1
}

# True when an installed update is waiting for permission to restart.
mp_ota_restart_pending() {
   case $(mp_ota_state) in
      *WAIT|*PROMPT) return 0 ;;
      *) return 1 ;;
   esac
}
