#!/bin/sh
# Tests for the build-time firmware replacement, with a fake root and stubs
# in place of vfetch and dpkg-divert.
#
# What matters here is refusal: a line that is wrong in any way has to stop
# the build before a file is touched. A firmware under the wrong name is never
# flashed, and one that does not match its pin is exactly what the pin is
# there to keep out.

set -eu

here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

script="$here/../layer/mp-dsf.d/bin/mp-dsf-firmware-files"
root="$tmp/root"
fw="$root/opt/dsf/sd/firmware"
distrib="$root/usr/share/meltingplot/firmware-distrib"
published="$tmp/published"
mkdir -p "$tmp/bin" "$published"

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-46s %s\n' "$1" "$3"
   else
      printf 'FAIL %-46s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}

# vfetch stub: serves whatever lies below $PUBLISHED under the last part of
# the URL and checks the pin the way the real one does.
cat > "$tmp/bin/vfetch" <<'STUB'
#!/bin/sh
set -eu
read -r name sum src < "$1"
f="$PUBLISHED/${src##*/}"
[ -f "$f" ] || { echo "vfetch stub: nothing published at $src" >&2; exit 1; }
[ "sha256:$(sha256sum "$f" | cut -d' ' -f1)" = "$sum" ] || { echo "vfetch stub: checksum mismatch" >&2; exit 1; }
cp "$f" "$2"
STUB

# chroot stub: the only call expected is dpkg-divert. It moves the file and
# records the diversion the way dpkg does, three lines per entry.
cat > "$tmp/bin/chroot" <<'STUB'
#!/bin/sh
set -eu
root=$1; shift
case "$*" in
   "dpkg-divert --local --rename --add --divert "*) ;;
   *) echo "chroot stub: unexpected call: $*" >&2; exit 2 ;;
esac
to=$6; from=$7
mkdir -p "$root$(dirname "$to")"
mv "$root$from" "$root$to"
printf '%s\n%s\n:\n' "$from" "$to" >> "$root/var/lib/dpkg/diversions"
STUB
chmod +x "$tmp/bin/vfetch" "$tmp/bin/chroot"
PATH="$tmp/bin:$PATH"; export PATH
PUBLISHED=$published; export PUBLISHED

fresh_root() {
   rm -rf "$root"
   mkdir -p "$fw" "$root/var/lib/dpkg"
   : > "$root/var/lib/dpkg/diversions"
   for b in MB6HC TOOL1LC EXP1HCL; do
      printf 'packaged %s\n' "$b" > "$fw/Duet3Firmware_$b.bin"
      chmod 0664 "$fw/Duet3Firmware_$b.bin"
   done
}

# run <list> -> ok|fail; the script's output is kept in $tmp/out
run() {
   if IGconf_dsf_firmware_list=$1 bash "$script" "$root" > "$tmp/out" 2>&1; then
      echo ok
   else
      echo fail
   fi
}
sum_of() { sha256sum "$1" | cut -d' ' -f1; }
tool_file="$fw/Duet3Firmware_TOOL1LC.bin"

printf 'patched TOOL1LC\n' > "$published/Duet3Firmware_TOOL1LC.bin"
good=$(sum_of "$published/Duet3Firmware_TOOL1LC.bin")
base="https://github.com/Meltingplot/RepRapFirmware/releases/download/v3.7.0-rc.1+mp1"

# --- nothing listed -------------------------------------------------------

fresh_root
printf '# nothing yet\n\n' > "$tmp/empty.list"
check "empty list passes"            ok "$(run "$tmp/empty.list")"
check "empty list leaves the file"   "packaged TOOL1LC" "$(cat "$tool_file")"
[ -e "$distrib" ] && r=yes || r=no
check "empty list diverts nothing"   no "$r"

check "missing list fails"           fail "$(run "$tmp/nonexistent.list")"

# --- a good line ----------------------------------------------------------

fresh_root
printf '# a patched build\nDuet3Firmware_TOOL1LC.bin sha256:%s %s/Duet3Firmware_TOOL1LC.bin\n' \
   "$good" "$base" > "$tmp/good.list"
check "good line passes"             ok "$(run "$tmp/good.list")"
check "published build is in place"  "patched TOOL1LC" "$(cat "$tool_file")"
check "packaged copy is set aside"   "packaged TOOL1LC" "$(cat "$distrib/Duet3Firmware_TOOL1LC.bin" 2>/dev/null)"
check "diversion is recorded"        "/opt/dsf/sd/firmware/Duet3Firmware_TOOL1LC.bin" \
   "$(sed -n 1p "$root/var/lib/dpkg/diversions")"
check "mode is kept"                 664 "$(stat -c '%a' "$tool_file")"
check "other files untouched"        "packaged MB6HC" "$(cat "$fw/Duet3Firmware_MB6HC.bin")"
check "uppercase checksum accepted"  ok "$(fresh_root; printf 'Duet3Firmware_TOOL1LC.bin sha256:%s %s/Duet3Firmware_TOOL1LC.bin\n' \
   "$(printf '%s' "$good" | tr 'a-f' 'A-F')" "$base" > "$tmp/upper.list"; run "$tmp/upper.list")"

# Running again on the same root: the file is already diverted.
check "second run refuses"           fail "$(run "$tmp/good.list")"
check "second run keeps the build"   "patched TOOL1LC" "$(cat "$tool_file")"

# --- refusals, each with the file left alone ------------------------------

refused() {
   # $1 label, $2 list content
   fresh_root
   printf '%s\n' "$2" > "$tmp/bad.list"
   check "$1 fails"              fail "$(run "$tmp/bad.list")"
   check "$1 leaves the file"    "packaged TOOL1LC" "$(cat "$tool_file")"
   check "$1 diverts nothing"    "" "$(cat "$root/var/lib/dpkg/diversions")"
}

refused "unknown file" \
   "Duet3Firmware_NOPE.bin sha256:$good $base/Duet3Firmware_NOPE.bin"
refused "path instead of a name" \
   "../sys/config.g sha256:$good $base/config.g"
refused "http location" \
   "Duet3Firmware_TOOL1LC.bin sha256:$good http://example.com/Duet3Firmware_TOOL1LC.bin"
refused "local path" \
   "Duet3Firmware_TOOL1LC.bin sha256:$good $published/Duet3Firmware_TOOL1LC.bin"
refused "short checksum" \
   "Duet3Firmware_TOOL1LC.bin sha256:abc $base/Duet3Firmware_TOOL1LC.bin"
refused "missing column" \
   "Duet3Firmware_TOOL1LC.bin sha256:$good"
refused "extra column" \
   "Duet3Firmware_TOOL1LC.bin sha256:$good $base/Duet3Firmware_TOOL1LC.bin extra"
refused "checksum mismatch" \
   "Duet3Firmware_TOOL1LC.bin sha256:$(printf '%064d' 0) $base/Duet3Firmware_TOOL1LC.bin"
refused "not published" \
   "Duet3Firmware_TOOL1LC.bin sha256:$good $base/Duet3Firmware_MISSING.bin"
refused "listed twice" \
   "Duet3Firmware_TOOL1LC.bin sha256:$good $base/Duet3Firmware_TOOL1LC.bin
Duet3Firmware_TOOL1LC.bin sha256:$good $base/Duet3Firmware_TOOL1LC.bin"

# A good line followed by a bad one: the list is checked as a whole before
# anything is fetched or moved.
refused "good line before a bad one" \
   "Duet3Firmware_TOOL1LC.bin sha256:$good $base/Duet3Firmware_TOOL1LC.bin
Duet3Firmware_MB6HC.bin sha256:$good http://example.com/Duet3Firmware_MB6HC.bin"

# The refusal has to say why, in terms of the rule that was broken.
fresh_root
printf 'Duet3Firmware_TOOL1LC.bin sha256:%s %s/Duet3Firmware_TOOL1LC.bin\n' "$good" "$published" > "$tmp/bad.list"
run "$tmp/bad.list" > /dev/null
grep -q "only published builds" "$tmp/out" && r=yes || r=no
check "local path names the rule"    yes "$r"

[ "$fail" -eq 0 ] && echo "all tests passed"
exit "$fail"
