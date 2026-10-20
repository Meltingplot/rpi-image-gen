#!/bin/sh
# Tests for the installer card's helpers, runnable on the build host with a
# fake /sys/block and a stub wipefs.
#
# What matters here is what the card decides on its own: which drive it may
# write, whether that drive counts as empty, whether the commissioning file
# is good enough to hand on, and the bootloader configuration it applies,
# which replaces the whole configuration on the Pi.

set -eu

here=$(dirname "$(readlink -f "$0")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

MP_DEVICE_CONF=/nonexistent
. "$here/../layer/mp-identity.d/customize.overlay/usr/lib/meltingplot/mp-common.sh"

MPI_CARD="$tmp/card"
MPI_SYS_BLOCK="$tmp/sys/block"
MPI_LED="$tmp/led/ACT"
MPI_LED_STOP="$tmp/led/PWR"
MPI_PHASE="$tmp/run/phase"
MPI_BOOTLOADER_TS="$tmp/build-timestamp"
. "$here/../layer/mp-installer.d/customize.overlay/usr/lib/meltingplot/mp-installer.sh"
mkdir -p "$MPI_CARD" "$MPI_SYS_BLOCK"

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %-46s %s\n' "$1" "$3"
   else
      printf 'FAIL %-46s expected=%s got=%s\n' "$1" "$2" "$3"
      fail=1
   fi
}
yesno() { if "$@"; then echo yes; else echo no; fi; }

# --- which drive ------------------------------------------------------------

check "no drive"                      ""             "$(mpi_target || true)"
mkdir -p "$MPI_SYS_BLOCK/mmcblk0" "$MPI_SYS_BLOCK/nvme0n1/device" "$MPI_SYS_BLOCK/nvme0c0n1"
check "the one drive"                 "/dev/nvme0n1" "$(mpi_target)"
check "controller path not a disk"    "nvme0n1"      "$(mpi_nvme_disks | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$MPI_SYS_BLOCK/nvme1n1"
check "two drives refused"            ""             "$(mpi_target || true)"
rmdir "$MPI_SYS_BLOCK/nvme1n1"

printf 'S6EUNX0T123456      \n' > "$MPI_SYS_BLOCK/nvme0n1/device/serial"
printf 'Samsung SSD 980 1TB          \n' > "$MPI_SYS_BLOCK/nvme0n1/device/model"
check "serial without padding"        "S6EUNX0T123456"      "$(mpi_drive_serial /dev/nvme0n1)"
check "model without padding"         "Samsung SSD 980 1TB" "$(mpi_drive_model /dev/nvme0n1)"

# --- whether it is empty ------------------------------------------------------
# The stub prints what stub.out holds and exits with stub.rc, as wipefs
# would for the signatures it found.

mkdir -p "$tmp/bin"
cat > "$tmp/bin/wipefs" <<'EOF'
#!/bin/sh
cat "$(dirname "$0")/stub.out"
exit "$(cat "$(dirname "$0")/stub.rc")"
EOF
chmod +x "$tmp/bin/wipefs"
PATH="$tmp/bin:$PATH"
: > "$tmp/bin/stub.out"; echo 0 > "$tmp/bin/stub.rc"

check "new drive is empty"            yes "$(yesno mpi_drive_blank /dev/nvme0n1)"
echo 'nvme0n1 0x200 gpt 45 46 49 20 50 41 52 54' > "$tmp/bin/stub.out"
check "partition table is not empty"  no  "$(yesno mpi_drive_blank /dev/nvme0n1)"
: > "$tmp/bin/stub.out"; echo 1 > "$tmp/bin/stub.rc"
check "unreadable drive is not empty" no  "$(yesno mpi_drive_blank /dev/nvme0n1)"
echo 0 > "$tmp/bin/stub.rc"
mkdir "$MPI_SYS_BLOCK/nvme0n1/nvme0n1p1"
check "a partition is not empty"      no  "$(yesno mpi_drive_blank /dev/nvme0n1)"
rmdir "$MPI_SYS_BLOCK/nvme0n1/nvme0n1p1"

# --- installer.conf -------------------------------------------------------------

conf="$here/../layer/mp-installer.d/customize.overlay/boot/firmware/meltingplot/installer.conf"
check "delivered: overwrite off"      no  "$(yesno mpi_card_flag "$conf" overwrite_nvme)"
printf 'overwrite_nvme = YES\r\n' > "$MPI_CARD/installer.conf"
check "overwrite on (CRLF, case)"     yes "$(yesno mpi_card_flag "$MPI_CARD/installer.conf" overwrite_nvme)"
printf 'overwrite_nvme=y\n' > "$MPI_CARD/installer.conf"
check "only yes counts"               no  "$(yesno mpi_card_flag "$MPI_CARD/installer.conf" overwrite_nvme)"

cp "$conf" "$MPI_CARD/installer.conf"
sed -i 's/^#overwrite_nvme=yes/overwrite_nvme=yes/' "$MPI_CARD/installer.conf"
comments=$(grep -c '^#' "$MPI_CARD/installer.conf")
mpi_card_spend "$MPI_CARD/installer.conf" overwrite_nvme "used 2026-10-19"
check "spent switch is off"           no  "$(yesno mpi_card_flag "$MPI_CARD/installer.conf" overwrite_nvme)"
check "spent switch says when"        "used 2026-10-19" "$(mp_conf_get "$MPI_CARD/installer.conf" overwrite_nvme)"
check "spending keeps the comments"   "$comments" "$(grep -c '^#' "$MPI_CARD/installer.conf")"

# --- identity.conf --------------------------------------------------------------

template="$here/../layer/mp-identity.d/customize.overlay/bootfs/meltingplot/identity.conf"
id="$MPI_CARD/identity.conf"
check "delivered identity is blank"   no  "$(yesno mpi_identity_set "$template")"
check "delivered identity is fine"    ""  "$(mpi_identity_problem "$template")"
check "no identity is fine"           ""  "$(mpi_identity_problem "$tmp/none")"

printf 'printer_serial=042\r\nprinter_name=Halle 2 links\r\nconnect_authkey=rpoak_abc\r\n' > "$id"
check "filled identity is set"        yes "$(yesno mpi_identity_set "$id")"
check "filled identity is fine"       ""  "$(mpi_identity_problem "$id")"

printf 'printer_serial=42\n' > "$id"
check "short serial"                  "printer_serial '42' is not three digits" "$(mpi_identity_problem "$id")"
printf 'printer_serial=042\nprinter_name=Halle/2\n' > "$id"
case $(mpi_identity_problem "$id") in "printer_name 'Halle/2' is not usable"*) r=refused ;; *) r=accepted ;; esac
check "name with a slash"             refused "$r"
printf 'printer_serial=042\nconnect_authkey=abc\n' > "$id"
check "key of another kind"           "connect_authkey is not an rpuak_ or rpoak_ key" "$(mpi_identity_problem "$id")"
printf 'connect_authkey=rpoak_abc\n' > "$id"
check "key without serial"            "printer_serial is missing; without it the device is not commissioned" "$(mpi_identity_problem "$id")"
printf '  # printer_serial=042\n' > "$id"
check "indented comment is blank"     no  "$(yesno mpi_identity_set "$id")"

# --- state of the card ----------------------------------------------------------

check "no state"                      ""  "$(mpi_state_get serial)"
mpi_state_write mp-duet-pi5-1.0.0 S6EUNX0T123456 done 2026-09-25
check "state image"                   mp-duet-pi5-1.0.0 "$(mpi_state_get image)"
check "state serial"                  S6EUNX0T123456    "$(mpi_state_get serial)"
check "state step"                    done              "$(mpi_state_get step)"
check "state bootloader"              2026-09-25        "$(mpi_state_get bootloader)"
mpi_state_write mp-duet-pi5-1.0.0 S6EUNX0T123456 writing
check "no bootloader before done"     ""                "$(mpi_state_get bootloader)"

# --- what to do with the drive ----------------------------------------------------
# An interrupted card must pick its own drive up again without the release
# switch, and must never take a drive it does not know for its own.

img=mp-duet-pi5-1.0.0 sn=S6EUNX0T123456
rm -f "$MPI_CARD/installer.state"
check "empty drive"                   write      "$(mpi_decide y n "$sn" $img)"
check "empty drive, released anyway"  write      "$(mpi_decide y y "$sn" $img)"
check "foreign drive"                 notempty   "$(mpi_decide n n "$sn" $img)"
check "foreign drive, released"       overwrite  "$(mpi_decide n y "$sn" $img)"
mpi_state_write $img "$sn" writing
check "own drive, write interrupted"  rewrite    "$(mpi_decide n n "$sn" $img)"
check "released beats own state"      overwrite  "$(mpi_decide n y "$sn" $img)"
check "other drive, same card"        notempty   "$(mpi_decide n n OTHER123 $img)"
check "unknown serial never own"      notempty   "$(mpi_decide n n "" $img)"
check "other image on the card"       notempty   "$(mpi_decide n n "$sn" mp-duet-pi5-1.0.1)"
mpi_state_write $img "$sn" bootloader
check "own drive, bootloader pending" bootloader "$(mpi_decide n n "$sn" $img)"
mpi_state_write $img "$sn" done 2026-09-25
check "own drive, installed"          noboot     "$(mpi_decide n n "$sn" $img)"

# --- LEDs -------------------------------------------------------------------------
# Fake sysfs: the trigger and brightness files of both LEDs.

mkdir -p "$MPI_LED" "$MPI_LED_STOP"
for f in trigger brightness delay_on delay_off; do : > "$MPI_LED/$f"; : > "$MPI_LED_STOP/$f"; done
mpi_led busy
check "busy: green flickers evenly"   "timer 100 100" "$(cat "$MPI_LED/trigger" "$MPI_LED/delay_on" "$MPI_LED/delay_off" | tr '\n' ' ' | sed 's/ $//')"
check "busy: red off"                 "none 0"        "$(cat "$MPI_LED_STOP/trigger" "$MPI_LED_STOP/brightness" | tr '\n' ' ' | sed 's/ $//')"
check "busy: screen told"             busy            "$(cat "$MPI_PHASE")"
mpi_led steady
check "steady: screen told"           steady          "$(cat "$MPI_PHASE")"
check "steady: green on"                "none 1"        "$(cat "$MPI_LED/trigger" "$MPI_LED/brightness" | tr '\n' ' ' | sed 's/ $//')"

# --- bootloader configuration -----------------------------------------------------

cat > "$tmp/current.conf" <<'EOF'
[all]
BOOT_UART=1
BOOT_ORDER=0xf461
NET_INSTALL_AT_POWER_ON=1
POWER_OFF_ON_HALT=0
EOF
mpi_eeprom_conf "$tmp/current.conf" 0xf416 "" n > "$tmp/new.conf"
check "boot order replaced" "[all]|BOOT_ORDER=0xf416|BOOT_UART=1|NET_INSTALL_AT_POWER_ON=1|POWER_OFF_ON_HALT=0" \
   "$(tr '\n' '|' < "$tmp/new.conf" | sed 's/|$//')"

mpi_eeprom_conf "$tmp/current.conf" 0xf416 5000 y > "$tmp/new.conf"
check "with supply and probe" "[all]|BOOT_ORDER=0xf416|PSU_MAX_CURRENT=5000|PCIE_PROBE=1|BOOT_UART=1|NET_INSTALL_AT_POWER_ON=1|POWER_OFF_ON_HALT=0" \
   "$(tr '\n' '|' < "$tmp/new.conf" | sed 's/|$//')"

# Applying twice changes nothing, which is how the card tells that the
# bootloader is already set up.
mpi_eeprom_conf "$tmp/new.conf" 0xf416 5000 y > "$tmp/again.conf"
check "applying twice is stable"      yes "$(yesno cmp -s "$tmp/new.conf" "$tmp/again.conf")"

printf 'BOOT_UART=1\r\nPSU_MAX_CURRENT=3000\r\n[gpio8=0]\r\nBOOT_ORDER=0x1\r\n' > "$tmp/current.conf"
mpi_eeprom_conf "$tmp/current.conf" 0xf416 5000 n > "$tmp/new.conf"
check "no [all], sections, CRLF" "BOOT_ORDER=0xf416|PSU_MAX_CURRENT=5000|BOOT_UART=1|[gpio8=0]" \
   "$(tr '\n' '|' < "$tmp/new.conf" | sed 's/|$//')"

printf '[all]\nPSU_MAX_CURRENT=3000\n' > "$tmp/current.conf"
check "supply left alone when unset" "[all]|BOOT_ORDER=0xf416|PSU_MAX_CURRENT=3000" \
   "$(mpi_eeprom_conf "$tmp/current.conf" 0xf416 "" n | tr '\n' '|' | sed 's/|$//')"

check "image date"        2026-05-26 "$(mpi_eeprom_image_date /usr/lib/firmware/raspberrypi/bootloader-2712/default/pieeprom-2026-05-26.bin)"
check "not an image"      ""         "$(mpi_eeprom_image_date /tmp/pieeprom.upd)"

# 2026-05-26 12:00:00 UTC, as the device tree holds it: 32 bits, big endian.
printf '\152\025\213\100' > "$MPI_BOOTLOADER_TS"
check "running bootloader date" 2026-05-26 "$(mpi_bootloader_date)"
rm -f "$MPI_BOOTLOADER_TS"
check "unknown bootloader date" ""         "$(mpi_bootloader_date)"

# --- test pictures -----------------------------------------------------------------
# The framebuffer of the panel's KMS driver takes RGB565 or XRGB8888, little
# endian. A wrong encoding shows the wrong colour, which is what the pictures
# are there to check for.

screen="$here/../layer/mp-installer-screen.d/customize.overlay/usr/lib/meltingplot/mp-installer-screen"
pixels=$(python3 -I -B - "$screen" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("screen", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("screen", loader))
loader.exec_module(m)
out = []
for bpp in (16, 32):
    out += [m.picture(rgb, 2, bpp, 8)[: bpp // 8].hex() for rgb in m.PICTURES]
    out.append(str(len(m.picture((0, 0, 0), 3, bpp, 10))))
print(" ".join(out))
PY
)
check "pictures white red green blue" "ffff 00f8 e007 1f00 30 ffffff00 0000ff00 00ff0000 ff000000 30" "$pixels"

exit $fail
