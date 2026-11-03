#!/bin/sh
# Tests for mp-hmi-usb-guard, runnable on the build host on a directory that
# stands in for /sys/bus/usb, with a stub in place of logger.
#
# What matters: only the camera on its port and a plain USB stick get a
# driver; every interface of an allowed device is authorized before any is
# probed; everything else stays without a driver, loses one it had, and is
# logged.

set -eu

here=$(dirname "$(readlink -f "$0")")
layer="$here/../layer/mp-hmi-usb-guard.d/customize.overlay"
guard="$layer/usr/lib/meltingplot/mp-hmi-usb-guard"
tmp=$(mktemp -d)
reader=
trap '[ -z "$reader" ] || kill "$reader" 2>/dev/null; rm -rf "$tmp"' EXIT

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-50s %s\n' "$1" "$3"
   else
      printf 'FAIL %-50s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}

mkdir "$tmp/bin"
cat > "$tmp/bin/logger" <<'STUB'
#!/bin/sh
shift 2
echo "$*" >> "$(dirname "$0")/../log"
STUB
chmod +x "$tmp/bin/logger"

sys=$tmp/sys
devices=$sys/bus/usb/devices
mkdir -p "$devices"

# drivers_probe: a FIFO whose reader notes each probe with the authorized
# flags of all interfaces of that device at that moment. It keeps the FIFO
# open while a writer has it, or a second probe right after the first is lost.
mkfifo "$sys/bus/usb/drivers_probe"
(
   while :; do
      while read -r name; do
         printf '%s %s\n' "$name" "$(cat "$devices/${name%%:*}":*/authorized | tr -d '\n')" >> "$tmp/probes"
      done < "$sys/bus/usb/drivers_probe"
   done
) &
reader=$!

# device <name> <manufacturer> <product> <interfaces>, as the kernel pads it
device() {
   mkdir -p "$devices/$1"
   printf '%s\n' "$2" > "$devices/$1/manufacturer"
   printf '%s\n' "$3" > "$devices/$1/product"
   printf '%2d\n' "$4" > "$devices/$1/bNumInterfaces"
   printf '1d6b\n' > "$devices/$1/idVendor"
   printf '0104\n' > "$devices/$1/idProduct"
}
# interface <name> <class> <subclass> <protocol> <authorized>
interface() {
   mkdir -p "$devices/$1"
   printf '%s\n' "$2" > "$devices/$1/bInterfaceClass"
   printf '%s\n' "$3" > "$devices/$1/bInterfaceSubClass"
   printf '%s\n' "$4" > "$devices/$1/bInterfaceProtocol"
   printf '%s\n' "$5" > "$devices/$1/authorized"
}
authorized() {
   for i in "$devices/$1":*; do cat "$i/authorized"; done | tr -d '\n'
}
run() {
   : > "$tmp/probes"
   : > "$tmp/log"
   rc=0
   PATH="$tmp/bin:$PATH" MP_SYSFS=$sys MP_USB_GUARD_CONF=$tmp/usb-guard.conf \
      timeout 10 sh "$guard" "$1" > "$tmp/out" 2>&1 || rc=$?
   # let the reader write the last probe
   sleep 0.2
}
probes() {
   tr '\n' ',' < "$tmp/probes" | sed 's/,$//'
}
logged() {
   [ -s "$tmp/log" ] && echo yes || echo no
}

# The camera on its port: CDC NCM, control and data interface
device 1-1 meltingplot "Pi Cam" 2
interface 1-1:1.0 02 0d 00 0
interface 1-1:1.1 0a 00 01 0
run 1-1:1.0
check "camera: exit" 0 "$rc"
check "camera: both interfaces authorized" 11 "$(authorized 1-1)"
check "camera: probed only once both were" "1-1:1.0 11,1-1:1.1 11" "$(probes)"
check "camera: not logged" no "$(logged)"
run 1-1:1.1
check "camera, second interface: probed again" "1-1:1.0 11,1-1:1.1 11" "$(probes)"

# A plain stick, bulk-only, on any port, the camera's included
device 3-1 "SanDisk" "Cruzer" 1
interface 3-1:1.0 08 06 50 0
run 3-1:1.0
check "stick: authorized and probed" "1 3-1:1.0 1" "$(authorized 3-1) $(probes)"
device 2-1 "Samsung" "T7" 1
interface 2-1:1.0 08 06 62 0
run 2-1:1.0
check "UAS stick: authorized and probed" "1 2-1:1.0 1" "$(authorized 2-1) $(probes)"

# What a prepared stick or a service technician might bring
refused() {
   run "$2"
   check "$1: exit" 0 "$rc"
   check "$1: no driver" "$3" "$(authorized "${2%%:*}")"
   check "$1: nothing probed" "" "$(probes)"
   check "$1: logged" yes "$(logged)"
}
device 1-2 "Logitech" "Keyboard" 1
interface 1-2:1.0 03 01 01 0
refused "keyboard" 1-2:1.0 0
device 3-2 "Rubber" "Ducky" 2
interface 3-2:1.0 08 06 50 0
interface 3-2:1.1 03 01 01 0
refused "stick that also is a keyboard (storage)" 3-2:1.0 00
refused "stick that also is a keyboard (keyboard)" 3-2:1.1 00
device 4-1 "Realtek" "USB 10/100/1000 LAN" 2
interface 4-1:1.0 02 06 00 0
interface 4-1:1.1 0a 00 00 0
refused "network adapter" 4-1:1.0 00
device 1-3 meltingplot "Pi Cam" 2
interface 1-3:1.0 02 0d 00 0
interface 1-3:1.1 0a 00 01 0
refused "camera on another port" 1-3:1.0 00
device 1-4 "Genesys" "USB2.0 Hub" 1
interface 1-4:1.0 09 00 00 0
refused "hub" 1-4:1.0 0
device 1-5 "Generic" "CD-ROM" 1
interface 1-5:1.0 08 02 50 0
refused "ATAPI drive" 1-5:1.0 0
device 1-6 "Generic" "Floppy" 1
interface 1-6:1.0 08 04 00 0
refused "UFI floppy" 1-6:1.0 0
grep -q "refused 1-6:1.0: 1d6b:0104 'Generic' 'Floppy', interface 08/04/00, 1 interface(s)" "$tmp/log" &&
   check "log names the device" yes yes || check "log names the device" "refused 1-6:1.0 ..." "$(cat "$tmp/log")"
# The camera with one interface more is not the camera
device 1-7 meltingplot "Pi Cam" 3
interface 1-7:1.0 02 0d 00 0
interface 1-7:1.1 0a 00 01 0
interface 1-7:1.2 03 01 01 0
printf 'MP_USB_CAMERA_PORT=1-7\n' > "$tmp/usb-guard.conf"
refused "camera with a keyboard in it" 1-7:1.0 000
# The configured port counts, not the built-in 1-1
run 1-1:1.0
check "camera on 1-1 with port 1-7 configured" "" "$(probes)"
rm "$tmp/usb-guard.conf"

# Bound before udev ran (no usbcore.authorized_default=0): the driver goes
device 3-3 "Logitech" "Keyboard" 1
interface 3-3:1.0 03 01 01 1
refused "keyboard bound at boot" 3-3:1.0 0

# A root hub's own hub interface stays as it is
mkdir -p "$devices/1-0:1.0"
printf '1\n' > "$devices/1-0:1.0/authorized"
run 1-0:1.0
check "root hub: left alone" "0 1 no" "$rc $(cat "$devices/1-0:1.0/authorized") $(logged)"

for bad in "" usb1 ../1-1:1.0 "1-1" "1-1:1.0/../1-2:1.0"; do
   run "$bad"
   check "no interface: '$bad'" "2 " "$rc $(probes)"
done

# The rules file, where the host's udev can check it
rules="$layer/usr/lib/udev/rules.d/50-mp-hmi-usb-guard.rules"
if udevadm verify --help >/dev/null 2>&1; then
   check "rules: udevadm verify" 0 "$(udevadm verify --no-style "$rules" >/dev/null 2>&1; echo $?)"
else
   echo "skip rules: udevadm verify not available"
fi

exit $fail
