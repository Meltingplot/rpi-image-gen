#!/bin/sh
# Tests for mp-hmi-net-guard, runnable on the build host with temporary
# directories in place of NetworkManager's.
#
# What matters: a copy or a tombstone of a network the image ships goes, for
# the printer network and the camera network alike, and the operator's own
# profiles stay.

set -eu

here=$(dirname "$(readlink -f "$0")")
guard="$here/../layer/mp-hmi-net.d/customize.overlay/usr/sbin/mp-hmi-net-guard"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The guard sources the library from its place on the device.
sed -e "s|/usr/lib/meltingplot/mp-common.sh|$here/../layer/mp-identity.d/customize.overlay/usr/lib/meltingplot/mp-common.sh|" \
   "$guard" > "$tmp/guard"

export MP_NM_LIB="$tmp/lib" MP_NM_ETC="$tmp/etc"
mkdir -p "$tmp/lib" "$tmp/etc"

printer=d7286c99-5c35-4362-8dab-6f5f33bac9a8
camera=b6f77c33-467e-480f-a3e6-1603e411d15a
printf '[connection]\nid=Printer network\nuuid=%s\n' "$printer" > "$tmp/lib/mp-printer-net.nmconnection"
printf '[connection]\nid=Camera network\nuuid=%s\n' "$camera" > "$tmp/lib/mp-camera-net.nmconnection"

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-50s %s\n' "$1" "$3"
   else
      printf 'FAIL %-50s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}
there() { [ -e "$tmp/etc/$1" ] && echo there || echo gone; }

# What the device made of them, and what the operator set up.
printf '[connection]\nid=Printer network\nuuid=%s\n' "$printer" > "$tmp/etc/Printer network.nmconnection"
printf '[connection]\nid=Camera\nuuid=%s\n' "$camera" > "$tmp/etc/Camera.nmconnection"
: > "$tmp/etc/$camera.nmmeta"
: > "$tmp/etc/$printer.nmmeta"
printf '[connection]\nid=Workshop\nuuid=0a7f2a52-1c1e-4bd4-8f3c-3a2b8d0e6b11\n' > "$tmp/etc/Workshop.nmconnection"
printf '[connection]\r\nid=Camera\r\nuuid=%s\r\n' "$camera" > "$tmp/etc/crlf.nmconnection"

sh "$tmp/guard" 2>/dev/null

check "changed printer network"          gone  "$(there 'Printer network.nmconnection')"
check "printer network tombstone"        gone  "$(there "$printer.nmmeta")"
check "changed camera network"           gone  "$(there 'Camera.nmconnection')"
check "camera network tombstone"         gone  "$(there "$camera.nmmeta")"
check "camera network with CRLF"         gone  "$(there 'crlf.nmconnection')"
check "the operator's wifi"              there "$(there 'Workshop.nmconnection')"
check "shipped profiles untouched"       2     "$(ls "$tmp/lib" | wc -l | tr -d ' ')"

# Nothing to do is no error.
sh "$tmp/guard" 2>/dev/null && r=0 || r=$?
check "second run"                       0     "$r"

# A shipped profile without a uuid would guard nothing; that is an image fault.
printf '[connection]\nid=Broken\n' > "$tmp/lib/mp-broken.nmconnection"
sh "$tmp/guard" 2>/dev/null && r=0 || r=$?
check "shipped profile without a uuid"   fail  "$([ "$r" -ne 0 ] && echo fail || echo ok)"

[ "$fail" -eq 0 ] && echo "all tests passed"
exit "$fail"
