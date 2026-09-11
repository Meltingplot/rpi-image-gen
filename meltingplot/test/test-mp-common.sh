#!/bin/sh
# Tests for the device helper functions, runnable on the build host.
#
# These carry the logic that is hard to see by reading: turning a printer name
# into a hostname, and parsing files written on a FAT partition by a Windows
# machine. The last test is the one that matters most - DuetControlServer
# rejects an M550 machine name whose letters and digits differ from the Linux
# hostname, so the two derivations have to agree by construction.

set -eu

here=$(dirname "$(readlink -f "$0")")
MP_DEVICE_CONF=/nonexistent
. "$here/../layer/mp-identity.d/customize.overlay/usr/lib/meltingplot/mp-common.sh"
MP_PRODUCT=chx-350
MP_ROLE=sbc

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-42s %s\n' "$1" "$3"
   else
      printf 'FAIL %-42s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}

check "slug plain"        "halle-2-links"                "$(mp_slug 'Halle 2 links')"
check "slug punctuation"  "werk-1-halle-2"               "$(mp_slug 'Werk 1 / Halle 2!')"
check "slug trims dashes" "abc"                          "$(mp_slug '  --abc-- ')"
check "slug no letters"   ""                             "$(mp_slug '!!!')"

# A DNS label is at most 63 characters and may not end in a dash, so the cut
# must not be able to leave one behind.
long=$(mp_slug "$(printf 'ab %.0s' $(seq 30))")
[ "${#long}" -le 63 ] && r=yes || r=no
check "slug fits a DNS label" yes "$r"
case $long in *-) r=no ;; *) r=yes ;; esac
check "slug does not end in a dash" yes "$r"
check "default name"      "meltingplot-chx-350-0042-sbc" "$(mp_default_name 0042)"
check "default is a slug" "meltingplot-chx-350-0042-sbc" "$(mp_slug "$(mp_default_name 0042)")"

# A commissioning file as a Windows machine writes it: CRLF, comments, spacing.
printf 'printer_serial = 0042\r\n#printer_name=ignored\r\nprinter_name = Halle 2 links  \r\nconnect_authkey=rpoak_secret\r\n' \
   > "$tmp/id.conf"
check "conf serial"       "0042"          "$(mp_conf_get "$tmp/id.conf" printer_serial)"
check "conf name"         "Halle 2 links" "$(mp_conf_get "$tmp/id.conf" printer_name)"
check "conf commented out is not read" "rpoak_secret" "$(mp_conf_get "$tmp/id.conf" connect_authkey)"
check "conf absent key"   ""              "$(mp_conf_get "$tmp/id.conf" force)"
check "conf missing file" ""              "$(mp_conf_get "$tmp/nope" printer_serial)"

# The identity file, written by mp-identity and read back by mp-hostname and
# mp-dsf-seed. It looks like shell but must never be sourced: a display name
# contains spaces, and a shell reads the line below as an assignment followed
# by a call to the command "2".
cat > "$tmp/mp-identity" <<'EOF'
# Written by mp-identity at commissioning.
PRINTER_SERIAL=0042
PRINTER_NAME=Halle 2 links
ROLE=sbc
COMMISSIONED=2026-09-10T20:00:00Z
EOF
check "identity name survives spaces" "Halle 2 links" "$(mp_conf_get "$tmp/mp-identity" PRINTER_NAME)"
check "identity serial"   "0042" "$(mp_conf_get "$tmp/mp-identity" PRINTER_SERIAL)"
check "identity role"     "sbc"  "$(mp_conf_get "$tmp/mp-identity" ROLE)"
sh -c 'set -eu; . "$1"' sh "$tmp/mp-identity" 2>/dev/null && r=yes || r=no
check "identity is not shell" no "$r"

printf '; comment\r\nM550 P"Halle 2 links"   ; name\r\n' > "$tmp/pn.g"
check "M550 name"         "Halle 2 links" "$(mp_read_printer_name "$tmp/pn.g")"
check "M550 missing file" ""              "$(mp_read_printer_name "$tmp/nope")"

mp_valid_printer_name "Halle 2 links" && r=yes || r=no
check "valid: normal" yes "$r"
mp_valid_printer_name "" && r=yes || r=no
check "valid: empty" no "$r"
mp_valid_printer_name 'bad"quote' && r=yes || r=no
check "valid: quote would break M550" no "$r"
mp_valid_printer_name "$(printf 'a%.0s' $(seq 41))" && r=yes || r=no
check "valid: over the 40 char DSF limit" no "$r"
mp_valid_printer_name "$(printf 'a%.0s' $(seq 40))" && r=yes || r=no
check "valid: at the 40 char DSF limit" yes "$r"
mp_valid_printer_name '!!!' && r=yes || r=no
check "valid: nothing a hostname can use" no "$r"

# What DuetControlServer compares: letters and digits of the machine name
# against those of the hostname, ignoring case.
for name in 'Halle 2 links' 'Werk 1 / Halle 2!' 'CHX350-Nr7' 'meltingplot-chx-350-0042-sbc'; do
   host=$(mp_slug "$name")
   a=$(printf '%s' "$name" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
   b=$(printf '%s' "$host" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')
   check "M550 '$name' agrees with hostname" "$a" "$b"
done

[ "$fail" -eq 0 ] && echo "all tests passed"
exit "$fail"
