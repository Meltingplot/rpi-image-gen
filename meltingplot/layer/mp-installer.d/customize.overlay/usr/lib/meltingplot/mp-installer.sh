# Helpers of the installer card. POSIX sh, sourced after mp-common.sh.
#
# The card boots a Raspberry Pi 5 from SD and writes the A/B image it carries
# to the NVMe drive. Nobody is at the machine: what the card does is told by
# the LEDs and by meltingplot/installer.log on its FAT partition, which any
# PC can read. Everything that decides something lives here, so the tests can
# run it on the build host with stubs.

# What this card installs, written by the build (postbuild20-installer-payload).
MPI_CONF=${MPI_CONF:-/etc/meltingplot/installer.conf}
# The FAT partition of the card, where the operator edits identity.conf and
# installer.conf and reads installer.log.
MPI_CARD=${MPI_CARD:-/boot/firmware/meltingplot}
# The pristine identity.conf, put back on the card once a device has its copy.
MPI_IDENTITY_TEMPLATE=${MPI_IDENTITY_TEMPLATE:-/usr/share/meltingplot/installer/identity.conf}
MPI_SYS_BLOCK=${MPI_SYS_BLOCK:-/sys/block}
# The green LED shows the card at work, the red one that it stopped.
MPI_LED=${MPI_LED:-/sys/class/leds/ACT}
MPI_LED_STOP=${MPI_LED_STOP:-/sys/class/leds/PWR}
# The same, for a display that shows the card at work (mp-installer-screen):
# busy, steady or stopped.
MPI_PHASE=${MPI_PHASE:-/run/mp-installer/phase}
MPI_BOOTLOADER_TS=${MPI_BOOTLOADER_TS:-/proc/device-tree/chosen/bootloader/build-timestamp}

# Why the installer stopped. The red LED is on, the green one blinks this many
# times, pauses and repeats, so the reason can be told without a screen.
MPI_E_NODRIVE=2    # no NVMe drive, or more than one
MPI_E_NOTEMPTY=3   # the drive holds data and installer.conf does not release it
MPI_E_CONFIG=4     # identity.conf on the card is not usable
MPI_E_NOBOOT=5     # this drive was installed by this card, yet the Pi started from SD again
MPI_E_FAILED=6     # anything else: card, drive or bootloader; see installer.log

mpi_load_conf() {
   [ -r "$MPI_CONF" ] || mp_die "$MPI_CONF is missing; this card was not built as an installer"
   # shellcheck source=/dev/null
   . "$MPI_CONF"
   for _v in MPI_IMAGE MPI_PAYLOAD MPI_SHA256 MPI_RAW_SIZE MPI_RAW_SHA256 MPI_BOOT_ORDER; do
      eval "[ -n \"\${$_v:-}\" ]" || mp_die "$MPI_CONF does not set $_v"
   done
}

mpi_log() {
   mp_log "$*"
   if [ -d "$MPI_CARD" ]; then
      printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$MPI_CARD/installer.log" 2>/dev/null || true
      sync "$MPI_CARD/installer.log" 2>/dev/null || true
   fi
}

# --- the drive ------------------------------------------------------------

# The NVMe namespaces the kernel sees, one per line (nvme0n1). Controller
# paths of a multipath setup (nvme0c0n1) are not disks of their own.
mpi_nvme_disks() {
   for _d in "$MPI_SYS_BLOCK"/nvme*n*; do
      [ -e "$_d" ] || continue
      _n=$(basename "$_d")
      case $_n in
         nvme*c*) continue ;;
      esac
      echo "$_n"
   done
}

# The one NVMe drive to write. Fails when there is none or more than one: a
# Pi 5 has a single PCIe lane, and guessing between two drives is not
# something to do without anyone watching.
mpi_target() {
   _disks=$(mpi_nvme_disks)
   [ -n "$_disks" ] || return 1
   [ "$(printf '%s\n' "$_disks" | wc -l)" -eq 1 ] || return 1
   printf '/dev/%s\n' "$_disks"
}

# Serial number of the drive, as its controller reports it. Tells this drive
# apart from the next one the card is put to.
mpi_drive_serial() {
   _n=$(basename "$1")
   tr -d ' \n' < "$MPI_SYS_BLOCK/$_n/device/serial" 2>/dev/null || true
}

mpi_drive_model() {
   _n=$(basename "$1")
   sed -e 's/[[:space:]]*$//' < "$MPI_SYS_BLOCK/$_n/device/model" 2>/dev/null || true
}

# Whether a drive is empty: no partition, and no partition table or
# filesystem signature that wipefs would recognise. A new drive is all zeros;
# anything else was put there by someone and is not overwritten unasked.
mpi_drive_blank() {
   _n=$(basename "$1")
   for _p in "$MPI_SYS_BLOCK/$_n/$_n"p*; do
      [ -e "$_p" ] && return 1
   done
   # A drive wipefs cannot read is not known to be empty.
   _sig=$(wipefs --no-act --noheadings "$1" 2>/dev/null) || return 1
   [ -z "$_sig" ]
}

# --- the layout on the drive ---------------------------------------------

# The partitions the kernel sees on a drive, one per line: GPT name (or -),
# start and size in bytes. sysfs counts in 512-byte units whatever the drive's
# block size.
mpi_partitions() {
   _n=$(basename "$1")
   for _p in "$MPI_SYS_BLOCK/$_n/$_n"p*; do
      [ -r "$_p/start" ] && [ -r "$_p/size" ] || continue
      _name=$(sed -n 's/^PARTNAME=//p' "$_p/uevent" 2>/dev/null)
      echo "${_name:--} $(($(cat "$_p/start") * 512)) $(($(cat "$_p/size") * 512))"
   done
}

# Which generation of the A/B layout the partitions on stdin (mpi_partitions)
# make, given the name of the partition to keep ($1) and the names of the
# partitions the card never writes ($2, separated by spaces;
# docs/meltingplot-layout.md):
#   gen4     the A/B layout with one of those, the reserve
#   gen3     the A/B layout with the partition to keep (the audit log)
#   gen2     the A/B layout with 4G system slots (since PR #111)
#   gen1     the A/B layout with smaller system slots (1G printer SBC, 2G panel)
#   blank    no partition at all
#   foreign  anything else
mpi_layout_generation() {
   awk -v keep="${1:-}" -v skip="${2:-}" '
      NF == 0 { next }
      { n++; size[$1] = $3 }
      END {
         if (!n) { print "blank"; exit }
         split("bootconfig boot_a boot_b system_a system_b persistent", ab, " ")
         for (i in ab) if (!(ab[i] in size)) { print "foreign"; exit }
         ns = split(skip, sk, " ")
         for (i = 1; i <= ns; i++) if (sk[i] in size) { print "gen4"; exit }
         if (keep != "" && (keep in size)) { print "gen3"; exit }
         # 3 GiB lies between the 2G slots of gen1 and the 4G slots of gen2
         if (size["system_a"] > 3221225472) print "gen2"; else print "gen1"
      }'
}

# Whether the card can leave the partition to keep ($1) alone: on the drive
# (partitions on stdin) it has to lie exactly where the image puts it, start
# $2 and size $3 in bytes. Prints
#   keep   it does; the card writes around it
#   moved  the drive has it somewhere else or at another size
#   none   the drive has no such partition, or there is nothing to keep
mpi_keep_decision() {
   awk -v k="${1:-}" -v s="${2:-}" -v z="${3:-}" '
      NF == 0 { next }
      $1 == k { found = 1; if ($2 == s && $3 == z) ok = 1 }
      END {
         if (k == "" || s == "" || z == "" || !found) print "none"
         else if (ok) print "keep"
         else print "moved"
      }'
}

# The partitions the card never writes, as the build measured them
# (MPI_SKIP: name:start:size, separated by commas), one per line:
# name start size.
mpi_skip_list() {
   printf '%s\n' "${1:-}" | tr ',' '\n' | awk -F: 'NF == 3 { print $1, $2, $3 }'
}

# The first of the partitions to skip ($1, MPI_SKIP) that the drive (partitions
# on stdin, mpi_partitions) has somewhere else or at another size than the
# image: its layout was changed in the field after this card. Nothing when
# all lie where the image puts them, or the drive has none of them.
mpi_skip_moved() {
   _parts=$(cat)
   mpi_skip_list "${1:-}" | while read -r _n _s _z; do
      _d=$(printf '%s\n' "$_parts" | mpi_keep_decision "$_n" "$_s" "$_z")
      if [ "$_d" = moved ]; then echo "$_n"; break; fi
   done
}

# The byte ranges the card leaves on the drive, as start:size separated by
# spaces and in order: the partitions to skip ($1, MPI_SKIP) and the one to
# keep, if it is kept ($2 start, $3 size, both empty otherwise).
mpi_ranges() {
   { mpi_skip_list "${1:-}" | awk '{ print $2 ":" $3 }'
     [ -z "${2:-}" ] || echo "$2:$3"; } | sort -t: -k1,1n | tr '\n' ' '
}

# Write the raw image on stdin to $1 but leave the byte ranges $2
# (mpi_ranges) as the drive has them: the image's own bytes for them are read
# and dropped. In blocks of 4 MiB, to which the build checked the ranges are
# aligned (mp-installer-measure); notrunc so a file stands in for the drive in
# the tests.
mpi_write_skipping() {
   _pos=0
   for _r in ${2:-}; do
      _s=${_r%%:*} _z=${_r#*:}
      dd of="$1" bs=4M iflag=fullblock seek=$((_pos / 4194304)) count=$(((_s - _pos) / 4194304)) \
         conv=fsync,notrunc status=none || return 1
      dd of=/dev/null bs=4M iflag=fullblock count=$((_z / 4194304)) status=none || return 1
      _pos=$((_s + _z))
   done
   dd of="$1" bs=4M iflag=fullblock seek=$((_pos / 4194304)) conv=fsync,notrunc status=none
}

# SHA-256 of the first $2 bytes of $1 without the byte ranges $3
# (mpi_ranges): what a drive written by mpi_write_skipping reads back.
mpi_read_back_skipping() {
   { _pos=0
     for _r in ${3:-}; do
        _s=${_r%%:*} _z=${_r#*:}
        dd if="$1" bs=4M iflag=fullblock skip=$((_pos / 4194304)) count=$(((_s - _pos) / 4194304)) status=none
        _pos=$((_s + _z))
     done
     dd if="$1" bs=4M skip=$((_pos / 4194304)) iflag=count_bytes count=$(($2 - _pos)) status=none
   } | sha256sum | cut -d' ' -f1
}

# Discard the partitions to skip ($2, MPI_SKIP) on the drive $1, so nothing of
# an earlier layout stays readable in the reserve. Best effort: a drive that
# cannot discard keeps what it had there, which nothing reads. Prints what
# could not be discarded.
mpi_discard_skipped() {
   mpi_skip_list "${2:-}" | while read -r _n _s _z; do
      blkdiscard --offset "$_s" --length "$_z" "$1" >/dev/null 2>&1 || echo "$_n"
   done
}

# --- the card -------------------------------------------------------------

# A yes/no switch from a key=value file on the card. Only yes counts.
mpi_card_flag() {
   case $(mp_conf_get "$1" "$2" | tr '[:upper:]' '[:lower:]') in
      yes) return 0 ;;
      *) return 1 ;;
   esac
}

# Whether identity.conf carries anything at all, i.e. someone took a # off.
mpi_identity_set() {
   [ -f "$1" ] || return 1
   sed -e 's/\r$//' "$1" | grep -q '^[[:space:]]*[a-z_][a-z_]*[[:space:]]*='
}

# Check identity.conf the way the first boot will read it, before anything
# is written, so a typo stops the card here rather than leaving a printer
# that comes up unprovisioned. Prints what is wrong.
mpi_identity_problem() {
   [ -f "$1" ] || return 0
   _serial=$(mp_conf_get "$1" printer_serial)
   _name=$(mp_conf_get "$1" printer_name)
   _key=$(mp_conf_get "$1" connect_authkey)
   if [ -n "$_serial" ] && ! mp_valid_serial "$_serial"; then
      echo "printer_serial '$_serial' is not three digits"
      return 0
   fi
   if [ -n "$_name" ] && ! mp_valid_printer_name "$_name"; then
      echo "printer_name '$_name' is not usable: letters, digits, space and -, at most 40 characters"
      return 0
   fi
   case $_key in
      ''|rpuak_*|rpoak_*) ;;
      *) echo "connect_authkey is not an rpuak_ or rpoak_ key"; return 0 ;;
   esac
   if [ -z "$_serial" ] && { [ -n "$_name" ] || [ -n "$_key" ]; }; then
      echo "printer_serial is missing; without it the device is not commissioned"
      return 0
   fi
}

# Replace the value of a key on the card with a note, the way the first boot
# replaces a used auth key. A switch that has done its job must not stay on
# for the next device the card is put into.
mpi_card_spend() {
   _f=$1 _k=$2 _note=$3
   [ -f "$_f" ] || return 0
   sed -e 's/\r$//' \
       -e "s|^\([[:space:]]*$_k[[:space:]]*=\).*|\1$_note|" "$_f" > "$_f.tmp" &&
      mv -f "$_f.tmp" "$_f"
}

# The card remembers the last drive it worked on and how far it got, so a
# start after an interruption picks its own work up instead of refusing a
# drive that is no longer empty, and a Pi that starts from SD again after an
# installation can say why. What the drive held before is kept with it: once
# writing began, the drive no longer shows it.
#   image=<image name>  serial=<drive serial>
#   step=writing|bootloader|done  bootloader=<date, once done>
#   layout=<generation found, mpi_layout_generation>  keep=keep|none
mpi_state_get() {
   mp_conf_get "$MPI_CARD/installer.state" "$1"
}

mpi_state_write() {
   {
      echo "# Written by mp-installer: the last drive this card worked on."
      echo "image=$1"
      echo "serial=$2"
      echo "step=$3"
      [ -z "${4:-}" ] || echo "bootloader=$4"
      [ -z "${5:-}" ] || echo "layout=$5"
      [ -z "${6:-}" ] || echo "keep=$6"
   } > "$MPI_CARD/installer.state.tmp" &&
      mv -f "$MPI_CARD/installer.state.tmp" "$MPI_CARD/installer.state"
   sync "$MPI_CARD/installer.state" 2>/dev/null || true
}

# What to do with the drive, from what the card finds.
#   $1 drive empty y|n  $2 installer.conf releases it y|n
#   $3 drive serial     $4 the image this card installs
# Prints one of:
#   write       an empty drive
#   overwrite   a drive with data, released by installer.conf
#   rewrite     this card began writing this drive and was interrupted
#   bootloader  this card wrote this drive, the bootloader step did not finish
#   noboot      this card installed this drive, yet the Pi started from SD again
#   notempty    a drive with data the card knows nothing about
mpi_decide() {
   if [ "$1" = y ]; then echo write; return 0; fi
   if [ "$2" = y ]; then echo overwrite; return 0; fi
   if [ -n "$3" ] && [ "$(mpi_state_get serial)" = "$3" ] &&
      [ "$(mpi_state_get image)" = "$4" ]; then
      case $(mpi_state_get step) in
         writing) echo rewrite ;;
         bootloader) echo bootloader ;;
         *) echo noboot ;;
      esac
      return 0
   fi
   echo notempty
}

# --- bootloader -----------------------------------------------------------

# The bootloader configuration to apply, from the one the Pi runs with:
# BOOT_ORDER, and PSU_MAX_CURRENT and PCIE_PROBE where this card sets them,
# replace whatever was there, in every section; everything else is kept.
# rpi-eeprom-config --apply replaces the whole configuration, so this is
# what keeps the rest of it. The settings go first, into [all], which a
# configuration starts with either explicitly or implicitly.
#   $1 current configuration  $2 BOOT_ORDER  $3 PSU_MAX_CURRENT or empty
#   $4 PCIE_PROBE y|n
mpi_eeprom_conf() {
   _keys=BOOT_ORDER
   [ -z "$3" ] || _keys="$_keys|PSU_MAX_CURRENT"
   [ "$4" != y ] || _keys="$_keys|PCIE_PROBE"
   _rest=$(sed -e 's/\r$//' "$1" | grep -Ev "^[[:space:]]*($_keys)[[:space:]]*=" || true)
   _first=$(printf '%s\n' "$_rest" | sed -n '/[^[:space:]]/{p;q;}')
   if [ "$_first" = "[all]" ]; then
      echo "[all]"
      _rest=$(printf '%s\n' "$_rest" | sed '0,/^\[all\]$/{//d;}')
   fi
   echo "BOOT_ORDER=$2"
   [ -z "$3" ] || echo "PSU_MAX_CURRENT=$3"
   [ "$4" != y ] || echo "PCIE_PROBE=1"
   [ -z "$_rest" ] || printf '%s\n' "$_rest"
}

# Date of a bootloader image, from its name: pieeprom-2026-05-26.bin.
mpi_eeprom_image_date() {
   basename "$1" | sed -n 's/^pieeprom-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)\.bin$/\1/p'
}

# Build date of the bootloader the Pi started with, empty if unknown.
mpi_bootloader_date() {
   [ -r "$MPI_BOOTLOADER_TS" ] || return 0
   _ts=$(od -An -tu4 --endian=big "$MPI_BOOTLOADER_TS" 2>/dev/null | tr -d ' ')
   [ -n "$_ts" ] || return 0
   date -u -d "@$_ts" +%Y-%m-%d
}

# --- the LEDs -------------------------------------------------------------
# At work the green LED flickers fast and evenly, with no pause in it, so it
# cannot be counted and taken for a reason code (the heartbeat pattern, two
# beats and a pause, looks exactly like code 2); power may be taken away then,
# the next start picks the work up. While the bootloader is written and until
# the restart it stays on: power must stay on now. Stopped, the red LED comes
# on and the green one counts the code.

mpi_led_set() {
   [ -w "$1/trigger" ] || return 0
   case $2 in
      flicker)
         if echo timer > "$1/trigger" 2>/dev/null; then
            echo 100 > "$1/delay_on" 2>/dev/null || true
            echo 100 > "$1/delay_off" 2>/dev/null || true
         else
            echo none > "$1/trigger"; echo 1 > "$1/brightness"
         fi ;;
      on)  echo none > "$1/trigger"; echo 1 > "$1/brightness" ;;
      off) echo none > "$1/trigger"; echo 0 > "$1/brightness" ;;
   esac
}

mpi_phase() {
   mkdir -p "$(dirname "$MPI_PHASE")" 2>/dev/null &&
      echo "$1" > "$MPI_PHASE.tmp" 2>/dev/null &&
      mv -f "$MPI_PHASE.tmp" "$MPI_PHASE" 2>/dev/null || true
}

mpi_led() {
   mpi_phase "$1"
   case $1 in
      busy) mpi_led_set "$MPI_LED_STOP" off; mpi_led_set "$MPI_LED" flicker ;;
      steady) mpi_led_set "$MPI_LED_STOP" off; mpi_led_set "$MPI_LED" on ;;
   esac
}

# Blink a reason code for good. The installer ends here when it fails.
mpi_blink_forever() {
   mpi_phase stopped
   mpi_led_set "$MPI_LED_STOP" on
   mpi_led_set "$MPI_LED" off
   [ -w "$MPI_LED/brightness" ] || exec sleep infinity
   while :; do
      _i=0
      while [ "$_i" -lt "$1" ]; do
         echo 1 > "$MPI_LED/brightness"; sleep 0.3
         echo 0 > "$MPI_LED/brightness"; sleep 0.4
         _i=$((_i + 1))
      done
      sleep 2
   done
}
