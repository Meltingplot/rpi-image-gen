#!/bin/sh
# Tests for the shared DSF paths across an update: the build marks every file
# the image ships below dsf.conf's paths as image-owned
# (mp-dsf.d/hooks/postbuild40-dsf-static), slot-state compiles that into its
# manifest and tmpfiles file (slot-state-manifest), and systemd-tmpfiles puts
# those files back from the active slot on boot while files the device added
# stay (persistent-shared-init.service).
#
# Runs all three against a fake root, the tmpfiles file without the lines that
# lay down the rest of the persistent partition, which need root. The filament
# profiles "PLA" and "PLA 1.2mm" are the case that matters: a path split at
# its space would take ".../PLA 1.2mm/load.g" for ".../PLA" and remove that
# whole profile from the device, its temps.g with it.

set -eu

here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

static_hook="$here/../layer/mp-dsf.d/hooks/postbuild40-dsf-static"
dsf_conf="$here/../layer/mp-dsf.d/customize.overlay/etc/rpi-image-gen/slot-shared.d/dsf.conf"
compile="$here/../../image/common/slot-state.d/self/host/bin/slot-state-manifest"

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-46s %s\n' "$1" "$3"
   else
      printf 'FAIL %-46s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}

root=$tmp/root
sd=$root/opt/dsf/sd
sh_sd=$root/persistent/shared/opt/dsf/sd
put() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
get() { cat "$1" 2>/dev/null || echo missing; }

# The image: what the new slot ships.
install -D -m 0644 "$dsf_conf" "$root/etc/rpi-image-gen/slot-shared.d/dsf.conf"
put "$sd/sys/config.g" new
put "$sd/sys/meltingplot/added.g" new
put "$sd/filaments/PLA 1.2mm/load.g" new
put "$sd/filaments/PLA/load.g" new
put "$sd/www/index.html" new
for d in $(sed -n 's/^SharedPath=//p' "$dsf_conf"); do mkdir -p "$root$d"; done

# The device: what the old slot left in the shared copy, and its own files.
put "$sh_sd/sys/config.g" old
put "$sh_sd/sys/overrides/global-override.g" device
put "$sh_sd/filaments/PLA 1.2mm/load.g" old
put "$sh_sd/filaments/PLA 1.2mm/temps.g" device
put "$sh_sd/filaments/PLA/load.g" old
put "$sh_sd/filaments/PLA/temps.g" device
put "$sh_sd/filaments/My profile/config.g" device
put "$sh_sd/www/js/Plugin.js" device
put "$sh_sd/www/index.html" old

bash "$static_hook" "$root" 2>/dev/null
static=$root/etc/rpi-image-gen/slot-shared.d/dsf-static.conf
check "static list version"           Version=1 "$(grep -m1 '^Version=' "$static")"
check "static: file with spaces"      yes "$(grep -qxF 'StaticPath=/opt/dsf/sd/filaments/PLA 1.2mm/load.g' "$static" && echo yes || echo no)"
check "static: no directories"        0   "$(grep -c -e '=/opt/dsf/sd/filaments/PLA$' -e '=/opt/dsf/sd/sys$' -e '=/opt/dsf/sd/sys/meltingplot$' "$static" || true)"
check "static: files only"            5   "$(grep -c '^StaticPath=' "$static")"

python3 "$compile" compile /persistent "$root"
manifest=$root/usr/lib/rpi-image-gen/slot-state.manifest
tmpfiles=$root/usr/lib/rpi-image-gen/slot-state.tmpfiles
check "manifest: space escaped"       yes "$(grep -qxF 'StaticPath /opt/dsf/sd/filaments/PLA\x201.2mm/load.g /persistent/shared/opt/dsf/sd/filaments/PLA\x201.2mm/load.g /opt/dsf/sd/filaments/PLA\x201.2mm/load.g -' "$manifest" && echo yes || echo no)"
check "manifest: five fields a line"  0   "$(grep -v '^#' "$manifest" | awk 'NF != 5' | wc -l)"

boot() {
   grep -E '^(R|C\+) /persistent/shared/' "$tmpfiles" > "$tmp/shared.tmpfiles"
   systemd-tmpfiles --root="$root" --remove --create "$tmp/shared.tmpfiles"
}

boot
check "image file replaced"           new    "$(get "$sh_sd/sys/config.g")"
check "new image file added"          new    "$(get "$sh_sd/sys/meltingplot/added.g")"
check "device override kept"          device "$(get "$sh_sd/sys/overrides/global-override.g")"
check "profile with spaces replaced"  new    "$(get "$sh_sd/filaments/PLA 1.2mm/load.g")"
check "its device file kept"          device "$(get "$sh_sd/filaments/PLA 1.2mm/temps.g")"
check "profile PLA replaced"          new    "$(get "$sh_sd/filaments/PLA/load.g")"
check "PLA's device file kept"        device "$(get "$sh_sd/filaments/PLA/temps.g")"
check "device's own profile kept"     device "$(get "$sh_sd/filaments/My profile/config.g")"
check "DWC file replaced"             new    "$(get "$sh_sd/www/index.html")"
check "plugin web file kept"          device "$(get "$sh_sd/www/js/Plugin.js")"

# A second boot changes nothing.
before=$(cd "$root/persistent/shared" && find . -type f -exec sha256sum {} + | sort)
boot
after=$(cd "$root/persistent/shared" && find . -type f -exec sha256sum {} + | sort)
check "second boot changes nothing"   same "$([ "$before" = "$after" ] && echo same || echo changed)"

# What slot-state cannot put back stops the build, with the file named.
bad=$tmp/bad
install -D -m 0644 "$dsf_conf" "$bad/etc/rpi-image-gen/slot-shared.d/dsf.conf"
mkdir -p "$bad/opt/dsf/sd/www"
ln -s index.html "$bad/opt/dsf/sd/www/start.html"
check "symlink stops the build"       yes "$(bash "$static_hook" "$bad" 2>&1 | grep -q 'start.html is a symlink' && echo yes || echo no)"
rm "$bad/opt/dsf/sd/www/start.html"
put "$bad/opt/dsf/sd/www/js[1].js" x
check "glob character stops the build" yes "$(bash "$static_hook" "$bad" 2>&1 | grep -q 'glob' && echo yes || echo no)"

exit $fail
