# Helpers of the installer card. POSIX sh, sourced after mp-common.sh.
#
# The card boots a Raspberry Pi 5 from SD and writes the A/B image it carries
# to the NVMe drive. Nobody is at the machine: what the card did is told by the
# green LED and by meltingplot/installer.log on its FAT partition, which any
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
MPI_LED=${MPI_LED:-/sys/class/leds/ACT}
MPI_BOOTLOADER_TS=${MPI_BOOTLOADER_TS:-/proc/device-tree/chosen/bootloader/build-timestamp}

# Why the installer stopped. The green LED blinks this many times, pauses,
# and repeats, so the reason can be told without a screen.
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

# The card remembers the last drive it installed, so a Pi that starts from SD
# again after an installation can say why instead of refusing a full drive.
#   image=<image name>  serial=<drive serial>  bootloader=pending|<date>
mpi_state_get() {
   mp_conf_get "$MPI_CARD/installer.state" "$1"
}

mpi_state_write() {
   {
      echo "# Written by mp-installer: the last drive this card installed."
      echo "image=$1"
      echo "serial=$2"
      echo "bootloader=$3"
   } > "$MPI_CARD/installer.state.tmp" &&
      mv -f "$MPI_CARD/installer.state.tmp" "$MPI_CARD/installer.state"
   sync "$MPI_CARD/installer.state" 2>/dev/null || true
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

# --- the LED --------------------------------------------------------------

mpi_led() {
   [ -w "$MPI_LED/trigger" ] || return 0
   case $1 in
      busy) echo heartbeat > "$MPI_LED/trigger" 2>/dev/null || echo timer > "$MPI_LED/trigger" 2>/dev/null || true ;;
      on)   echo none > "$MPI_LED/trigger"; echo 1 > "$MPI_LED/brightness" ;;
      off)  echo none > "$MPI_LED/trigger"; echo 0 > "$MPI_LED/brightness" ;;
   esac
}

# Blink a reason code for good. The installer ends here when it fails.
mpi_blink_forever() {
   mpi_led off
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
