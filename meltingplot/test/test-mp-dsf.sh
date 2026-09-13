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
# asked.

export MP_LIB="$tmp/lib"
mkdir -p "$MP_LIB"
cp "$here/../layer/mp-identity.d/customize.overlay/usr/lib/meltingplot/mp-common.sh" "$MP_LIB/"
cp "$here/../layer/mp-dsf.d/customize.overlay/usr/lib/meltingplot/mp-dsf.sh" "$MP_LIB/"
export MP_DEVICE_CONF MP_CODECONSOLE MP_SLOT_TRYBOOT MP_AUTOBOOT
export MP_SYSTEMCTL="$tmp/systemctl"
cat > "$MP_SYSTEMCTL" <<'EOF'
#!/bin/sh
case $1 in
   is-active) cat "$(dirname "$0")/unit.state"; [ "$(cat "$(dirname "$0")/unit.state")" = active ] ;;
   *) echo "$1 $2" >> "$(dirname "$0")/systemctl.log" ;;
esac
EOF
chmod +x "$MP_SYSTEMCTL"
gate="$here/../layer/mp-dsf.d/customize.overlay/usr/sbin/mp-ota-gate"

# printer status, unit state, slot committed -> expected systemctl calls
gate_case() {
   echo "{\"key\":\"state.status\",\"flags\":\"\",\"result\":$2}" > "$tmp/status.out"
   echo "$3" > "$tmp/unit.state"
   if [ "$4" = committed ]; then echo 2 > "$tmp/active"; else echo 3 > "$tmp/active"; fi
   : > "$tmp/systemctl.log"
   sh "$gate" 2>>"$tmp/gate.log"
   check "gate: $1" "$5" "$(paste -sd, "$tmp/systemctl.log")"
}

cat > "$MP_CODECONSOLE" <<'EOF'
#!/bin/sh
cat "$(dirname "$0")/status.out"
exit "$(cat "$(dirname "$0")/status.rc")"
EOF
chmod +x "$MP_CODECONSOLE"
echo 0 > "$tmp/status.rc"
printf '[all]\ntryboot_a_b=1\nboot_partition=2\n[tryboot]\nboot_partition=3\n' > "$MP_AUTOBOOT"

gate_case "idle, connector running"        '"idle"'       active     committed   ""
gate_case "idle, connector stopped"        '"idle"'       inactive   committed   "start rpi-connect-ota.service"
gate_case "idle, connector failed"         '"idle"'       failed     committed   "start rpi-connect-ota.service"
gate_case "printing, connector running"    '"processing"' active     committed   "stop rpi-connect-ota.service"
gate_case "printing, connector starting"   '"processing"' activating committed   "stop rpi-connect-ota.service"
gate_case "printing, connector stopped"    '"processing"' inactive   committed   ""
gate_case "paused, connector running"      '"paused"'     active     committed   "stop rpi-connect-ota.service"
gate_case "unreachable, connector running" 'null'         active     committed   "stop rpi-connect-ota.service"
gate_case "printing, slot not committed"   '"processing"' active     uncommitted ""
gate_case "unreachable, not committed"     'null'         inactive   uncommitted "start rpi-connect-ota.service"
rm -f "$MP_CODECONSOLE"
gate_case "no control server, running"     '"idle"'       active     committed   "stop rpi-connect-ota.service"

[ "$fail" -eq 0 ] && echo "all tests passed"
exit "$fail"
