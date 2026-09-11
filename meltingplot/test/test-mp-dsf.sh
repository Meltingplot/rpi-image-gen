#!/bin/sh
# Tests for the DSF-side helpers, runnable on the build host with stubs in
# place of CodeConsole and rpi-slot-tryboot.
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
MP_OTA_STATE="$tmp/ota_state"
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

# --- update connector state -----------------------------------------------

rm -f "$MP_OTA_STATE"
check "ota state absent"       ""             "$(mp_ota_state)"
mp_ota_restart_pending && r=yes || r=no
check "pending: no state file" no "$r"
printf 'state=TRYBOOTWAIT\r\ndeployment=abc\r\n' > "$MP_OTA_STATE"
check "ota state CRLF"         "TRYBOOTWAIT"  "$(mp_ota_state)"
mp_ota_restart_pending && r=yes || r=no
check "pending: tryboot wait"  yes "$r"
printf 'state=REBOOTPROMPT\n' > "$MP_OTA_STATE"
mp_ota_restart_pending && r=yes || r=no
check "pending: reboot prompt" yes "$r"
printf 'state=FETCHDEPLOYMENT\n' > "$MP_OTA_STATE"
mp_ota_restart_pending && r=yes || r=no
check "pending: still downloading" no "$r"
printf 'deployment=abc\n' > "$MP_OTA_STATE"
mp_ota_restart_pending && r=yes || r=no
check "pending: no state line" no "$r"

[ "$fail" -eq 0 ] && echo "all tests passed"
exit "$fail"
