#!/bin/sh
# Tests for mp-hmi-usb-guard, runnable on the build host on a directory that
# stands in for /sys/bus/usb, with stubs in place of tee (the sysfs writes,
# doing what the kernel does with them), modprobe and logger.
#
# What matters: only the camera on its port and a plain USB stick get a
# driver, and only the driver named for them, whatever IDs they carry; the
# driver is loaded first and every interface of an allowed device is
# authorized before the bind; everything else stays without a driver, loses
# one it had, and is logged.

set -eu

here=$(dirname "$(readlink -f "$0")")
layer="$here/../layer/mp-hmi-usb-guard.d/customize.overlay"
guard="$layer/usr/lib/meltingplot/mp-hmi-usb-guard"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-50s %s\n' "$1" "$3"
   else
      printf 'FAIL %-50s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}

sys=$tmp/sys
devices=$sys/bus/usb/devices
drivers=$sys/bus/usb/drivers
mkdir -p "$devices"

mkdir "$tmp/bin"
# tee <attribute>: the kernel's side of a sysfs write, noted in calls
cat > "$tmp/bin/tee" <<'STUB'
#!/bin/sh
read -r v
echo "${1#"$SYS"/bus/usb/} $v" >> "$CALLS"
case $1 in
   */bind)
      drv=${1%/bind}
      drv=${drv##*/}
      devs=$SYS/bus/usb/devices
      i=$devs/$v
      # usb_probe_interface: only an authorized interface; bind: not a bound one
      [ "$(cat "$i/authorized")" = 1 ] && [ ! -e "$i/driver" ] || exit 1
      # uas takes UAS devices only; a stick may refuse any driver
      [ "$drv" != uas ] || [ -e "$i/uas" ] || exit 1
      [ ! -e "$i/refuses-$drv" ] || exit 1
      data=
      if [ "$drv" = cdc_ncm ]; then
         # usb_driver_claim_interface refuses an unauthorized interface
         for s in "$devs/${v%%:*}":*; do
            [ "$(cat "$s/bInterfaceClass")" = 0a ] || continue
            [ "$(cat "$s/authorized")" = 1 ] && [ ! -e "$s/driver" ] || exit 1
            data=$s
         done
      fi
      ln -s "../../drivers/$drv" "$i/driver"
      [ -z "$data" ] || ln -s "../../drivers/$drv" "$data/driver"
      ;;
   */authorized)
      printf '%s\n' "$v" > "$1"
      # deauthorizing unbinds
      [ "$v" = 1 ] || rm -f "${1%/authorized}/driver"
      ;;
   *) printf '%s\n' "$v" > "$1" ;;
esac
STUB
cat > "$tmp/bin/modprobe" <<'STUB'
#!/bin/sh
echo "modprobe $*" >> "$CALLS"
STUB
cat > "$tmp/bin/logger" <<'STUB'
#!/bin/sh
shift 2
echo "$*" >> "$LOG"
STUB
chmod +x "$tmp/bin/"*

drivers_loaded() {
   for drv in cdc_ncm uas usb-storage; do
      mkdir -p "$drivers/$drv"
      : > "$drivers/$drv/bind"
   done
}
drivers_loaded

# device <name> <manufacturer> <product> <interfaces> [<vendor> <product id>]
device() {
   mkdir -p "$devices/$1"
   printf '%s\n' "$2" > "$devices/$1/manufacturer"
   printf '%s\n' "$3" > "$devices/$1/product"
   printf '%2d\n' "$4" > "$devices/$1/bNumInterfaces"
   printf '%s\n' "${5:-1d6b}" > "$devices/$1/idVendor"
   printf '%s\n' "${6:-0104}" > "$devices/$1/idProduct"
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
drivers_of() {
   for i in "$devices/$1":*; do
      l=$(readlink "$i/driver" 2>/dev/null) || l=-
      printf '%s ' "${l##*/}"
   done | sed 's/ $//'
}
run() {
   : > "$tmp/calls"
   : > "$tmp/log"
   rc=0
   PATH="$tmp/bin:$PATH" SYS=$sys CALLS=$tmp/calls LOG=$tmp/log \
      MP_SYSFS=$sys MP_USB_GUARD_CONF=$tmp/usb-guard.conf \
      timeout 10 sh "$guard" "$1" > "$tmp/out" 2>&1 || rc=$?
}
calls() {
   tr '\n' ',' < "$tmp/calls" | sed 's/,$//'
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
check "camera: load, authorize both, then bind" \
   "modprobe -q cdc_ncm,devices/1-1:1.0/authorized 1,devices/1-1:1.1/authorized 1,drivers/cdc_ncm/bind 1-1:1.0" \
   "$(calls)"
check "camera: both with cdc_ncm" "cdc_ncm cdc_ncm" "$(drivers_of 1-1)"
check "camera: not logged" no "$(logged)"
run 1-1:1.1
check "camera, second interface: nothing to write" "modprobe -q cdc_ncm" "$(calls)"
check "camera, second interface: still cdc_ncm" "cdc_ncm cdc_ncm" "$(drivers_of 1-1)"

# Sticks, on any port, the camera's included
device 3-1 "SanDisk" "Cruzer" 1 0781 5567
interface 3-1:1.0 08 06 50 0
run 3-1:1.0
check "stick: uas refuses, usb-storage takes it" \
   "modprobe -q -a uas usb_storage,devices/3-1:1.0/authorized 1,drivers/uas/bind 3-1:1.0,drivers/usb-storage/bind 3-1:1.0" \
   "$(calls)"
check "stick: usb-storage" usb-storage "$(drivers_of 3-1)"
device 2-1 "Samsung" "T7" 1 04e8 4001
interface 2-1:1.0 08 06 50 0
: > "$devices/2-1:1.0/uas"
run 2-1:1.0
check "UAS stick: uas" "uas" "$(drivers_of 2-1)"
device 4-2 "Fake" "Stick" 1
interface 4-2:1.0 08 06 62 0
run 4-2:1.0
check "stick in UAS mode, bulk-only driver" "usb-storage" "$(drivers_of 4-2)"
run 3-1:1.0
check "stick bound already: nothing to write" "modprobe -q -a uas usb_storage" "$(calls)"

# A "stick" with the IDs of an ASIX network adapter gets usb-storage and
# nothing else: no probe that asix could answer
device 3-4 "ASIX" "AX88179" 1 0b95 1790
interface 3-4:1.0 08 06 50 0
run 3-4:1.0
check "stick with network adapter IDs: usb-storage" "usb-storage" "$(drivers_of 3-4)"
check "nothing probed" no "$([ -e "$sys/bus/usb/drivers_probe" ] && echo yes || echo no)"

# A stick both drivers refuse loses its authorization again
device 3-5 "Odd" "Stick" 1
interface 3-5:1.0 08 06 50 0
: > "$devices/3-5:1.0/refuses-usb-storage"
run 3-5:1.0
check "stick no driver takes: deauthorized" "0 -" "$(authorized 3-5) $(drivers_of 3-5)"
check "stick no driver takes: logged" yes "$(logged)"

# What a prepared stick or a service technician might bring
refused() {
   run "$2"
   check "$1: exit" 0 "$rc"
   check "$1: no driver" "$3" "$(authorized "${2%%:*}") $(drivers_of "${2%%:*}")"
   check "$1: no bind" "" "$(calls | tr ',' '\n' | grep -E 'bind|modprobe' || true)"
   check "$1: logged" yes "$(logged)"
}
device 1-2 "Logitech" "Keyboard" 1 046d c31c
interface 1-2:1.0 03 01 01 0
refused "keyboard" 1-2:1.0 "0 -"
device 3-2 "Rubber" "Ducky" 2
interface 3-2:1.0 08 06 50 0
interface 3-2:1.1 03 01 01 0
refused "stick that also is a keyboard (storage)" 3-2:1.0 "00 - -"
refused "stick that also is a keyboard (keyboard)" 3-2:1.1 "00 - -"
device 4-1 "Realtek" "USB 10/100/1000 LAN" 2 0bda 8153
interface 4-1:1.0 02 06 00 0
interface 4-1:1.1 0a 00 00 0
refused "network adapter" 4-1:1.0 "00 - -"
device 1-3 meltingplot "Pi Cam" 2
interface 1-3:1.0 02 0d 00 0
interface 1-3:1.1 0a 00 01 0
refused "camera on another port" 1-3:1.0 "00 - -"
device 1-4 "Genesys" "USB2.0 Hub" 1
interface 1-4:1.0 09 00 00 0
refused "hub" 1-4:1.0 "0 -"
device 1-5 "Generic" "CD-ROM" 1
interface 1-5:1.0 08 02 50 0
refused "ATAPI drive" 1-5:1.0 "0 -"
device 1-6 "Generic" "Floppy" 1
interface 1-6:1.0 08 04 00 0
refused "UFI floppy" 1-6:1.0 "0 -"
grep -q "refused 1-6:1.0: 1d6b:0104 'Generic' 'Floppy', interface 08/04/00, 1 interface(s)" "$tmp/log" &&
   check "log names the device" yes yes || check "log names the device" "refused 1-6:1.0 ..." "$(cat "$tmp/log")"
# The camera with one interface more is not the camera
device 1-7 meltingplot "Pi Cam" 3
interface 1-7:1.0 02 0d 00 0
interface 1-7:1.1 0a 00 01 0
interface 1-7:1.2 03 01 01 0
printf 'MP_USB_CAMERA_PORT=1-7\n' > "$tmp/usb-guard.conf"
refused "camera with a keyboard in it" 1-7:1.0 "000 - - -"
# The configured port counts, not the built-in 1-1: the camera there goes
run 1-1:1.0
check "camera on 1-1 with port 1-7 configured" "00 - -" "$(authorized 1-1) $(drivers_of 1-1)"
rm "$tmp/usb-guard.conf"
run 1-1:1.0
check "camera back on 1-1" "11 cdc_ncm cdc_ncm" "$(authorized 1-1) $(drivers_of 1-1)"

# cdc_ncm refuses the camera, or is not there: the camera loses its
# authorization rather than wait for whatever registers next
device 1-8 meltingplot "Pi Cam" 2
interface 1-8:1.0 02 0d 00 0
interface 1-8:1.1 0a 00 01 0
: > "$devices/1-8:1.0/refuses-cdc_ncm"
printf 'MP_USB_CAMERA_PORT=1-8\n' > "$tmp/usb-guard.conf"
run 1-8:1.0
check "camera cdc_ncm refuses: deauthorized" "00 - -" "$(authorized 1-8) $(drivers_of 1-8)"
check "camera cdc_ncm refuses: logged" yes "$(logged)"
rm "$devices/1-8:1.0/refuses-cdc_ncm"
rm -r "$drivers/cdc_ncm"
run 1-8:1.0
check "camera without cdc_ncm: deauthorized" "00 - -" "$(authorized 1-8) $(drivers_of 1-8)"
rm "$tmp/usb-guard.conf"
drivers_loaded

# A stick some other driver took first is refused, and the driver goes
device 3-6 "ASIX" "AX88179" 1 0b95 1790
interface 3-6:1.0 08 06 50 1
ln -s ../../drivers/ax88179_178a "$devices/3-6:1.0/driver"
run 3-6:1.0
check "stick bound to another driver: deauthorized" "0 -" "$(authorized 3-6) $(drivers_of 3-6)"
check "stick bound to another driver: no bind" "" "$(calls | tr ',' '\n' | grep bind || true)"

# Bound before udev ran (no usbcore.authorized_default=0): the driver goes
device 3-3 "Logitech" "Keyboard" 1 046d c31c
interface 3-3:1.0 03 01 01 1
ln -s ../../drivers/usbhid "$devices/3-3:1.0/driver"
refused "keyboard bound at boot" 3-3:1.0 "0 -"

# A root hub's own hub interface stays as it is
mkdir -p "$devices/1-0:1.0"
printf '1\n' > "$devices/1-0:1.0/authorized"
run 1-0:1.0
check "root hub: left alone" "0 1 no " "$rc $(cat "$devices/1-0:1.0/authorized") $(logged) $(calls)"

for bad in "" usb1 ../1-1:1.0 "1-1" "1-1:1.0/../1-2:1.0"; do
   run "$bad"
   check "no interface: '$bad'" "2 " "$rc $(calls)"
done

# The rules file, where the host's udev can check it
rules="$layer/usr/lib/udev/rules.d/50-mp-hmi-usb-guard.rules"
if udevadm verify --help >/dev/null 2>&1; then
   check "rules: udevadm verify" 0 "$(udevadm verify --no-style "$rules" >/dev/null 2>&1; echo $?)"
else
   echo "skip rules: udevadm verify not available"
fi

exit $fail
