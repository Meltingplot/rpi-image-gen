#!/bin/sh
# Tests for the DSF-side helpers and the update connector gate, runnable on
# the build host with stubs in place of CodeConsole, rpi-slot-tryboot and
# systemctl.
#
# What matters here is the reading of state. A wrong answer either restarts a
# printing machine, or flashes firmware into a slot the bootloader is about to
# leave.

set -eu

here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

MP_DEVICE_CONF=/nonexistent
. "$here/../layer/mp-identity.d/customize.overlay/usr/lib/meltingplot/mp-common.sh"

MP_CODECONSOLE="$tmp/CodeConsole"
MP_SLOT_TRYBOOT="$tmp/rpi-slot-tryboot"
MP_AUTOBOOT="$tmp/autoboot.txt"
MP_OTA_STATE_FILE="$tmp/ota_state"
MP_TRYBOOT_FLAG="$tmp/tryboot"
. "$here/../layer/mp-dsf.d/customize.overlay/usr/lib/meltingplot/mp-dsf.sh"

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-46s %s\n' "$1" "$3"
   else
      printf 'FAIL %-46s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}

# --- machine status through CodeConsole -----------------------------------
# The stub answers with whatever the test put in status.out and exits with
# status.rc, so the parsing sees exactly what the real tool prints.

cat > "$MP_CODECONSOLE" <<'EOF'
#!/bin/sh
[ "$1" = "-c" ] && [ "$2" = 'M409 K"state.status"' ] || { echo "unexpected: $*" >&2; exit 2; }
cat "$(dirname "$0")/status.out"
exit "$(cat "$(dirname "$0")/status.rc")"
EOF
chmod +x "$MP_CODECONSOLE"
echo 0 > "$tmp/status.rc"

echo '{"key":"state.status","flags":"","result":"idle"}' > "$tmp/status.out"
check "status idle"            "idle"       "$(mp_dcs_status)"
echo '{"key":"state.status","flags":"","result":"processing"}' > "$tmp/status.out"
check "status processing"      "processing" "$(mp_dcs_status)"
printf 'Connected to DuetControlServer\n{"key":"state.status","flags":"","result":"paused"}\n' > "$tmp/status.out"
check "status after a banner"  "paused"     "$(mp_dcs_status)"
echo '{"key":"state.status","flags":"","result":null}' > "$tmp/status.out"
check "status null is unknown" ""           "$(mp_dcs_status)"
echo 'Error: Failed to connect to /run/dsf/dcs.sock' > "$tmp/status.out"
check "status error text"      ""           "$(mp_dcs_status)"
echo 1 > "$tmp/status.rc"
echo '{"key":"state.status","flags":"","result":"idle"}' > "$tmp/status.out"
check "status tool failed"     ""           "$(mp_dcs_status)"
rm -f "$MP_CODECONSOLE"
check "status tool missing"    ""           "$(mp_dcs_status)"

# --- other object model keys ----------------------------------------------
# A string result is printed as it is, anything else as JSON, null as
# nothing. The stub now answers any M409 from a file named after the key.

cat > "$MP_CODECONSOLE" <<'EOF'
#!/bin/sh
d=$(dirname "$0")
[ "$1" = "-c" ] || { echo "unexpected: $*" >&2; exit 2; }
echo "$2" >> "$d/codes.log"
case $2 in
   'M409 K"'*'"') key=${2#M409 K\"}; key=${key%\"}; cat "$d/query.$key" 2>/dev/null ;;
esac
exit "$(cat "$d/status.rc")"
EOF
chmod +x "$MP_CODECONSOLE"
echo 0 > "$tmp/status.rc"
echo '{"key":"state.messageBox.title","flags":"","result":"OTA Update"}' > "$tmp/query.state.messageBox.title"
check "query string"           "OTA Update" "$(mp_dcs_query state.messageBox.title)"
echo '{"key":"state.messageBox","flags":"","result":{"mode":0,"title":"OTA Update"}}' > "$tmp/query.state.messageBox"
check "query object"           '{"mode": 0, "title": "OTA Update"}' "$(mp_dcs_query state.messageBox)"
echo '{"key":"state.messageBox","flags":"","result":null}' > "$tmp/query.state.messageBox"
check "query null"             ""           "$(mp_dcs_query state.messageBox)"
check "query unknown key"      ""           "$(mp_dcs_query boards[9].name)"

# --- the boot the bootloader started ---------------------------------------
# The device tree carries a big-endian 32-bit flag.

printf '\0\0\0\1' > "$MP_TRYBOOT_FLAG"
mp_boot_trybooted && r=yes || r=no
check "trybooted: flag set"    yes "$r"
printf '\0\0\0\0' > "$MP_TRYBOOT_FLAG"
mp_boot_trybooted && r=yes || r=no
check "trybooted: flag clear"  no  "$r"
rm -f "$MP_TRYBOOT_FLAG"
mp_boot_trybooted && r=yes || r=no
check "trybooted: no flag"     no  "$r"

# --- the update connector's state ------------------------------------------
# The connector keeps a small key=value file on the boot partition (FAT, so
# CRLF is possible) and rewrites it on every transition.

printf 'state=INSTALL\nbootid=8b4d9a8288c9869e95087366c977aa9a\ntrybooktoken=3\ndepid=da9b2312\n' > "$MP_OTA_STATE_FILE"
check "ota state"              "INSTALL" "$(mp_ota_state)"
printf 'state=IDLE\r\nbootid=8b4d9a8288c9869e95087366c977aa9a\r\n' > "$MP_OTA_STATE_FILE"
check "ota state CRLF"         "IDLE"    "$(mp_ota_state)"
printf 'bootid=8b4d9a8288c9869e95087366c977aa9a\n' > "$MP_OTA_STATE_FILE"
check "ota state no line"      ""        "$(mp_ota_state)"
rm -f "$MP_OTA_STATE_FILE"
check "ota state no file"      ""        "$(mp_ota_state)"

for st in DOWNLOAD PREINSTALL INSTALL REBOOT TRYBOOT REBOOTWAIT; do
   mp_ota_installing "$st" && r=yes || r=no
   check "installing: $st" yes "$r"
done
for st in IDLE CHECKPENDING FETCHDEPLOYMENT TRYBOOTED COMMIT PASSDEPLOYMENT FAILDEPLOYMENT ""; do
   mp_ota_installing "$st" && r=yes || r=no
   check "installing: ${st:-none}" no "$r"
done

# --- the update notice -----------------------------------------------------
# Shown as a plain timed message, closed only when it is the message box on
# display.

: > "$tmp/codes.log"
mp_ota_notice_show
check "notice show" 'M291 S0 T1800 R"OTA Update" P"OTA update in progress - do not shut down the machine! You can use the machine again when this message disappears."' "$(cat "$tmp/codes.log")"
: > "$tmp/codes.log"
echo '{"key":"state.messageBox.title","flags":"","result":"OTA Update"}' > "$tmp/query.state.messageBox.title"
mp_ota_notice_close
check "notice close: ours"     'M409 K"state.messageBox.title",M292' "$(paste -sd, "$tmp/codes.log")"
: > "$tmp/codes.log"
echo '{"key":"state.messageBox.title","flags":"","result":"Nozzle"}' > "$tmp/query.state.messageBox.title"
mp_ota_notice_close
check "notice close: a dialog" 'M409 K"state.messageBox.title"' "$(paste -sd, "$tmp/codes.log")"
: > "$tmp/codes.log"
echo '{"key":"state.messageBox.title","flags":"","result":null}' > "$tmp/query.state.messageBox.title"
mp_ota_notice_close
check "notice close: none open" 'M409 K"state.messageBox.title"' "$(paste -sd, "$tmp/codes.log")"
: > "$tmp/codes.log"
echo '{"key":"state.messageBox.title","flags":"","result":"OTA Update"}' > "$tmp/query.state.messageBox.title"
mp_ota_done_show
check "done: replaces the notice" 'M409 K"state.messageBox.title",M292,M291 S1 T0 R"OTA Update" P"OTA update completed successfully. The machine is ready for use."' "$(paste -sd, "$tmp/codes.log")"
MP_VERSION=0.1.0-rc.23
MP_RELEASE_URL=https://github.com/Meltingplot/rpi-image-gen/releases/tag/duet-pi5%2Fv0.1.0-rc.23
check "done text: release" 'OTA update to 0.1.0-rc.23 completed successfully. Read the <a href="https://github.com/Meltingplot/rpi-image-gen/releases/tag/duet-pi5%2Fv0.1.0-rc.23" target="_blank">changelog</a>.' "$(mp_ota_done_text)"
: > "$tmp/codes.log"
echo '{"key":"state.messageBox.title","flags":"","result":null}' > "$tmp/query.state.messageBox.title"
mp_ota_done_show
check "done: quotes doubled for G-code" 'M291 S1 T0 R"OTA Update" P"OTA update to 0.1.0-rc.23 completed successfully. Read the <a href=""https://github.com/Meltingplot/rpi-image-gen/releases/tag/duet-pi5%2Fv0.1.0-rc.23"" target=""_blank"">changelog</a>."' "$(grep '^M291' "$tmp/codes.log")"
check "failed text" "OTA update to 0.1.0-rc.23 installed, but the Duet firmware update did not complete. Please contact Meltingplot support." "$(mp_ota_failed_text)"
MP_RELEASE_URL=
check "done text: local build" "OTA update to 0.1.0-rc.23 completed successfully. The machine is ready for use." "$(mp_ota_done_text)"
MP_RELEASE_URL=https://example.invalid/$(python3 -c 'print("x" * 300)')
t=$(mp_ota_done_text)
check "done text: cut to what RRF shows" 256 "${#t}"
MP_VERSION=
MP_RELEASE_URL=
rm -f "$MP_CODECONSOLE"
mp_ota_notice_show && r=yes || r=no
check "notice show: no control server" no "$r"
mp_ota_done_show && r=yes || r=no
check "done show: no control server" no "$r"

# --- slot commit ----------------------------------------------------------
# rpi-slot-tryboot prints the configuration that makes the running slot the
# default. The slot is committed when autoboot.txt already says the same.

cat > "$MP_SLOT_TRYBOOT" <<'EOF'
#!/bin/sh
cur=$(cat "$(dirname "$0")/active") || exit 1
printf '[all]\ntryboot_a_b=1\nboot_partition=%s\n[tryboot]\nboot_partition=%s\n' "$cur" "$((5 - cur))"
EOF
chmod +x "$MP_SLOT_TRYBOOT"

printf '[all]\ntryboot_a_b=1\nboot_partition=2\n[tryboot]\nboot_partition=3\n' > "$MP_AUTOBOOT"
check "default partition"      "2" "$(mp_default_boot_partition < "$MP_AUTOBOOT")"
printf '[all]\r\ntryboot_a_b=1\r\nboot_partition=3\r\n[tryboot]\r\nboot_partition=2\r\n' > "$MP_AUTOBOOT"
check "default partition CRLF" "3" "$(mp_default_boot_partition < "$MP_AUTOBOOT")"
printf '[tryboot]\nboot_partition=3\n' > "$MP_AUTOBOOT"
check "default partition absent" "" "$(mp_default_boot_partition < "$MP_AUTOBOOT")"

printf '[all]\ntryboot_a_b=1\nboot_partition=2\n[tryboot]\nboot_partition=3\n' > "$MP_AUTOBOOT"
echo 2 > "$tmp/active"
mp_slot_committed && r=yes || r=no
check "committed: running the default" yes "$r"
echo 3 > "$tmp/active"
mp_slot_committed && r=yes || r=no
check "committed: in a tryboot" no "$r"
printf '[all]\ntryboot_a_b=1\nboot_partition=3\n[tryboot]\nboot_partition=2\n' > "$MP_AUTOBOOT"
mp_slot_committed && r=yes || r=no
check "committed: after the commit" yes "$r"
rm -f "$tmp/active"
mp_slot_committed && r=yes || r=no
check "committed: slot helper fails" no "$r"
echo 3 > "$tmp/active"
rm -f "$MP_AUTOBOOT"
mp_slot_committed && r=yes || r=no
check "committed: no autoboot.txt" no "$r"

# --- update connector gate ------------------------------------------------
# The gate script itself, with systemctl replaced by a stub that answers
# is-active from a file and records every other call. The connector runs
# while the printer is idle, and while the slot is not yet committed; it is
# stopped for anything else, including a control server that cannot be
# asked. While the connector installs, the printer shows the notice; when an
# install the gate announced is over without a restart, the notice comes
# down, and only then.

export MP_LIB="$tmp/lib"
mkdir -p "$MP_LIB"
cp "$here/../layer/mp-identity.d/customize.overlay/usr/lib/meltingplot/mp-common.sh" "$MP_LIB/"
cp "$here/../layer/mp-dsf.d/customize.overlay/usr/lib/meltingplot/mp-dsf.sh" "$MP_LIB/"
export MP_DEVICE_CONF MP_CODECONSOLE MP_SLOT_TRYBOOT MP_AUTOBOOT MP_OTA_STATE_FILE MP_TRYBOOT_FLAG
export MP_SYSTEMCTL="$tmp/systemctl"
export MP_NOTICE_FLAG="$tmp/notice.flag"
cat > "$MP_SYSTEMCTL" <<'EOF'
#!/bin/sh
case $1 in
   is-active) cat "$(dirname "$0")/unit.state"; [ "$(cat "$(dirname "$0")/unit.state")" = active ] ;;
   *) echo "$1 $2" >> "$(dirname "$0")/systemctl.log" ;;
esac
EOF
chmod +x "$MP_SYSTEMCTL"
gate="$here/../layer/mp-dsf.d/customize.overlay/usr/sbin/mp-ota-gate"

# printer status, unit state, slot committed, connector state (its file)
#   -> expected systemctl calls, expected codes sent (other than the status)
gate_case() {
   echo "{\"key\":\"state.status\",\"flags\":\"\",\"result\":$2}" > "$tmp/query.state.status"
   echo "$3" > "$tmp/unit.state"
   if [ "$4" = committed ]; then echo 2 > "$tmp/active"; else echo 3 > "$tmp/active"; fi
   if [ -n "$5" ]; then printf 'state=%s\nbootid=0\n' "$5" > "$MP_OTA_STATE_FILE"; else rm -f "$MP_OTA_STATE_FILE"; fi
   : > "$tmp/systemctl.log"
   : > "$tmp/codes.log"
   sh "$gate" 2>>"$tmp/gate.log"
   check "gate: $1" "$6" "$(paste -sd, "$tmp/systemctl.log")"
   check "gate: $1, codes" "$7" "$(grep -v '^M409 K"state.status"$' "$tmp/codes.log" | paste -sd, -)"
}

cat > "$MP_CODECONSOLE" <<'EOF'
#!/bin/sh
d=$(dirname "$0")
echo "$2" >> "$d/codes.log"
case $2 in
   'M409 K"'*'"') key=${2#M409 K\"}; key=${key%\"}; cat "$d/query.$key" 2>/dev/null ;;
esac
exit "$(cat "$d/status.rc")"
EOF
chmod +x "$MP_CODECONSOLE"
echo 0 > "$tmp/status.rc"
printf '[all]\ntryboot_a_b=1\nboot_partition=2\n[tryboot]\nboot_partition=3\n' > "$MP_AUTOBOOT"
echo '{"key":"state.messageBox.title","flags":"","result":null}' > "$tmp/query.state.messageBox.title"
rm -f "$MP_NOTICE_FLAG"

gate_case "idle, connector running"        '"idle"'       active     committed   IDLE ""                             ""
gate_case "idle, connector stopped"        '"idle"'       inactive   committed   ""   "start rpi-connect-ota.service" ""
gate_case "idle, connector failed"         '"idle"'       failed     committed   ""   "start rpi-connect-ota.service" ""
gate_case "printing, connector running"    '"processing"' active     committed   IDLE "stop rpi-connect-ota.service"  ""
gate_case "printing, connector starting"   '"processing"' activating committed   IDLE "stop rpi-connect-ota.service"  ""
gate_case "printing, connector stopped"    '"processing"' inactive   committed   ""   ""                             ""
gate_case "paused, connector running"      '"paused"'     active     committed   IDLE "stop rpi-connect-ota.service"  ""
gate_case "unreachable, connector running" 'null'         active     committed   IDLE "stop rpi-connect-ota.service"  ""
gate_case "printing, slot not committed"   '"processing"' active     uncommitted IDLE ""                             ""
gate_case "unreachable, not committed"     'null'         inactive   uncommitted ""   "start rpi-connect-ota.service" ""

notice='M291 S0 T1800 R"OTA Update" P"OTA update in progress - do not shut down the machine! You can use the machine again when this message disappears."'
gate_case "idle, downloading"              '"idle"'       active     committed   DOWNLOAD "" "$notice"
[ -e "$MP_NOTICE_FLAG" ] && r=yes || r=no
check "gate: notice flag after showing" yes "$r"
gate_case "idle, installing"               '"idle"'       active     committed   INSTALL  "" "$notice"
gate_case "idle, about to restart"         '"idle"'       active     committed   TRYBOOT  "" "$notice"
echo '{"key":"state.messageBox.title","flags":"","result":"OTA Update"}' > "$tmp/query.state.messageBox.title"
gate_case "idle, install failed"           '"idle"'       active     committed   FAILDEPLOYMENT "" 'M409 K"state.messageBox.title",M292'
[ -e "$MP_NOTICE_FLAG" ] && r=yes || r=no
check "gate: notice flag after closing" no "$r"
gate_case "idle, install over, nothing shown" '"idle"'    active     committed   IDLE "" ""
gate_case "idle, stale file, connector off" '"idle"'      inactive   committed   INSTALL "start rpi-connect-ota.service" ""
gate_case "idle, installing again"         '"idle"'       active     committed   INSTALL  "" "$notice"
# The print that starts during an install stops the connector. Its file is
# left saying INSTALL, which counts for nothing once the connector is gone,
# and the notice comes down.
gate_case "printing, install interrupted"  '"processing"' inactive   committed   INSTALL "" 'M409 K"state.messageBox.title",M292'
# The notice of a message box that is not ours is left alone.
gate_case "idle, installing, flag reset"   '"idle"'       active     committed   INSTALL  "" "$notice"
echo '{"key":"state.messageBox.title","flags":"","result":"Nozzle diameter"}' > "$tmp/query.state.messageBox.title"
gate_case "idle, install over, dialog open" '"idle"'      active     committed   IDLE "" 'M409 K"state.messageBox.title"'
# A boot puts up its own notice; a gate that has not announced one leaves it.
echo '{"key":"state.messageBox.title","flags":"","result":"OTA Update"}' > "$tmp/query.state.messageBox.title"
gate_case "idle, notice of the boot"       '"idle"'       active     committed   IDLE "" ""

rm -f "$MP_CODECONSOLE"
gate_case "no control server, running"     '"idle"'       active     committed   IDLE "stop rpi-connect-ota.service" ""
gate_case "no control server, installing"  '"idle"'       active     committed   INSTALL "stop rpi-connect-ota.service" ""

# --- firmware update after boot --------------------------------------------
# The script itself against a simulated printer. CodeConsole answers the
# status from a list, one line per query with the last one repeating, the
# uptime from a boot time on file, and the message box title from what the
# codes put up and took down. DuetControlServer -u prints one prepared answer
# per pass; a pass that flashes resets the mainboard: the message box goes,
# the boot time moves on (by a fixed step, so that passes in quick succession
# still read as restarts) and the printer starts again.

cat > "$MP_CODECONSOLE" <<'EOF'
#!/bin/sh
d=$(dirname "$0")
case $2 in
   'M409 K"state.status"')
      if [ -s "$d/fw.status" ]; then
         s=$(head -n1 "$d/fw.status")
         [ "$(wc -l < "$d/fw.status")" -gt 1 ] && sed -i 1d "$d/fw.status"
      fi
      [ -n "${s:-}" ] || exit 1
      echo "{\"key\":\"state.status\",\"flags\":\"\",\"result\":\"$s\"}" ;;
   'M409 K"state.upTime"')
      echo "{\"key\":\"state.upTime\",\"flags\":\"\",\"result\":$(($(date +%s) - $(cat "$d/fw.boot")))}" ;;
   'M409 K"state.messageBox.title"')
      t=$(cat "$d/fw.title" 2>/dev/null) || t=
      if [ -n "$t" ]; then t="\"$t\""; else t=null; fi
      echo "{\"key\":\"state.messageBox.title\",\"flags\":\"\",\"result\":$t}" ;;
   M291*)
      echo "$2" | cut -c1-9 >> "$d/codes.log"
      echo "OTA Update" > "$d/fw.title" ;;
   M292)
      echo M292 >> "$d/codes.log"
      rm -f "$d/fw.title" ;;
esac
EOF
chmod +x "$MP_CODECONSOLE"
cat > "$tmp/DuetControlServer" <<'EOF'
#!/bin/sh
d=$(dirname "$0")
n=$(($(cat "$d/fw.pass") + 1))
echo "$n" > "$d/fw.pass"
echo "DCS -u" >> "$d/codes.log"
cat "$d/fw.out.$n"
if ! grep -q up-to-date "$d/fw.out.$n"; then
   echo $(($(cat "$d/fw.boot") + 1000)) > "$d/fw.boot"
   rm -f "$d/fw.title"
   printf 'updating\nstarting\nidle\n' > "$d/fw.status"
fi
exit "$(cat "$d/fw.rc.$n" 2>/dev/null || echo 0)"
EOF
chmod +x "$tmp/DuetControlServer"
export MP_DCS="$tmp/DuetControlServer" MP_FIRMWARE_POLL=1 MP_FIRMWARE_WAIT=20
fwscript="$here/../layer/mp-dsf.d/customize.overlay/usr/sbin/mp-dsf-firmware"
printf '[all]\ntryboot_a_b=1\nboot_partition=2\n[tryboot]\nboot_partition=3\n' > "$MP_AUTOBOOT"
echo 2 > "$tmp/active"
flashed='There is 1 outdated board:
- Duet 3 MB6HC (3.7.0-rc.1 -> 3.7.0-rc.1+2-mp.1)
Updating firmware on mainboard... Done!'
uptodate='All boards are up-to-date!'

# name, trybooted, status list, answers of each pass -> exit status, codes
fw_case() {
   if [ "$2" = yes ]; then printf '\0\0\0\1'; else printf '\0\0\0\0'; fi > "$MP_TRYBOOT_FLAG"
   printf '%s\n' $3 > "$tmp/fw.status"
   echo $(($(date +%s) - 5000)) > "$tmp/fw.boot"
   echo 0 > "$tmp/fw.pass"
   rm -f "$tmp/fw.title" "$tmp"/fw.out.* "$tmp"/fw.rc.*
   _i=0
   for _a in $4; do
      _i=$((_i + 1))
      case $_a in
         flash) printf '%s\n' "$flashed" > "$tmp/fw.out.$_i" ;;
         ok) printf '%s\n' "$uptodate" > "$tmp/fw.out.$_i" ;;
         fail) echo 'Error: board did not respond' > "$tmp/fw.out.$_i"; echo 1 > "$tmp/fw.rc.$_i" ;;
      esac
   done
   : > "$tmp/codes.log"
   _rc=0
   sh "$fwscript" 2>"$tmp/fw.log" || _rc=$?
   [ -z "${FWDEBUG:-}" ] || cat "$tmp/fw.log" >&2
   check "firmware: $1" "$5" "$_rc"
   check "firmware: $1, codes" "$6" "$(paste -sd, "$tmp/codes.log")"
}

fw_case "update, firmware current"   yes "starting starting idle" "ok" \
   0 "M291 S0 T,DCS -u,M292,M291 S1 T"
fw_case "update, one flash"          yes "starting idle" "flash ok" \
   0 "M291 S0 T,DCS -u,M291 S0 T,DCS -u,M292,M291 S1 T"
fw_case "update, flash fails"        yes "idle" "fail" \
   1 "DCS -u,M291 S1 T"
fw_case "update, never up to date"   yes "idle" "flash flash flash" \
   1 "DCS -u,M291 S0 T,DCS -u,M291 S0 T,DCS -u,M291 S1 T"
fw_case "normal boot, one flash"     no  "starting idle" "flash ok" \
   0 "DCS -u,DCS -u"
MP_FIRMWARE_WAIT=3 fw_case "update, never idle" yes "halted" "" \
   1 "M291 S0 T,M292,M291 S1 T"
MP_FIRMWARE_WAIT=3 fw_case "normal boot, never idle" no "halted" "" \
   0 ""
echo 3 > "$tmp/active"
MP_FIRMWARE_WAIT=3 fw_case "update, slot not committed" yes "idle" "" \
   1 "M291 S0 T,M292,M291 S1 T"
echo 2 > "$tmp/active"

[ "$fail" -eq 0 ] && echo "all tests passed"
exit "$fail"
