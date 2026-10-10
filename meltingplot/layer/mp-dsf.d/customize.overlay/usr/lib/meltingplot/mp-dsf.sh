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
MP_DSF_CONF=${MP_DSF_CONF:-/etc/meltingplot/dsf.conf}
MP_DSF_SHARED=${MP_DSF_SHARED:-/persistent/shared/opt/dsf}
MP_DSF_GROUP_STAMP=${MP_DSF_GROUP_STAMP:-/var/lib/meltingplot/dsf-group}

# Settings the image was built with (layer mp-dsf). MP_MAINBOARD_RESET=y makes
# the first boot after an update reset the mainboard (mp-dsf-firmware).
MP_MAINBOARD_RESET=n
# shellcheck source=/dev/null
[ -r "$MP_DSF_CONF" ] && . "$MP_DSF_CONF"

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

# When RepRapFirmware last started, in seconds since the epoch, from the
# uptime it reports. A reset of the mainboard moves it forward; the answer
# carries a second or two of jitter from the round trip. Nothing when the
# control server cannot be asked or has no uptime yet.
mp_dcs_boot_time() {
   _up=$(mp_dcs_query state.upTime)
   case $_up in
      '' | *[!0-9]*) return 0 ;;
   esac
   echo $(($(date +%s) - _up))
}

# Send one code to the printer through DuetControlServer. Fails when the
# control server cannot be reached.
mp_dcs_code() {
   "$MP_CODECONSOLE" -c "$1" >/dev/null 2>&1
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

# Show the notice unless a message box of ours is already on display, so a
# queue of identical boxes never builds up.
mp_ota_notice_ensure() {
   mp_ota_notice_open || mp_ota_notice_show
}

# Close the notice if it is the message box on display. Succeeds when there is
# nothing of ours to close.
mp_ota_notice_close() {
   mp_ota_notice_open || return 0
   mp_dcs_code M292
}

# The message box that stays once the machine has restarted into an update: a
# Close button and no timeout (M291 S1 T0), so whoever next stands at the
# printer sees that the update happened and dismisses it. It names the
# version and, when the image was published as a release, links the page
# with the changelog: Duet Web Control renders a message as HTML, so the
# link is clickable there. RepRapFirmware queues message boxes, so one of
# ours still on display is closed first; this one carries the same title and
# is closed by the same helper.
#
# Measured on RepRapFirmware 3.7.0-rc.1 with DSF 3.7.0-rc.1: the firmware
# shows at most 256 characters of a message, and DuetControlServer refuses a
# code over 384 bytes in its binary form, which this title and these
# parameters reach at about 330 characters. The text is cut at what the
# firmware shows; with a version and a GitHub release page it stays below
# 200 characters. A double quote inside a G-code string is written twice;
# that is how the quotes of the link survive the trip, a single quote does
# not (RepRapFirmware reads it as a lower-case escape and drops it).
MP_OTA_DONE_MAX=256

mp_ota_done_text() {
   if [ -n "$MP_RELEASE_URL" ]; then
      _text="OTA update${MP_VERSION:+ to $MP_VERSION} completed successfully. Read the <a href=\"$MP_RELEASE_URL\" target=\"_blank\">changelog</a>."
   else
      _text="OTA update${MP_VERSION:+ to $MP_VERSION} completed successfully. The machine is ready for use."
   fi
   printf '%.*s\n' "$MP_OTA_DONE_MAX" "$_text"
}

mp_ota_done_show() {
   mp_ota_notice_close || return 1
   _p=$(mp_ota_done_text | sed 's/"/""/g')
   mp_dcs_code "M291 S1 T0 R\"$MP_OTA_NOTICE_TITLE\" P\"$_p\""
}

# The same kind of box when the machine restarted into the update but the
# Duet firmware could not be brought to the version the update carries. The
# machine runs the new software with the old firmware then, which Duet Web
# Control also warns about.
mp_ota_failed_text() {
   printf '%.*s\n' "$MP_OTA_DONE_MAX" "OTA update${MP_VERSION:+ to $MP_VERSION} installed, but the Duet firmware update did not complete. Please contact Meltingplot support."
}

mp_ota_failed_show() {
   mp_ota_notice_close || return 1
   _p=$(mp_ota_failed_text | sed 's/"/""/g')
   mp_dcs_code "M291 S1 T0 R\"$MP_OTA_NOTICE_TITLE\" P\"$_p\""
}

# Images before mp-dsf 1.16.0 gave everything they put below /opt/dsf the uid
# of dsf as its group, which on the device is kvm and not dsf. An image that
# ships its files with the right group puts those back on its own, because
# persistent-shared-init copies ownership along, but not what the seed placed
# once, and not what DSF created since: the directories are setgid, so every
# new file inherited the wrong group. This hands whatever still carries gid $1
# to the group $2, on the persistent copy itself, where the read-only mounts
# over the bundled plugins are no obstacle. It walks every file on the virtual
# SD card, so it runs once per image version; a rollback to an older image
# brings the wrong group back, and the next update puts it right again.
mp_dsf_fix_group() {
   [ -d "$MP_DSF_SHARED" ] || return 0
   if [ -f "$MP_DSF_GROUP_STAMP" ] && [ "$(cat "$MP_DSF_GROUP_STAMP")" = "$MP_VERSION" ]; then
      return 0
   fi
   _n=$(find "$MP_DSF_SHARED" -xdev -gid "$1" -print | wc -l)
   if [ "$_n" -gt 0 ]; then
      find "$MP_DSF_SHARED" -xdev -gid "$1" -exec chgrp -h "$2" {} + || return 1
      mp_log "$_n files below $MP_DSF_SHARED moved from gid $1 to the group $2"
   fi
   mkdir -p "$(dirname "$MP_DSF_GROUP_STAMP")"
   printf '%s\n' "$MP_VERSION" > "$MP_DSF_GROUP_STAMP"
}

# Whether the autostart list $1 of DuetPluginService names plugin $2.
# DuetControlServer rewrites that file whenever a plugin is started or
# stopped in Duet Web Control, as UTF-8 with a byte order mark in front of
# the first id, which a plain grep takes for part of that line.
mp_dsf_autostart_has() {
   [ -f "$1" ] || return 1
   LC_ALL=C sed '1s/^\xef\xbb\xbf//' "$1" | grep -qxF "$2"
}
