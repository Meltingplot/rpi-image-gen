#!/bin/sh
# Point the CI runner's Ubuntu packages at a list of mirrors instead of one
# host.
#
# The runner installs the build's own tools from Ubuntu: install_deps.sh, and
# python3-cryptography for the helper tests. Its sources name hosts under
# ubuntu.com only: ports.ubuntu.com on the arm64 runners that build the images,
# azure.archive.ubuntu.com and security.ubuntu.com on x64. When the ubuntu.com
# name servers fail, as on 2026-11-11, none of them resolves. apt-get update
# then keeps the old indexes of the runner image without an error, and the
# install fails on every package, 20 s each.
#
# apt's mirror method (apt-transport-mirror(1)) takes a list instead: when a
# file cannot be fetched from one mirror, apt asks the next, lowest priority
# first. The Ubuntu host stays first. The others mirror the whole archive and
# lie outside ubuntu.com, so they keep working when its DNS does not; each was
# checked on 2026-11-11 for the security pocket and the packages of its
# architecture. apt checks every index against the Ubuntu archive key and
# every package against the index, whichever mirror serves them, so a mirror
# can make a fetch fail but cannot change what is installed.
#
# A mirror that does not answer now moves to the end of the list. apt would
# otherwise try it first for every single file and wait for the resolver each
# time. It stays in the list, so a mirror that only failed the probe is still
# tried after all others.
#
# Run as root before the first apt-get update. MP_APT_DIR, MP_APT_ARCH,
# MP_APT_CODENAME and MP_APT_PROBE let the tests run it on a copy.

set -eu

apt_dir=${MP_APT_DIR:-/etc/apt}
arch=${MP_APT_ARCH:-$(dpkg --print-architecture)}
codename=${MP_APT_CODENAME:-$(. /etc/os-release && echo "$VERSION_CODENAME")}
probe=${MP_APT_PROBE:-probe}
list=$apt_dir/mp-ubuntu-mirrors.list

# One request for the release file, with a hard limit that includes the name
# lookup.
probe() {
   curl -fsS -m 10 -o /dev/null "${1}dists/$codename/InRelease"
}

# The university mirrors of Erlangen (FAU) and Aachen come right after Ubuntu's
# own hosts. Aachen mirrors the amd64 archive only, not ubuntu-ports, so it
# cannot serve the arm64 runners that build the images.
case $arch in
   arm64)
      mirrors="http://ports.ubuntu.com/ubuntu-ports/
https://ftp.fau.de/ubuntu-ports/
https://mirrors.dotsrc.org/ubuntu-ports/
https://mirrors.ocf.berkeley.edu/ubuntu-ports/" ;;
   amd64)
      mirrors="http://azure.archive.ubuntu.com/ubuntu/
http://archive.ubuntu.com/ubuntu/
https://ftp.halifax.rwth-aachen.de/ubuntu/
https://ftp.fau.de/ubuntu/
https://mirrors.edge.kernel.org/ubuntu/
https://mirror.csclub.uwaterloo.ca/ubuntu/
https://mirrors.dotsrc.org/ubuntu/" ;;
   *)
      echo "apt-mirrors: no Ubuntu mirrors known for $arch" >&2
      exit 1 ;;
esac

# --- the mirror list ---------------------------------------------------------

up= down=
for m in $mirrors; do
   if "$probe" "$m" 2>/dev/null; then
      up="$up $m"
   else
      echo "apt-mirrors: $m does not answer, trying it last" >&2
      down="$down $m"
   fi
done
[ -n "$up" ] || echo "::warning::apt-mirrors: no Ubuntu mirror answers"

n=0
{
   echo "# Written by meltingplot/ci/apt-mirrors.sh: answering mirrors first."
   for m in $up $down; do
      n=$((n + 1))
      printf '%s\tpriority:%d\n' "$m" "$n"
   done
} > "$list"

# --- the sources ---------------------------------------------------------------
# Only the Ubuntu archive itself, not ESM, PPAs or anything else the runner
# carries: those are not on the mirrors. On x64 the runner image already uses
# a mirror list of its own, with ubuntu.com hosts only; that one is replaced.

ubuntu='https?://([a-z0-9-]+\.)?(archive|ports|security)\.ubuntu\.com/[^[:space:]]*|mirror\+file:/etc/apt/apt-mirrors\.txt'
ours="mirror+file:$list"
ours_re=$(printf '%s' "$ours" | sed 's/[.+]/\\&/g')

changed=
for f in "$apt_dir/sources.list" "$apt_dir"/sources.list.d/*.list \
         "$apt_dir"/sources.list.d/*.sources; do
   [ -f "$f" ] || continue
   case $f in
      *.sources) grep -Eq "^URIs:.*($ubuntu)" "$f" || continue
                 sed -E -i -e "/^URIs:/s#$ubuntu#$ours#g" "$f" ;;
      *)         grep -Eq "^deb(-src)?[[:space:]].*($ubuntu)" "$f" || continue
                 sed -E -i -e "/^deb(-src)?[[:space:]]/s#$ubuntu#$ours#g" "$f" ;;
   esac
   # Two Ubuntu hosts in one line, as archive and security, become one entry.
   sed -E -i -e "s#($ours_re)([[:space:]]+$ours_re)+#\\1#g" "$f"
   changed="$changed $f"
done
if [ -z "$changed" ]; then
   echo "::warning::apt-mirrors: no Ubuntu source found below $apt_dir, nothing changed"
fi

# --- apt itself ----------------------------------------------------------------
# A mirror that accepts the connection and then stalls is given up after 30 s
# instead of apt's 120 s, and each file is tried three times before apt
# reports it, spread over the mirrors of the list.

cat > "$apt_dir/apt.conf.d/80mp-ci-mirrors" <<'EOF'
// Written by meltingplot/ci/apt-mirrors.sh.
Acquire::Retries "3";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
EOF

echo "apt-mirrors: $arch $codename, sources:${changed:- none}"
cat "$list"
