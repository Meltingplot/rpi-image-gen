#!/bin/sh
# Tests for the build-time replacement of Duet Web Control, with a fake root
# and a stub in place of vfetch.
#
# What matters here is refusal: a pin that is wrong in any way has to stop the
# build before the packaged web interface is touched, and a release that is
# not the pinned version must never reach a printer.

set -eu

here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

script="$here/../layer/mp-dsf.d/bin/mp-dsf-dwc"
root="$tmp/root"
dwc="$root/opt/dsf/dwc"
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

# vfetch stub: serves $PUBLISHED/<tag>/<asset> for .../download/<tag>/<asset>,
# checks the pin the way the real one does, and records the URL it was given.
cat > "$tmp/bin/vfetch" <<'STUB'
#!/bin/sh
set -eu
read -r name sum src < "$1"
echo "$src" > "$PUBLISHED/last-url"
f="$PUBLISHED/$(basename "$(dirname "$src")")/${src##*/}"
[ -f "$f" ] || { echo "vfetch stub: nothing published at $src" >&2; exit 1; }
[ "sha256:$(sha256sum "$f" | cut -d' ' -f1)" = "$sum" ] || { echo "vfetch stub: checksum mismatch" >&2; exit 1; }
cp "$f" "$2"
STUB
chmod +x "$tmp/bin/vfetch"
PATH="$tmp/bin:$PATH"; export PATH
PUBLISHED=$published; export PUBLISHED

fresh_root() {
   rm -rf "$root"
   mkdir -p "$dwc/js"
   printf 'packaged index\n' > "$dwc/index.html"
   printf 'version:`3.7.0-rc.1`\n' > "$dwc/js/app-packaged.js"
}

# publish <tag> <version in the bundle> [extra entry] -> sha256 of the asset
publish() {
   python3 - "$published/$1" "$2" "${3:-}" <<'PY'
import pathlib, sys, zipfile
d, version, extra = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
d.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(d / "DuetWebControl-SBC.zip", "w") as z:
    if extra != "no-index":
        z.writestr("index.html", "fork index\n")
    z.writestr("js/app-fork.js", "const p={name:`DuetWebControl`,version:`%s`};\n" % version)
    z.writestr("css/app-fork.css", "body{}\n")
    if extra == "escape":
        z.writestr("../escape.txt", "outside\n")
PY
   sha256sum "$published/$1/DuetWebControl-SBC.zip" | cut -d' ' -f1
}

# run <dwc version> <sha256> [dsf version] -> ok|fail; output in $tmp/out
run() {
   if IGconf_dsf_dwc_version=$1 IGconf_dsf_dwc_sha256=$2 IGconf_dsf_version=${3:-3.7.0~rc.1} \
      bash "$script" "$root" > "$tmp/out" 2>&1; then
      echo ok
   else
      echo fail
   fi
}

good=$(publish 'v3.7.0-rc.1%2Bmp.1' 3.7.0-rc.1+mp.1)

# --- a good pin -----------------------------------------------------------

fresh_root
check "good pin passes"               ok "$(run 3.7.0-rc.1+mp.1 "$good")"
check "asked for the tagged asset"    "https://github.com/Meltingplot/DuetWebControl/releases/download/v3.7.0-rc.1%2Bmp.1/DuetWebControl-SBC.zip" \
   "$(cat "$published/last-url")"
check "fork index in place"           "fork index" "$(cat "$dwc/index.html")"
[ -e "$dwc/js/app-packaged.js" ] && r=yes || r=no
check "packaged bundle removed"       no "$r"
check "file mode"                     644 "$(stat -c '%a' "$dwc/js/app-fork.js")"
check "directory mode"                755 "$(stat -c '%a' "$dwc/css")"

# --- refusals, each with the packaged web interface left alone ------------

refused() {
   # $1 label, $2 dwc version, $3 sha256, $4 dsf version
   fresh_root
   check "$1 fails"                   fail "$(run "$2" "$3" "${4:-3.7.0~rc.1}")"
   check "$1 leaves the package"      "packaged index" "$(cat "$dwc/index.html")"
}

refused "checksum mismatch"           3.7.0-rc.1+mp.1 "$(printf '%064d' 0)"
refused "short checksum"              3.7.0-rc.1+mp.1 abc
refused "not published"               3.7.0-rc.1+mp.2 "$good"
refused "no suffix"                   3.7.0-rc.1 "$good"
refused "empty suffix"                3.7.0-rc.1+ "$good"
refused "other generation"            3.7.0-rc.1+mp.1 "$good" 3.7.0~rc.2
refused "other generation, 3.6"       3.6.0+mp.1 "$good"

wrong=$(publish 'v3.7.0-rc.1%2Bmp.3' 3.7.0-rc.1+mp.4)
refused "bundle of another version"   3.7.0-rc.1+mp.3 "$wrong"
noindex=$(publish 'v3.7.0-rc.1%2Bmp.5' 3.7.0-rc.1+mp.5 no-index)
refused "archive without index.html"  3.7.0-rc.1+mp.5 "$noindex"
escape=$(publish 'v3.7.0-rc.1%2Bmp.6' 3.7.0-rc.1+mp.6 escape)
refused "path out of the archive"     3.7.0-rc.1+mp.6 "$escape"
[ -e "$tmp/escape.txt" ] || [ -e "$root/opt/dsf/escape.txt" ] && r=yes || r=no
check "nothing written outside"       no "$r"

rm -rf "$root"; mkdir -p "$root/opt/dsf"
check "no packaged interface fails"   fail "$(run 3.7.0-rc.1+mp.1 "$good")"

# The refusal has to say why, in terms of the rule that was broken.
fresh_root
run 3.7.0-rc.1 "$good" > /dev/null
grep -q "expected 3.7.0-rc.1+<suffix>" "$tmp/out" && r=yes || r=no
check "missing suffix names the rule" yes "$r"
fresh_root
run 3.7.0-rc.1+mp.2 "$good" > /dev/null
grep -q "only ever ships published builds" "$tmp/out" && r=yes || r=no
check "missing release names the rule" yes "$r"

[ "$fail" -eq 0 ] && echo "all tests passed"
exit "$fail"
