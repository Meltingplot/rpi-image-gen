#!/bin/sh
# Tests for mp-bundle-guard, runnable on the build host with stubs in place
# of systemctl and busctl.
#
# What matters: a bundle of another Meltingplot image is stopped before the
# connector restarts into it, the connector comes back idle and Connect hears
# why; this image's own bundles, and anything the guard cannot judge, go
# ahead untouched.

set -eu

here=$(dirname "$(readlink -f "$0")")
script="$here/../layer/mp-connect.d/customize.overlay/usr/sbin/mp-bundle-guard"
units="$here/../layer/mp-connect.d/customize.overlay/usr/lib/systemd/system"
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
# busctl: logs the method and its arguments, fails while busctl.fail exists
cat > "$tmp/bin/busctl" <<'STUB'
#!/bin/sh
d=$(dirname "$0")/..
shift 5
echo "busctl $*" >> "$d/calls"
[ ! -e "$d/busctl.fail" ]
STUB
chmod +x "$tmp/bin/systemctl" "$tmp/bin/busctl"

printf 'MP_USER=meltingplot\nMP_ROLE=hmi\nMP_IMAGE=mp-hmi-pi5\n' > "$tmp/device.conf"
export PATH="$tmp/bin:$PATH" MP_DEVICE_CONF="$tmp/device.conf" \
   MP_OTA_STATE_FILE="$tmp/ota_state" MP_KILL_WAIT=0
touch "$tmp/active.rpi-connect-ota.service"

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-44s\n' "$1"
   else
      printf 'FAIL %-44s\n     expected=%s\n     got=     %s\n' "$1" "$2" "$3"
      fail=1
   fi
}

rel=https://github.com/Meltingplot/rpi-image-gen/releases/download
hmi="$rel/hmi-pi5%2Fv0.1.0-rc.6/mp-hmi-pi5-0.1.0-rc.6.update.tar.zst"
duet="$rel/duet-pi5%2Fv0.1.0-rc.60/mp-duet-pi5-0.1.0-rc.60.update.tar.zst"

# The connector's state file as it writes it while it works on a deployment.
state() {
   printf 'state=%s\nbootid=034108a7bb5cf678d7178e6d650ad3b8\ntrybooktoken=3\n' "$1" > "$tmp/ota_state"
   [ -z "${2-}" ] || printf 'depid=c237f411-8584\ndepurl=%s\ndephash=ab12\n' "$2" >> "$tmp/ota_state"
}
# what was called, then the state file afterwards
step() {
   rm -f "$tmp/calls"
   sh "$tmp/run" 2>/dev/null
   printf '%s|%s' "$({ cat "$tmp/calls" 2>/dev/null || true; } | tr '\n' ';')" \
      "$(tr '\n' ';' < "$tmp/ota_state")"
}

idle='state=IDLE;bootid=034108a7bb5cf678d7178e6d650ad3b8;trybooktoken=3;'
stopped="systemctl stop rpi-connect-ota.service;\
systemctl kill --kill-whom=all rpi-connect-ota.service;\
systemctl kill --kill-whom=all --signal=SIGKILL rpi-connect-ota.service;\
busctl FailDeployment ss c237f411-8584 mp-duet-pi5-0.1.0-rc.60.update.tar.zst is not an image for this device, which runs mp-hmi-pi5;\
systemctl --no-block start rpi-connect-ota.service;"

state IDLE
check "idle"                        "|$idle" "$(step)"

state DOWNLOAD "$hmi"
check "own bundle downloads"        "|$(tr '\n' ';' < "$tmp/ota_state")" "$(step)"

state DOWNLOAD "$duet"
check "printer SBC bundle downloads" "$stopped|$idle" "$(step)"

state INSTALL "$duet"
check "printer SBC bundle installs"  "$stopped|$idle" "$(step)"

state DOWNLOAD "$duet?X-Amz-Signature=abc#x"
check "query and fragment ignored"   "$stopped|$idle" "$(step)"

state DOWNLOAD "$rel/x/mp-hmi-pi5x-1.0.update.tar.zst"
check "a longer image name is another" "$(printf %s "$stopped" | sed 's/mp-duet-pi5-0.1.0-rc.60/mp-hmi-pi5x-1.0/')|$idle" "$(step)"

state DOWNLOAD "https://example.com/bundles/1234"
check "unknown naming goes ahead"   "|$(tr '\n' ';' < "$tmp/ota_state")" "$(step)"

state FAILURE "$duet"
check "not installing, left alone"  "|$(tr '\n' ';' < "$tmp/ota_state")" "$(step)"

rm "$tmp/active.rpi-connect-ota.service"
state INSTALL "$duet"
check "stale state, connector down" "|$(tr '\n' ';' < "$tmp/ota_state")" "$(step)"
touch "$tmp/active.rpi-connect-ota.service"

touch "$tmp/busctl.fail"
state DOWNLOAD "$duet"
check "Connect unreachable: idle all the same" "$stopped|$idle" "$(step)"
rm "$tmp/busctl.fail"

printf 'MP_USER=meltingplot\nMP_ROLE=hmi\n' > "$tmp/device.conf"
state DOWNLOAD "$duet"
check "image without a name: unchecked" "|$(tr '\n' ';' < "$tmp/ota_state")" "$(step)"

# The guard stops and starts the connector itself, so it must not be ordered
# against it (see the deadlock in test-mp-hmi-ota-state.sh), and it must not
# hang for ever.
order=$(grep -E '^(After|Before|Wants|Requires|BindsTo)=' "$units/mp-bundle-guard.service" |
   grep -c rpi-connect-ota || true)
check "not ordered against the connector" 0 "$order"
grep -q '^TimeoutStartSec=' "$units/mp-bundle-guard.service" && r=yes || r=no
check "cannot hang for ever"              yes "$r"
r=$(sed -n 's/^PathChanged=//p' "$units/mp-bundle-guard.path")
check "watches the connector's state file" /bootfs/ota_state "$r"

[ "$fail" -eq 0 ] && echo "all tests passed"
exit "$fail"
