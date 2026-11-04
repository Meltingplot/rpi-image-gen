#!/bin/sh
# Tests for the shared DSF paths across an update: the build marks every file
# the image ships below dsf.conf's paths as image-owned
# (mp-dsf.d/hooks/postbuild40-dsf-static), and rpi-persistent-shared-init puts
# those back from the active slot on boot while files the device added stay.
#
# Runs both against a fake root. The filament profiles "PLA" and "PLA 1.2mm"
# are the case that matters: a parser that split paths at spaces would take
# "StaticPath=.../PLA 1.2mm/load.g" for ".../PLA" and remove that whole
# profile from the device, its temps.g with it.

set -eu

here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

static_hook="$here/../layer/mp-dsf.d/hooks/postbuild40-dsf-static"
dsf_conf="$here/../layer/mp-dsf.d/customize.overlay/etc/rpi-image-gen/slot-shared.d/dsf.conf"
shared_init="$here/../../image/gpt/ab_userdata/image.d/postbuild.overlay/usr/sbin/rpi-persistent-shared-init"

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
ln -s index.html "$sd/www/start.html"

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
check "static: symlink"               yes "$(grep -qxF 'StaticPath=/opt/dsf/sd/www/start.html' "$static" && echo yes || echo no)"
check "static: no directories"        0   "$(grep -c -e '=/opt/dsf/sd/filaments/PLA$' -e '=/opt/dsf/sd/sys$' -e '=/opt/dsf/sd/sys/meltingplot$' "$static" || true)"
check "static: files only"            6   "$(grep -c '^StaticPath=' "$static")"

RPI_SHARED_INIT_ROOT=$root sh "$shared_init" >/dev/null
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
check "symlink put back"              index.html "$(readlink "$sh_sd/www/start.html" || echo missing)"

# A second boot changes nothing.
before=$(cd "$root/persistent/shared" && find . -type f -exec sha256sum {} + | sort)
RPI_SHARED_INIT_ROOT=$root sh "$shared_init" >/dev/null
after=$(cd "$root/persistent/shared" && find . -type f -exec sha256sum {} + | sort)
check "second boot changes nothing"   same "$([ "$before" = "$after" ] && echo same || echo changed)"

exit $fail
