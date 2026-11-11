#!/bin/sh
# Tests for ci/apt-mirrors.sh, on copies of the apt sources of the GitHub
# runners and with a stub in place of the network probe.
#
# What matters: the Ubuntu archive of the runner goes through the mirror list
# and nothing else does, a mirror that does not answer is tried last, and a
# second run changes nothing.

set -eu

here=$(dirname "$(readlink -f "$0")")
script="$here/../ci/apt-mirrors.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The probe fails for every mirror whose URL contains a word of $DOWN.
cat > "$tmp/probe" <<'STUB'
#!/bin/sh
for d in $DOWN; do
   case $1 in *"$d"*) exit 1 ;; esac
done
exit 0
STUB
chmod +x "$tmp/probe"
export MP_APT_PROBE="$tmp/probe" MP_APT_CODENAME=noble DOWN=

fail=0
check() {
   if [ "$2" = "$3" ]; then
      printf 'ok   %s\n' "$1"
   else
      printf 'FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"
      fail=1
   fi
}

# A fresh copy of a runner's /etc/apt for architecture $1.
setup() {
   rm -rf "$tmp/apt"
   mkdir -p "$tmp/apt/sources.list.d" "$tmp/apt/apt.conf.d"
   export MP_APT_DIR="$tmp/apt" MP_APT_ARCH="$1"
}
run() { sh "$script" > "$tmp/out" 2>&1; }
uris() { sed -n 's/^URIs: //p' "$1" | tr '\n' ' ' | sed 's/ $//'; }
mirrors() { grep -v '^#' "$MP_APT_DIR/mp-ubuntu-mirrors.list" | cut -f1 | sed 's#^https\?://##; s#/.*##' | tr '\n' ' ' | sed 's/ $//'; }
priorities() { grep -v '^#' "$MP_APT_DIR/mp-ubuntu-mirrors.list" | cut -f2 | tr '\n' ' ' | sed 's/ $//'; }

ours="mirror+file:$tmp/apt/mp-ubuntu-mirrors.list"

# --- arm64, as ubuntu-24.04-arm ---------------------------------------------

setup arm64
cat > "$tmp/apt/sources.list.d/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
cat > "$tmp/apt/sources.list.d/ubuntu-esm-apps.sources" <<'EOF'
Types: deb
URIs: https://esm.ubuntu.com/apps/ubuntu
Suites: noble-apps-security
Components: main
EOF
echo 'deb [arch=arm64] https://packages.microsoft.com/ubuntu/24.04/prod noble main' \
   > "$tmp/apt/sources.list.d/microsoft-prod.list"
cp "$tmp/apt/sources.list.d/ubuntu-esm-apps.sources" "$tmp/esm"
cp "$tmp/apt/sources.list.d/microsoft-prod.list" "$tmp/ms"

run
check "arm64: both Ubuntu stanzas use the list" "$ours $ours" \
   "$(uris "$tmp/apt/sources.list.d/ubuntu.sources")"
check "arm64: ESM is left alone" "" "$(diff "$tmp/esm" "$tmp/apt/sources.list.d/ubuntu-esm-apps.sources")"
check "arm64: another repository is left alone" "" "$(diff "$tmp/ms" "$tmp/apt/sources.list.d/microsoft-prod.list")"
check "arm64: ports mirrors, Ubuntu first" \
   "ports.ubuntu.com ftp.fau.de mirrors.dotsrc.org mirrors.ocf.berkeley.edu" \
   "$(mirrors)"
check "arm64: every mirror carries a priority of its own" \
   "priority:1 priority:2 priority:3 priority:4" "$(priorities)"
check "arm64: all ports paths" "4" "$(grep -c '/ubuntu-ports/' "$tmp/apt/mp-ubuntu-mirrors.list")"
check "arm64: apt retries and timeouts" 'Acquire::Retries "3";' \
   "$(grep Retries "$tmp/apt/apt.conf.d/80mp-ci-mirrors")"

cp "$tmp/apt/sources.list.d/ubuntu.sources" "$tmp/once"
run
check "arm64: a second run changes no source" "" "$(diff "$tmp/once" "$tmp/apt/sources.list.d/ubuntu.sources")"

# ubuntu.com does not resolve: its host goes last, the others keep their order.
setup arm64
printf 'Types: deb\nURIs: http://ports.ubuntu.com/ubuntu-ports/\nSuites: noble\nComponents: main\n' \
   > "$tmp/apt/sources.list.d/ubuntu.sources"
DOWN=ubuntu.com run
check "ubuntu.com down: Ubuntu last" \
   "ftp.fau.de mirrors.dotsrc.org mirrors.ocf.berkeley.edu ports.ubuntu.com" \
   "$(mirrors)"
check "ubuntu.com down: said in the log" "1" "$(grep -c 'ports.ubuntu.com/ubuntu-ports/ does not answer' "$tmp/out")"

# Nothing answers: all stay, in their order, with a warning.
setup arm64
printf 'Types: deb\nURIs: http://ports.ubuntu.com/ubuntu-ports/\nSuites: noble\nComponents: main\n' \
   > "$tmp/apt/sources.list.d/ubuntu.sources"
DOWN=http run
check "nothing answers: all stay in order" \
   "ports.ubuntu.com ftp.fau.de mirrors.dotsrc.org mirrors.ocf.berkeley.edu" \
   "$(mirrors)"
check "nothing answers: warning" "1" "$(grep -c '^::warning::apt-mirrors: no Ubuntu mirror answers' "$tmp/out")"

# --- amd64, as ubuntu-24.04 ---------------------------------------------------
# The x64 image already goes through a mirror list of its own, and security
# may sit beside the archive in one line.

setup amd64
cat > "$tmp/apt/sources.list.d/ubuntu.sources" <<'EOF'
Types: deb
URIs: mirror+file:/etc/apt/apt-mirrors.txt
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse

Types: deb
URIs: http://azure.archive.ubuntu.com/ubuntu/ http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main universe restricted multiverse
EOF
cat > "$tmp/apt/sources.list" <<'EOF'
# a comment naming http://archive.ubuntu.com/ubuntu/ stays as it is
deb http://de.archive.ubuntu.com/ubuntu/ noble main
deb-src [trusted=no] http://security.ubuntu.com/ubuntu noble-security main
deb https://ppa.launchpadcontent.net/foo/bar/ubuntu noble main
EOF
run
check "amd64: the runner's mirror list and both hosts become ours" "$ours $ours" \
   "$(uris "$tmp/apt/sources.list.d/ubuntu.sources")"
check "amd64: one-line deb and deb-src use the list" \
   "deb $ours noble main|deb-src [trusted=no] $ours noble-security main" \
   "$(grep '^deb' "$tmp/apt/sources.list" | grep -v ppa | paste -sd'|')"
check "amd64: comment and PPA untouched" "2" \
   "$(grep -c -e '^# a comment naming http://archive.ubuntu.com/ubuntu/' -e 'ppa.launchpadcontent.net' "$tmp/apt/sources.list")"
check "amd64: archive mirrors, Azure first, then Aachen and Erlangen" \
   "azure.archive.ubuntu.com archive.ubuntu.com ftp.halifax.rwth-aachen.de ftp.fau.de mirrors.edge.kernel.org mirror.csclub.uwaterloo.ca mirrors.dotsrc.org" \
   "$(mirrors)"
check "amd64: no ports path" "0" "$(grep -c 'ubuntu-ports' "$tmp/apt/mp-ubuntu-mirrors.list" || true)"

# --- elsewhere ------------------------------------------------------------------

setup riscv64
printf 'Types: deb\nURIs: http://ports.ubuntu.com/ubuntu-ports/\nSuites: noble\nComponents: main\n' \
   > "$tmp/apt/sources.list.d/ubuntu.sources"
rc=0; run || rc=$?
check "unknown architecture: refused" "1" "$rc"
check "unknown architecture: source unchanged" "http://ports.ubuntu.com/ubuntu-ports/" \
   "$(uris "$tmp/apt/sources.list.d/ubuntu.sources")"

setup arm64
run
check "no Ubuntu source: warning" "1" "$(grep -c '^::warning::apt-mirrors: no Ubuntu source found' "$tmp/out")"

exit $fail
