#!/bin/sh
# Tests for hooks/deploy20-mp-release, runnable on the build host.
#
# What matters: the update bundle reaches the release under the name
# mp-bundle-guard goes by, with the hash a device checks it against, and a
# build whose bundle has gone missing fails rather than publishing without it.

set -eu

here=$(dirname "$(readlink -f "$0")")
hook="$here/../hooks/deploy20-mp-release"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-44s\n' "$1"
   else
      printf 'FAIL %-44s\n     expected=%s\n     got=     %s\n' "$1" "$2" "$3"
      fail=1
   fi
}

version=0.1.0-rc.80
image=mp-duet-pi5-$version
bundle=$image.update.tar.zst
ota=ota-$image-$version.tar.zst

# <deploy dir> <update format>, with the environment of a deploy hook
run() {
   IGTOP=$tmp/no-repo IGconf_image_name=$image IGconf_image_version=$version \
   IGconf_artefact_version=$version IGconf_image_updatefmt=$2 \
      bash "$hook" "$1" 2>/dev/null
}
names() { ls "$1" | tr '\n' ' '; }
sum_of() { awk -v f="$2" '$2 == f { print $1 }' "$1/SHA256SUMS"; }
in_release_json() {
   python3 -c 'import json, sys
print(sys.argv[2] in [a["name"] for a in json.load(open(sys.argv[1]))["artefacts"]])' "$1/release.json" "$2"
}

# An image with a bundle, as rpi-image-gen deployed it.
d=$tmp/ab; mkdir "$d"
echo bundle > "$d/$ota"
echo whole > "$d/$ota.sha256sum"
echo manifest > "$d/$ota.manifest.sha256sum"
echo image > "$d/$image.img.zst"
run "$d" otamaker
check "the bundle goes by the guard's name" \
   "SHA256SUMS $image.img.zst $bundle $bundle.manifest.sha256sum $bundle.sha256sum release.json " \
   "$(LC_ALL=C names "$d")"
check "SHA256SUMS holds the hash of the whole bundle" \
   "$(sha256sum "$d/$bundle" | cut -d' ' -f1)" "$(sum_of "$d" "$bundle")"
check "release.json lists it" True "$(in_release_json "$d" "$bundle")"
check "the manifest hash stays beside it" manifest "$(cat "$d/$bundle.manifest.sha256sum")"

# An image that makes no bundle: the installer card, which has no update
# format at all, and an image that turned it off.
for fmt in "" none; do
   d=$tmp/none$fmt; mkdir "$d"
   echo image > "$d/$image.img.zst"
   rc=0; run "$d" "$fmt" || rc=$?
   check "no bundle wanted, format '$fmt'" "0 SHA256SUMS $image.img.zst release.json " \
      "$rc $(LC_ALL=C names "$d")"
done

# The bundle should be there and is not.
d=$tmp/gone; mkdir "$d"
echo image > "$d/$image.img.zst"
rc=0; run "$d" otamaker || rc=$?
check "a missing bundle fails the build" 1 "$rc"

exit $fail
