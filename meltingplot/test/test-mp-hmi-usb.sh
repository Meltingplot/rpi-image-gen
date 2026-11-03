#!/bin/sh
# Tests for mp-hmi-usb, runnable on the build host: mp-hmi-usb-mount with
# stubs in place of udevadm, mount and umount, mp-hmi-usb-serve for real on a
# directory that stands in for the mounted sticks.
#
# What matters: a stick is mounted read-only with names in UTF-8 and comes
# and goes with its label; the server hands out the G-code files on a stick
# and nothing else, whatever path it is asked for.

set -eu

here=$(dirname "$(readlink -f "$0")")
d="$here/../layer/mp-hmi-usb.d/customize.overlay/usr/lib/meltingplot"
tmp=$(mktemp -d)
server=
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; rm -rf "$tmp"' EXIT

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-46s %s\n' "$1" "$3"
   else
      printf 'FAIL %-46s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}

# --- mp-hmi-usb-mount -------------------------------------------------------

mkdir "$tmp/bin"
# udevadm: the properties of /dev/<name> from props.<name>
cat > "$tmp/bin/udevadm" <<'STUB'
#!/bin/sh
d=$(dirname "$0")/..
for a; do name=${a#--name=/dev/}; done
echo "udevadm $name" >> "$d/calls"
cat "$d/props.$name"
STUB
cat > "$tmp/bin/mount" <<'STUB'
#!/bin/sh
d=$(dirname "$0")/..
echo "mount $*" >> "$d/calls"
[ ! -e "$d/mount-fails" ] || exit 32
STUB
cat > "$tmp/bin/umount" <<'STUB'
#!/bin/sh
echo "umount $*" >> "$(dirname "$0")/../calls"
STUB
cat > "$tmp/bin/mountpoint" <<'STUB'
#!/bin/sh
[ -e "$(dirname "$0")/../mounted" ]
STUB
chmod +x "$tmp/bin/"*

usb=$tmp/usb
run_mount() {
   : > "$tmp/calls"
   rc=0
   PATH="$tmp/bin:$PATH" MP_USB_DIR=$usb TZ=${tz:-CET-1} sh "$d/mp-hmi-usb-mount" "$@" \
      > "$tmp/out" 2>&1 || rc=$?
}
props() {
   printf 'DEVNAME=/dev/%s\nID_FS_TYPE=%s\nID_FS_LABEL=%s\n' "$1" "$2" "$3" > "$tmp/props.$1"
}
opts=ro,nosuid,nodev,noexec,noatime,fmask=0133,dmask=0022

props sda1 vfat INTENSO
run_mount start sda1
check "FAT: exit" 0 "$rc"
check "FAT: read-only, UTF-8, the panel's time" "mount -t vfat -o $opts,utf8,time_offset=60 /dev/sda1 $usb/sda1/fs" \
   "$(grep '^mount' "$tmp/calls")"
check "FAT: label published" INTENSO "$(cat "$usb/sda1/label")"
for tz in UTC0:0 CEST-2 IST-5:30 NST3:30 HST10; do
   rm -rf "$usb/sda1"
   run_mount start sda1
   check "FAT: time offset in $tz" "$(TZ=$tz date +%z)" \
      "$(grep -o 'time_offset=[-0-9]*' "$tmp/calls" | sed 's/time_offset=//' |
         awk '{ m = $1 < 0 ? -$1 : $1; printf "%s%02d%02d", ($1 < 0 ? "-" : "+"), m / 60, m % 60 }')"
done
tz=

# a label is the stick's own: never evaluated
props sdb1 exfat "it's \$(touch $tmp/pwned)"
run_mount start sdb1
check "exFAT: read-only, names in UTF-8" "mount -t exfat -o $opts,iocharset=utf8 /dev/sdb1 $usb/sdb1/fs" \
   "$(grep '^mount' "$tmp/calls")"
check "exFAT: label as written" "it's \$(touch $tmp/pwned)" "$(cat "$usb/sdb1/label")"
check "exFAT: label not run" no "$([ -e "$tmp/pwned" ] && echo yes || echo no)"

props sdc ntfs ""
run_mount start sdc
check "NTFS: through ntfs3" "mount -t ntfs3 -o $opts,iocharset=utf8 /dev/sdc $usb/sdc/fs" \
   "$(grep '^mount' "$tmp/calls")"
check "NTFS: empty label" "" "$(cat "$usb/sdc/label")"

props sdd1 ext4 data
run_mount start sdd1
check "ext4: left alone" "0 0 no" "$rc $(grep -c '^mount' "$tmp/calls") $([ -e "$usb/sdd1" ] && echo yes || echo no)"

props sde1 vfat BROKEN
touch "$tmp/mount-fails"
run_mount start sde1
rm "$tmp/mount-fails"
check "mount fails: exit" 1 "$rc"
check "mount fails: nothing left" no "$([ -e "$usb/sde1" ] && echo yes || echo no)"

touch "$tmp/mounted"
run_mount stop sda1
check "stop: unmounted" "umount -l $usb/sda1/fs" "$(grep '^umount' "$tmp/calls")"
check "stop: gone" no "$([ -e "$usb/sda1" ] && echo yes || echo no)"
rm "$tmp/mounted"
run_mount stop sdb1
check "stop, already unmounted: no umount" 0 "$(grep -c '^umount' "$tmp/calls" || true)"
check "stop, already unmounted: gone" no "$([ -e "$usb/sdb1" ] && echo yes || echo no)"
run_mount stop sdd1
check "stop, never mounted: exit" 0 "$rc"

for bad in ../etc sda/1 Sda1 .sda1 'sda 1' ''; do
   run_mount start "$bad"
   check "no device name: '$bad'" "2 0" "$rc $(grep -c '^udevadm' "$tmp/calls" || true)"
done
run_mount mount sda1
check "unknown action" 2 "$rc"

# --- mp-hmi-usb-serve -------------------------------------------------------

rm -rf "$usb"
# sda1 mounted, sdb1 still mounting (no label yet)
mkdir -p "$usb/sda1/fs/Sub" "$usb/sda1/fs/System Volume Information" "$usb/sdb1/fs" "$tmp/outside"
printf 'INTENSO\n' > "$usb/sda1/label"
printf 'G28\nG1 X10\n' > "$usb/sda1/fs/job.gcode"
printf 'M117 Brücke\n' > "$usb/sda1/fs/Brücke.gcode"
printf 'mac\n' > "$usb/sda1/fs/._job.gcode"
printf 'text\n' > "$usb/sda1/fs/readme.txt"
printf 'G1\n' > "$usb/sda1/fs/Sub/part.GCODE"
printf 'secret\n' > "$tmp/outside/secret.gcode"
ln -s "$tmp/outside/secret.gcode" "$usb/sda1/fs/link.gcode"
ln -s "$tmp/outside" "$usb/sda1/fs/dirlink"
ln -s ../job.gcode "$usb/sda1/fs/Sub/up.gcode"
printf 'G1\n' > "$usb/sdb1/fs/early.gcode"

port=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
MP_USB_DIR=$usb MP_USB_PORT=$port python3 -I "$d/mp-hmi-usb-serve" 2> "$tmp/serve.log" &
server=$!

python3 -I - "$port" "$tmp" <<'PY' || fail=1
import json, sys, time, urllib.error, urllib.parse, urllib.request

port, tmp = sys.argv[1], sys.argv[2]
fail = False

def get(path, query=None):
    url = f"http://127.0.0.1:{port}{path}"
    if query is not None:
        url += "?path=" + urllib.parse.quote(query, safe="")
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers

def check(what, expected, got):
    global fail
    if expected == got:
        print(f"ok   {what:<46} {got}")
    else:
        print(f"FAIL {what:<46} expected={expected!r} got={got!r}")
        fail = True

for _ in range(50):
    try:
        get("/list")
        break
    except OSError:
        time.sleep(0.1)

status, body, _ = get("/list")
check("sticks: only the mounted one", (200, {"sticks": [{"name": "sda1", "label": "INTENSO"}]}),
      (status, json.loads(body)))

status, body, headers = get("/list", "sda1")
check("folder: dirs and G-code, no hidden or links",
      (200, [("Brücke.gcode", "file"), ("job.gcode", "file"), ("Sub", "dir")]),
      (status, [(e["name"], e["type"]) for e in json.loads(body)["entries"]]))
check("folder: not cached", "no-store", headers["Cache-Control"])
job = next(e for e in json.loads(body)["entries"] if e["name"] == "job.gcode")
check("folder: size of a job", 11, job["size"])

status, body, _ = get("/list", "sda1/Sub")
check("subfolder: G-code in capitals, no link",
      (200, ["part.GCODE"]), (status, [e["name"] for e in json.loads(body)["entries"]]))

status, body, headers = get("/file", "sda1/job.gcode")
check("file: content", (200, b"G28\nG1 X10\n"), (status, body))
check("file: length", "11", headers["Content-Length"])
status, body, _ = get("/file", "sda1/Brücke.gcode")
check("file: umlaut in the name", (200, "M117 Brücke\n"), (status, body.decode()))
status, body, _ = get("/file", "sda1/Sub/part.GCODE")
check("file: in a subfolder", 200, status)

for what, path, query in [
        ("not G-code", "/file", "sda1/readme.txt"),
        ("hidden", "/file", "sda1/._job.gcode"),
        ("link out of the stick", "/file", "sda1/link.gcode"),
        ("link to a folder outside", "/file", "sda1/dirlink/secret.gcode"),
        ("link within the stick", "/file", "sda1/Sub/up.gcode"),
        ("dot-dot", "/file", "sda1/Sub/../job.gcode"),
        ("dot-dot out of the sticks", "/file", "../outside/secret.gcode"),
        ("dot", "/file", "sda1/./job.gcode"),
        ("empty part", "/file", "sda1//job.gcode"),
        ("absolute", "/file", "/etc/passwd"),
        ("no path", "/file", ""),
        ("stick still mounting", "/file", "sdb1/early.gcode"),
        ("stick still mounting, listed", "/list", "sdb1"),
        ("no such stick", "/list", "sdz1"),
        ("no such file", "/file", "sda1/none.gcode"),
        ("NUL", "/file", "sda1/job.gcode\0"),
        ("a file as folder", "/list", "sda1/job.gcode"),
        ("a folder as file", "/file", "sda1/Sub"),
        ("other path", "/etc/passwd", None)]:
    status, _, _ = get(path, query)
    check(f"404: {what}", 404, status)

sys.exit(1 if fail else 0)
PY

kill "$server"
wait "$server" 2>/dev/null || true
server=
# the interface asks every few seconds; only refusals go to the journal
check "log: successful requests not logged" 0 "$(grep -c '" 200 ' "$tmp/serve.log" || true)"
check "log: refusals logged" yes "$(grep -q '" 404 ' "$tmp/serve.log" && echo yes || echo no)"

exit $fail
