#!/bin/sh
# Tests for mp-role-guard, runnable on the build host with stubs in place of
# the device configuration, the identity, rpi-slot-tryboot and the reboot.
#
# What matters: an image of the other kind on a fresh slot restarts back,
# before the update connector can commit it, and nothing else ever restarts.

set -eu

here=$(dirname "$(readlink -f "$0")")
guard="$here/../layer/mp-identity.d/customize.overlay/usr/sbin/mp-role-guard"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The guard sources the library from its place on the device.
sed -e "s|/usr/lib/meltingplot/mp-common.sh|$here/../layer/mp-identity.d/customize.overlay/usr/lib/meltingplot/mp-common.sh|" \
   "$guard" > "$tmp/guard"

cat > "$tmp/rpi-slot-tryboot" <<'STUB'
#!/bin/sh
printf '[all]\ntryboot_a_b=1\nboot_partition=%s\n[tryboot]\nboot_partition=9\n' "$(cat "$(dirname "$0")/running")"
STUB
chmod +x "$tmp/rpi-slot-tryboot"

export MP_DEVICE_CONF="$tmp/device.conf" MP_IDENTITY_FILE="$tmp/mp-identity" \
   MP_SLOT_TRYBOOT="$tmp/rpi-slot-tryboot" MP_AUTOBOOT="$tmp/autoboot.txt" \
   MP_REBOOT="touch $tmp/rebooted"

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-50s %s\n' "$1" "$3"
   else
      printf 'FAIL %-50s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}

# image role, device role or "none", slot committed (y/n)
run() {
   printf 'MP_ROLE=%s\n' "$1" > "$tmp/device.conf"
   rm -f "$tmp/mp-identity" "$tmp/rebooted"
   [ "$2" = none ] || printf 'PRINTER_SERIAL=003\nROLE=%s\n' "$2" > "$tmp/mp-identity"
   echo 2 > "$tmp/running"
   if [ "$3" = y ]; then b=2; else b=3; fi
   printf '[all]\ntryboot_a_b=1\nboot_partition=%s\n[tryboot]\nboot_partition=9\n' "$b" > "$tmp/autoboot.txt"
   sh "$tmp/guard" 2>/dev/null
   [ -e "$tmp/rebooted" ] && echo reboot || echo boot
}

check "panel image on the panel, fresh slot"       boot   "$(run hmi hmi n)"
check "SBC image on the SBC, fresh slot"            boot   "$(run sbc sbc n)"
check "SBC image on the panel, fresh slot"          reboot "$(run sbc hmi n)"
check "panel image on the SBC, fresh slot"          reboot "$(run hmi sbc n)"
check "wrong image, slot committed: no loop"        boot   "$(run hmi sbc y)"
check "not commissioned yet"                        boot   "$(run hmi none n)"

# An identity without a role line compares nothing.
printf 'MP_ROLE=hmi\n' > "$tmp/device.conf"
printf 'PRINTER_SERIAL=003\n' > "$tmp/mp-identity"
rm -f "$tmp/rebooted"; echo 2 > "$tmp/running"
printf '[all]\nboot_partition=3\n' > "$tmp/autoboot.txt"
sh "$tmp/guard" 2>/dev/null
check "identity without a role"                     boot   "$([ -e "$tmp/rebooted" ] && echo reboot || echo boot)"

# CRLF in the identity, as written on a FAT partition from Windows.
printf 'MP_ROLE=hmi\n' > "$tmp/device.conf"
printf 'PRINTER_SERIAL=003\r\nROLE=sbc\r\n' > "$tmp/mp-identity"
rm -f "$tmp/rebooted"
sh "$tmp/guard" 2>/dev/null
check "CRLF identity, wrong image, fresh slot"      reboot "$([ -e "$tmp/rebooted" ] && echo reboot || echo boot)"

[ "$fail" -eq 0 ] && echo "all tests passed"
exit "$fail"
