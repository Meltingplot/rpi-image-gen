# Shared helpers for the Meltingplot device scripts. POSIX sh, sourced.
#
# The identity of a printer computer lives in three places:
#   /etc/meltingplot/device.conf              baked into the image (user, role)
#   /persistent/common/etc/mp-identity        written at commissioning
#   <printer name file>                       the customer's display name
# Everything below reads those and nothing else.

MP_DEVICE_CONF=/etc/meltingplot/device.conf
MP_IDENTITY_FILE=/persistent/common/etc/mp-identity
MP_HOSTNAME_CACHE=/persistent/common/etc/hostname

# The display name is a DSF config file, shared across A/B slots. It is the
# single source of both the M550 machine name and the Linux hostname, because
# DuetControlServer refuses an M550 name whose letters and digits differ from
# the hostname.
MP_PRINTER_NAME_FILE=/persistent/shared/opt/dsf/sd/sys/meltingplot/printer-name.g

MP_USER=root
MP_PRODUCT=unknown
MP_ROLE=sbc
# shellcheck source=/dev/null
[ -r "$MP_DEVICE_CONF" ] && . "$MP_DEVICE_CONF"

mp_log() {
   echo "${MP_TAG:-meltingplot}: $*" >&2
}

mp_die() {
   mp_log "$*"
   exit 1
}

# Read one key from a simple key=value file. Comments and CRLF line endings
# (the commissioning file is written on a FAT partition, often from Windows)
# are handled. Prints the empty string when the key is absent.
#
# This is how the identity file is read too. It is never sourced: a display
# name contains spaces, so a shell would read PRINTER_NAME=Halle 2 links as an
# assignment followed by a call to the command 2.
mp_conf_get() {
   [ -f "$1" ] || return 0
   sed -n -e 's/\r$//' -e "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$1" \
      | head -n1 \
      | sed -e 's/[[:space:]]*$//'
}

# Turn a display name into a DNS label: lower case, every run of characters
# that is not a letter or digit becomes a single dash, no leading or trailing
# dash, at most 63 characters. Prints nothing if no letter or digit remains.
# Truncation happens before the dashes are trimmed, so a cut that lands on a
# dash cannot leave one at the end, which no DNS label may have.
mp_slug() {
   printf '%s' "$1" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -e 's/[^a-z0-9]\{1,\}/-/g' \
      | cut -c1-63 \
      | sed -e 's/^-*//' -e 's/-*$//'
}

# The name a device carries when nothing has been commissioned yet. Deliberately
# obvious, so an unprovisioned unit stands out in a device list.
mp_fallback_name() {
   _s=$(tr -d '\0' < /proc/device-tree/serial-number 2>/dev/null || true)
   [ -n "$_s" ] || _s=$(sed -n 's/^Serial[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n1)
   [ -n "$_s" ] || _s=unknown
   printf 'meltingplot-unprovisioned-%s-%s' "$(printf '%s' "$_s" | tail -c 7)" "$MP_ROLE"
}

# The name a commissioned device carries unless the customer picked one.
mp_default_name() {
   printf 'meltingplot-%s-%s-%s' "$MP_PRODUCT" "$1" "$MP_ROLE"
}

# A Meltingplot serial number is exactly three digits, as printed on the
# machine and expected by the CHX350 configuration.
mp_valid_serial() {
   case $1 in
      [0-9][0-9][0-9]) return 0 ;;
      *) return 1 ;;
   esac
}

# Extract the machine name from an RRF M550 line.
mp_read_printer_name() {
   [ -f "$1" ] || return 0
   sed -n -e 's/\r$//' -e 's/^[[:space:]]*M550[[:space:]]\{1,\}P"\([^"]*\)".*/\1/p' "$1" \
      | head -n1
}

# DuetControlServer rejects an M550 name longer than 40 characters and one that
# does not reduce to the same letters and digits as the hostname. Keep the
# accepted set narrow so both stay in step.
mp_valid_printer_name() {
   case $1 in
      '') return 1 ;;
      *[!A-Za-z0-9\ -]*) return 1 ;;
   esac
   [ "${#1}" -le 40 ] || return 1
   [ -n "$(mp_slug "$1")" ] || return 1
   return 0
}
