# Shared helpers for the DSF side of a Meltingplot printer computer. POSIX sh,
# sourced after mp-common.sh.
#
# The update path keeps asking two questions: is the printer doing anything,
# and will the bootloader start the running slot again. Both are answered
# here and nowhere else, so the connector gate and the firmware update cannot
# disagree about either. The same goes for the third thing they share, the
# message box that tells whoever stands at the printer that an update is in
# progress.

# Overridable so the logic can be exercised on a build host with stubs.
MP_CODECONSOLE=${MP_CODECONSOLE:-/opt/dsf/bin/CodeConsole}
MP_SLOT_TRYBOOT=${MP_SLOT_TRYBOOT:-/usr/bin/rpi-slot-tryboot}
MP_AUTOBOOT=${MP_AUTOBOOT:-/bootfs/autoboot.txt}
MP_BUSCTL=${MP_BUSCTL:-busctl}
MP_TRYBOOT_FLAG=${MP_TRYBOOT_FLAG:-/proc/device-tree/chosen/bootloader/tryboot}

# Ask DuetControlServer for one key of the object model with M409, which is
# what Duet Web Control does too. Prints a string result as it is and any
# other non-null result as JSON. Prints nothing when the control server
# cannot be reached, gives no answer, or the key is null; callers must read
# that as "unknown".
mp_dcs_query() {
   _json=$("$MP_CODECONSOLE" -c "M409 K\"$1\"" 2>/dev/null) || return 0
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
    elif result is not None:
        print(json.dumps(result))
    break
' 2>/dev/null || true
}

# The machine status as RepRapFirmware reports it: idle, processing, paused,
# updating and so on. Nothing means the control server cannot be asked;
# callers must read that as "not idle".
mp_dcs_status() {
   mp_dcs_query state.status
}

# Send one code to the printer through DuetControlServer. Fails when the
# control server cannot be reached.
mp_dcs_code() {
   "$MP_CODECONSOLE" -c "$1" >/dev/null 2>&1
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

# True when the bootloader started this boot as a tryboot, which is how the
# update connector activates a freshly written slot and how an operator rolls
# back by hand. The flag describes the boot, not the slot: it stays set after
# the slot has been committed, until the next reset.
mp_boot_trybooted() {
   _flag=$(od -An -tu1 "$MP_TRYBOOT_FLAG" 2>/dev/null | tr -d ' \n')
   [ -n "$_flag" ] && [ "$_flag" -eq 1 ]
}

# The state the update connector reports over D-Bus: IDLE, DOWNLOAD, INSTALL,
# TRYBOOT and so on (rpi-ota-connector 1.3.14). Prints nothing when the
# connector is not running.
mp_ota_state() {
   "$MP_BUSCTL" call com.raspberrypi.ota /com/raspberrypi/ota com.raspberrypi.ota GetStatus 2>/dev/null \
      | sed -n 's/^s "\(.*\)"$/\1/p'
}

# True for the connector states between picking a deployment up and restarting
# into it. Everything before (checking for a deployment) and after the restart
# (committing, reporting) is not an install from the printer's point of view.
mp_ota_installing() {
   case $1 in
      DOWNLOAD | PREINSTALL | INSTALL | REBOOTPROMPT | REBOOTWAIT | REBOOT | TRYBOOTPROMPT | TRYBOOTWAIT | TRYBOOT)
         return 0 ;;
      *)
         return 1 ;;
   esac
}

# The message box that tells whoever stands at the printer that an update is
# in progress. Shown as a plain notice without buttons (M291 S0) on the
# PanelDue and in Duet Web Control; it goes away when it is closed, when the
# control server restarts (it does not survive the restart into an update),
# when the mainboard resets (a firmware flash does that), or after the
# timeout, which is generous so that a refresh once a minute never lets it
# lapse while an install runs. Only a
# message box with this title is ever closed, so a dialog of a macro or of
# the operator is left alone.
MP_OTA_NOTICE_TITLE="OTA Update"
MP_OTA_NOTICE_TEXT="OTA update in progress - do not shut down the machine! You can use the machine again when this message disappears."
MP_OTA_NOTICE_TIMEOUT=1800

mp_ota_notice_show() {
   mp_dcs_code "M291 S0 T$MP_OTA_NOTICE_TIMEOUT R\"$MP_OTA_NOTICE_TITLE\" P\"$MP_OTA_NOTICE_TEXT\""
}

mp_ota_notice_open() {
   [ "$(mp_dcs_query state.messageBox.title)" = "$MP_OTA_NOTICE_TITLE" ]
}

# Close the notice if it is the message box on display. Succeeds when there is
# nothing of ours to close.
mp_ota_notice_close() {
   mp_ota_notice_open || return 0
   mp_dcs_code M292
}

# The message box that stays once the machine has restarted into an update: a
# Close button and no timeout (M291 S1 T0), so whoever next stands at the
# printer sees that the update happened and dismisses it. RepRapFirmware
# queues message boxes, so one of ours still on display is closed first; this
# one carries the same title and is closed by the same helper.
MP_OTA_DONE_TEXT="OTA update completed successfully. The machine is ready for use."

mp_ota_done_show() {
   mp_ota_notice_close || return 1
   mp_dcs_code "M291 S1 T0 R\"$MP_OTA_NOTICE_TITLE\" P\"$MP_OTA_DONE_TEXT\""
}
