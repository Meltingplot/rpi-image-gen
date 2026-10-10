#!/bin/sh
# Tests for mp-hmi-ota-state, runnable on the build host with stubs in place
# of systemctl and pkill.
#
# What matters: the update page comes while the connector installs and goes
# when it stops without a restart, and haproxy and the browser are touched
# only when that changes.

set -eu

here=$(dirname "$(readlink -f "$0")")
script="$here/../layer/mp-hmi-proxy.d/customize.overlay/usr/sbin/mp-hmi-ota-state"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sed -e "s|/usr/lib/meltingplot/mp-common.sh|$here/../layer/mp-identity.d/customize.overlay/usr/lib/meltingplot/mp-common.sh|" \
   "$script" > "$tmp/run"

mkdir "$tmp/bin"
# systemctl: is-active answers from active.<unit>, everything else is logged
cat > "$tmp/bin/systemctl" <<'STUB'
#!/bin/sh
d=$(dirname "$0")/..
[ "$1" = -q ] && shift
case $1 in
   is-active) [ -e "$d/active.$2" ] ;;
   *) echo "systemctl $*" >> "$d/calls" ;;
esac
STUB
cat > "$tmp/bin/pkill" <<'STUB'
#!/bin/sh
echo "pkill $*" >> "$(dirname "$0")/../calls"
STUB
chmod +x "$tmp/bin/systemctl" "$tmp/bin/pkill"

# the slot this boot runs is 2; autoboot.txt says which slot is committed
cat > "$tmp/bin/rpi-slot-tryboot" <<'STUB'
#!/bin/sh
printf '[all]\ntryboot_a_b=1\nboot_partition=2\n[tryboot]\nboot_partition=3\n'
STUB
chmod +x "$tmp/bin/rpi-slot-tryboot"
committed() {
   printf '[all]\ntryboot_a_b=1\nboot_partition=%s\n[tryboot]\nboot_partition=9\n' "$1" > "$tmp/autoboot.txt"
}
committed 2

printf 'MP_USER=meltingplot\n' > "$tmp/device.conf"
export PATH="$tmp/bin:$PATH" MP_DEVICE_CONF="$tmp/device.conf" \
   MP_OTA_STATE_FILE="$tmp/ota_state" MP_PROXY_DIR="$tmp/proxy" \
   MP_SLOT_TRYBOOT="$tmp/bin/rpi-slot-tryboot" MP_AUTOBOOT="$tmp/autoboot.txt"

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-46s %s\n' "$1" "$3"
   else
      printf 'FAIL %-46s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}
# state of the connector, then: what the list holds, what was called
step() {
   printf 'state=%s\nbootid=0\n' "$1" > "$tmp/ota_state"
   rm -f "$tmp/calls"
   sh "$tmp/run" 2>/dev/null
   printf '%s|%s' "$(cat "$tmp/proxy/ota.lst" 2>/dev/null)" \
      "$({ cat "$tmp/calls" 2>/dev/null || true; } | tr '\n' ';')"
}

touch "$tmp/active.rpi-connect-ota.service"
# at boot, before haproxy: the list is created, nothing restarted
check "boot, idle"                  "|"  "$(step IDLE)"
touch "$tmp/active.haproxy.service"
check "idle again, nothing changes" "|"  "$(step IDLE)"
check "download starts"             "/|systemctl restart haproxy.service;pkill -u meltingplot -f ^/usr/lib/chromium/chromium;" "$(step DOWNLOAD)"
check "install goes on, nothing new" "/|" "$(step INSTALL)"
check "install fails"               "|systemctl reload haproxy.service;" "$(step FAILURE)"
rm "$tmp/active.rpi-connect-ota.service"
check "stale state, connector down" "|"  "$(step INSTALL)"
touch "$tmp/active.rpi-connect-ota.service"

# The boot after the restart into the update: the slot is not committed yet
# and the state file still says TRYBOOT until the connector moves on.
committed 3
check "trybooted slot, state left over" "|" "$(step TRYBOOT)"
check "trybooted slot, connector on"    "|" "$(step TRYBOOTED)"
committed 2
check "committed, back to idle"         "|" "$(step IDLE)"

[ "$fail" -eq 0 ] && echo "all tests passed"
exit "$fail"
