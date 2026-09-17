# Meltingplot printer images

Images for the computers inside a Meltingplot printer, built with
[rpi-image-gen](../README.adoc). Each image has two root filesystems and is
updated over the air through Raspberry Pi Connect, so a printer can be brought
to a known software state and taken back off it if the new one misbehaves.

Phase 1 covers one target:

| Config | Machine | Contents |
|---|---|---|
| `duet-pi5.yaml` | Raspberry Pi 5 on the Duet 3 mainboard of a CHX350 | DuetSoftwareFramework, Duet Web Control, the CHX350 printer configuration, the Vigil monitoring plugin |

The operator panel (`hmi`) follows in phase 2 and shares `mp-base.yaml`.

## How an image is put together

Two root filesystems, one persistent partition, and a small boot partition that
holds which of the two to start. Everything the machine writes lives on the
persistent partition and is visible from both root filesystems, so an update
and a rollback both keep it:

| Path | Belongs to | What happens on an update |
|---|---|---|
| `/`, `/boot/firmware` | the image | replaced wholesale, read-only at runtime |
| `/opt/dsf/sd/{sys,macros,filaments}` | the image | the new printer configuration replaces the old one |
| `/opt/dsf/sd/www` | the image | the new Duet Web Control replaces the old one |
| `/opt/dsf/conf/{config,plugins}.json` | the image | corrected by the update |
| `/opt/dsf/sd/firmware` | the image | flashed to the Duet boards once the new slot is committed |
| the files in `layer/mp-dsf.d/protected.list` | the machine | never touched |
| `/opt/dsf/sd/gcodes`, calibration files, `/opt/dsf/sd/Vigil`, `/home` | the machine | never touched |

That split is the reason a printer configuration change reaches every printer
through a release, while a customer's calibration, filament tuning and printer
name survive it. Editing an image-owned file on the device works until the next
boot, when it is put back.

The image-owned G-code under `sys` and `macros` is built with a line number and
a CRC-16 on every line (`tools/gcode_crc.py` from chx350-config), so a flipped
bit in a file makes DuetControlServer reject the line and abort the macro
rather than run altered code. The machine-owned files and `sys/dsf-config.g`
are left as they are. Checking the CRCs takes the DuetSoftwareFramework build
of our own from 3.7.0-rc.1+mp.7 on; the build stops with any other control
server, which would read the CRC as part of the code. An edit on the device
has to keep line number and CRC in step, or the line is rejected.

## Building

The build runs the way rpi-image-gen documents it, on a Debian or Ubuntu host.
That is also what the release workflow does, on a native arm64 runner, and what
the upstream CI does on x86, so nothing here is specific to this project. On
x86 (including WSL2 with systemd) the chroot's arm64 binaries run through
qemu-user-static, which the Debian package registers with the kernel and keeps
registered across reboots:

```bash
# once per machine: the upstream tool list plus qemu and binfmt from
# meltingplot/depends, through the upstream installer
sudo ./install_deps.sh meltingplot/depends
# apt inside the chroot runs as _apt and has to reach the key directory under
# work/, so every directory on the way there needs the execute bit
chmod o+x "$HOME"
```

Then, from the repository root:

```bash
mkdir -p meltingplot/.cache/apt
./rpi-image-gen build -S ./meltingplot -c duet-pi5.yaml \
   -- IGconf_sys_apt_cachedir="$PWD/meltingplot/.cache/apt"
```

`make build` runs the same command; `VERSION=1.2.0-rc.1` on the make line
passes a version, `make test` runs the shell library tests. The Makefile in
the repository root holds nothing but these commands.

The cache directory is optional; with it, a second build does not download the
Duet packages and the .NET runtime again. rpi-image-gen runs as a regular user
through rootless podman and never needs root itself. `./rpi-image-gen clean`
removes the work directory.

Artefacts land in `work/deploy-<version>/`:

| File | Purpose |
|---|---|
| `mp-duet-pi5-<version>.img.zst` | full image, for writing to an SD card or NVMe drive |
| `mp-duet-pi5-<version>.update.tar.zst` | update bundle, for Raspberry Pi Connect |
| `mp-duet-pi5-<version>.idp.tar.zst` | provisioning archive, for rpi-sb-provisioner |
| `filesystem-<version>.sbom.zst` | software bill of materials |
| `release.json`, `SHA256SUMS` | what went into this build, and its checksums |

A build without a version is a development build. The release workflow passes
the version from the git tag.

### What is checked after a build

The SBOM is the input for three checks the release workflow runs once the
artefacts are out. None of them holds a release back, and none of them changes
the image; they are there so a problem in a shipped image is known, not so the
image never ships.

| Check | Covers | Result lands in |
|---|---|---|
| Dependabot, fed by the SBOM through the dependency submission API | the .NET packages of DuetSoftwareFramework, the Go modules of Raspberry Pi Connect, the Python packages | Security tab, Dependabot alerts |
| [grype](https://github.com/anchore/grype) | everything above, and the Debian packages from the Debian security tracker | Security tab, code scanning, for what has a fix; the full report in the `-audit` workflow artefact |
| [grant](https://github.com/anchore/grant) against `grant.yaml` | the licence of every package | job summary, and the `-audit` workflow artefact |

Dependabot is fed rather than left to read the repository because the image
has no manifest a dependency scanner would recognise; the SBOM syft writes
during the build is that manifest. GitHub's advisory database has no Debian
ecosystem, so Dependabot never sees the Debian packages and the kernel; that
gap is what grype is for. Alerts are only raised for the default branch, so
they reflect the last push to `meltingplot`, not the last tag. Most of what
grype finds in a Debian image has no fix in Debian yet, so only findings with
one reach the Security tab; a rebuild picks the fix up once it is packaged.
The unfiltered report, including the unfixed ones, is in the audit artefact.
The workflow also runs on a weekly schedule, since grype only knows what it
saw at the last build.

What cannot be fixed by rebuilding is assessed in `vex.openvex.json`, an
OpenVEX document grype reads before reporting. A statement names the
vulnerability, the component at the version assessed, and a status: a
`not_affected` statement with its justification drops the finding from the
Security tab, an `under_investigation` statement leaves it there and records
what is known. The statements are bound to the component version, so a
rebuild with a fixed component makes them moot rather than wrong. The current
file covers the Go runtime inside Raspberry Pi Connect, which only Raspberry
Pi can rebuild; the symbol-level check behind it was `govulncheck
-mode=binary` on the two Connect binaries.

Two findings were removed at the source instead: the Vigil virtual environment
no longer carries pip, which the build only needs to install dsf-python and
which nothing on the device uses, and the wireless and bluetooth firmware is
taken out of the image by `mp-net-static`, since the radios it serves are
switched off in firmware anyway.

grant fails the run for any package whose licence is outside `grant.yaml`.
The file holds the licence families accepted for the image, the entries from
the review of the first build, and the licences of the components that carry
no metadata of their own, the Duet stack and Raspberry Pi Connect among them.
A new licence therefore needs a decision before the image ships; the file
says how to record one. The grant version is pinned in the workflow, like
syft in the build; grype comes with the scan action at the version that
action ships.

What the licences oblige the image to tell its user is in one place on the
device: `0:/sys/LICENSES.txt`, readable in Duet Web Control next to the
printer configuration and replaced with every update. It comes from
`layer/mp-dsf.d/LICENSES.txt` with the image version filled in and the
paragraphs on replaced Duet firmware and on DuetSoftwareFramework packages
from a build of our own written from `firmware.list` and `packages.list`, so
a patched board firmware or control server is named together with the
release its modified source is published in. The file covers who licensed what, where
the corresponding source of the exact version is, the written offer for it,
how a modified image gets onto the machine, and the Broadcom and Raspberry
Pi notices the boot firmware requires to be reproduced. The post-build
assert refuses an image without it, or one that does not name every
replaced firmware file and package. Everything else in the file is static: a
new component, pin or source repository means editing it.

`.github/dependabot.yml` also lets Dependabot propose updates for the actions
the workflows use and for the commit of the printer configuration submodule.
The component pins in `layer/mp-dsf.yaml` are not something Dependabot can
read and stay manual.

Both scanners run against the published SBOM, so any release can be checked
again later:

```
zstd -d filesystem-<version>.sbom.zst -o filesystem.spdx.json
grype sbom:filesystem.spdx.json
grant check -c meltingplot/grant.yaml filesystem.spdx.json
```

### Versions and prereleases

Everything the image contains is pinned: the DuetSoftwareFramework version, the
Vigil release and its checksum, the dsf-python version, the commit of the
printer configuration, any Duet firmware file a build of our own replaces,
and any DuetSoftwareFramework package that comes from a build of our own. A
prerelease of any of them is allowed while the image
itself is a prerelease, and refused once it is not, so a customer image can
never quietly contain a release candidate. The check runs before the build
starts; see `hooks/prebuild05-mp-release-gate`.

Only published release assets are used. If a component has no release for the
Duet Web Control generation this image targets, the build stops rather than
falling back to something built locally.

Current pins are the defaults in `layer/mp-dsf.yaml`.

### Replacing a Duet firmware file

The Duet firmware comes from the `reprapfirmware` package, one file per board
type below `/opt/dsf/sd/firmware`. A build published separately, say a patched
TOOL1LC firmware, is listed in `layer/mp-dsf.d/firmware.list`:

```
Duet3Firmware_TOOL1LC.bin sha256:<checksum> https://<where the build is published>
```

The build fetches the file, checks it against the pin, sets the packaged copy
aside with `dpkg-divert` and puts the published build under the packaged name.
That name is the only one that works: RepRapFirmware derives it from the type
of the board it flashes and `M997` takes no path. The directory is part of the
read-only root and outside the slot-shared paths, so an image is the only way
such a file reaches a printer; an upload through Duet Web Control fails. A
line that names a file the package does not deliver, a location that is not
`https`, or a build that does not match its checksum stops the build. There is
no local path and no fallback. What was replaced is recorded in
`release.json`, and `dpkg-divert --list` shows it on the device.

On the device nothing changes: `mp-dsf-firmware` flashes every board, the
mainboard and the expansion boards alike, whose reported version differs from
the version string inside its file. A patched build therefore needs a version
string of its own, such as `3.7.0-rc.1+mp1`, or the boards keep the firmware
they have and only a manual `M997 B<address>` puts it on. The same comparison
puts the packaged firmware back once the line is removed again.

### Installing a DuetSoftwareFramework build of our own

The DSF packages form one generation. `duetcontrolserver` needs
`duetruntime` at exactly its own version, `duetpluginservice` needs
`duetcontrolserver` at exactly its own version, the `duetsoftwareframework`
meta package needs all of them at that version, and the programs check each
other's version again when they connect. A modified DuetControlServer is
therefore never a single package: the whole set the fork builds is installed
in place of the archive's set. It is listed in `layer/mp-dsf.d/packages.list`,
one line per package:

```
duetsoftwareframework sha256:<checksum> https://<where the .deb is published>
duetcontrolserver     sha256:<checksum> https://...
duetwebserver         sha256:<checksum> https://...
duetpluginservice     sha256:<checksum> https://...
duettools             sha256:<checksum> https://...
duetruntime           sha256:<checksum> https://...
```

The artefacts are the `.deb` files that the upstream packaging in the fork
builds from the modified source, what Duet3D would have put in its archive:

```bash
# in the fork, on the branch of the pinned generation (v3.7-dev for 3.7.0-rc.1)
# Directory.Build.props: <Version>3.7.0-rc.1+mp.7</Version>
pkg/build.sh --target-arch=aarch64 --packages=progs,meta deb
```

The build fetches every listed package, checks it against the pin, and
installs the set in one apt transaction together with what the archive
still provides: `duetsd`, `duetwebcontrol` and `reprapfirmware`, which the
build's meta package pins to the archive's versions, and any package of the
generation the list leaves out, at `dsf.version`. apt checks the
exact-version chain over all of them, so a set that does not close, say a
build without its meta package, stops the build instead of leaving a mixed
installation. dpkg, the SBOM, `M122` and Duet Web Control then all report
the build's version.

The build has to be of the pinned generation and carry a version of the form
`<dsf.version>+<suffix>`, `3.7.0~rc.1+mp.1` for a modified `3.7.0~rc.1`. The
suffix is what tells it apart from the archive's package; a package that
keeps the archive's version is the archive's package and is left out of the
list. A line that names a package outside the generation, a location that is
not `https`, a build of a different package, architecture or version, or a
list without the meta package stops the build. There is no local path and no
fallback. `release.json` records what came from the build, and
`0:/sys/LICENSES.txt` names each package with its version and the release
its modified source is published in.

A board firmware file is not part of this: it belongs to `reprapfirmware`,
which is versioned separately, and goes through `firmware.list`.

## Commissioning a printer

The image is identical on every machine. What makes a device unique is written
to the boot partition when the medium is flashed.

1. Take `mp-duet-pi5-<version>.img.zst` from the release and check it against
   `SHA256SUMS`.
2. Write it to the SD card or NVMe drive, with Raspberry Pi Imager (*Use
   custom*) or:
   ```bash
   zstdcat mp-duet-pi5-<version>.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync
   ```
   Do not use the Imager's own customisation: it writes settings for Raspberry
   Pi OS, which this image does not read.
3. Mount the first partition, labelled `BOOTCONFIG`, and put a file
   `meltingplot/identity.conf` on it, from
   [identity.conf.example](identity.conf.example): the printer serial, the name
   the customer wants, and a Raspberry Pi Connect auth key for this device.
4. Fit the medium, connect the Duet mainboard and the printer network, power up.

The first boot stores the identity, signs in to Raspberry Pi Connect, removes
the auth key from the boot partition, grows the persistent partition to the
medium, seeds the machine-owned configuration and starts the control server.

Check afterwards: Duet Web Control answers on the printer address, `M115` and
`M122` reply, the device is listed in Connect, and the Vigil page shows
counters.

### The printer name

The name shown in Duet Web Control and on the PanelDue is also the Linux
hostname, because DuetControlServer refuses a machine name that disagrees with
it. It is set at commissioning, and the customer can change it afterwards:

```bash
sudo mp-set-printer-name "Halle 2 links"
```

or by editing `sys/meltingplot/printer-name.g` in Duet Web Control. The name is
machine-owned, so an update does not reset it. The device keeps its original
name in Raspberry Pi Connect, which is how Meltingplot finds a machine again
regardless of what the customer called it; the serial is also a tag there and
is recorded in `/persistent/common/etc/mp-identity`.

## Updating a fleet

1. Tag the repository `duet-pi5/v<version>`. The workflow builds the image and
   publishes a release; a version with a suffix becomes a prerelease. The
   release notes carry the commits since the previous release as the
   changelog, which the printer points its operator to after the update.
2. Register the artefact in the Raspberry Pi Connect dashboard under *Remote
   update*: the URL of `mp-duet-pi5-<version>.update.tar.zst` from the release,
   and its SHA-256 from `SHA256SUMS`.
3. Deploy it to a device. Once the printer is idle, the device writes the
   bundle to the root filesystem it is not running from, restarts into it
   once, and keeps it if it comes up.

Roll out to a bench machine first, then to pilot customers.

To go back, deploy the previous artefact again. It stays registered.

### What happens on the device

1. The update connector from `rpi-connect-ota` runs only while the printer is
   idle. `mp-ota-gate` checks once a minute what RepRapFirmware reports and
   stops the connector's service for anything but idle: a running, paused or
   cancelling print, a firmware update, or a control server that cannot be
   asked. A deployment created in Connect meanwhile stays pending there, for
   as long as the print takes.
2. Once the printer is idle the connector runs, picks the deployment up,
   streams the bundle into the other slot and restarts the machine at once.
   That is the packaged behaviour, and it cannot be changed: the connector's
   `AutoReboot=false` setting makes it ask the Connect daemon over D-Bus, the
   daemon does not implement the question, and a failed question counts as
   yes. This was found the hard way, with a print cut short by a restart.
   What the gate cannot cover is the minute between a print starting and its
   next check: an install that completes within that minute restarts the
   machine. Support can deploy to a printer whose control server is down by
   stopping `mp-ota-gate.timer` and starting `rpi-connect-ota` by hand over
   the Connect shell.
   While the connector reports an install in progress, the gate puts a
   message box titled *OTA Update* on the PanelDue and in Duet Web Control
   (`M291 S0`, no buttons) asking not to shut the machine down until the
   message is gone. The gate learns of the install on its next check, so the
   message can appear up to a minute after the download has started, and it
   takes it down again when an install ends without a restart.
3. The bootloader starts the new slot once. If it does not come up, the next
   reset returns to the old one. If it comes up, the connector commits it
   within seconds of boot and reports the deployment as succeeded. That is the
   whole health check: Linux booted far enough to run the connector.
4. `mp-dsf-firmware` runs on every boot, waits for the printer to report
   idle, which RepRapFirmware does only once `config.g` is through (it reports
   *starting* until then, and `config.g` waits for every board), then for the
   slot to be committed, and then runs `DuetControlServer -u`, which
   flashes every Duet board whose firmware differs from the files under
   `/opt/dsf/sd/firmware`. Those files belong to the slot, so a rollback
   flashes the previous firmware back the same way. Until that has happened,
   Duet Web Control shows a firmware mismatch warning. Waiting for the end of
   `config.g` matters because flashing takes a board off the CAN bus, and a
   `config.g` that cannot reach one of its boards ends in an emergency stop,
   which cancels the update. `DuetControlServer -u` returns while the
   mainboard is still restarting, so after a flash the script waits for
   RepRapFirmware to report a later start and to be idle again, and asks once
   more, up to three passes, until every board is up to date.
   The message box from before the restart does not survive it. On a
   boot the bootloader started as a tryboot, which is every boot that follows
   an update, `mp-dsf-firmware` puts the *OTA Update* notice up again as soon
   as the control server answers, and again after every reset of the
   mainboard during the firmware update. Once every board is up to date it
   replaces the notice with a message box saying the update to this version
   is complete, with a link to the release
   page as the changelog (Duet Web Control renders the message as HTML), a
   Close button and no timeout (`M291 S1 T0`), so whoever next stands at the
   printer sees what happened. The
   version and the page come from `/etc/meltingplot/device.conf`, which the
   release workflow fills in; a local build names its development version and
   no page. When the printer does not become idle, the slot is not committed
   or the firmware cannot be brought up to date, a message box of the same
   kind says that the firmware update did not complete. Any other message
   box, such as a macro's dialog, is left alone.

The flash comes after the commit, so a firmware that fails to flash is not
undone by the bootloader. A Duet board keeps its bootloader, so it can be
recovered over USB, but not remotely. Committing only after a successful flash
is planned, see the project plan.

### Rolling back by hand

```bash
sudo sh -c 'rpi-slot-tryboot > /bootfs/autoboot.txt'
sudo reboot '0 tryboot'
```

This starts the other root filesystem once. Running the same command again
after it comes up makes the choice permanent. The persistent partition is not
touched either way, so the machine keeps its data; image-owned configuration
returns to the version that slot carries. The firmware follows on the next
boot after the commit, or right away with
`sudo systemctl start mp-dsf-firmware`.

## Plugins

Duet Web Control plugins can be installed as usual. Plugins that would run code
on the printer cannot: they install, but never start. A printer placed on the
market may only run software that is part of a released image, so the plugins
that do run are the ones the image brought, currently Vigil.

The rule is enforced by an AppArmor profile
(`layer/mp-dsf.d/customize.overlay/etc/apparmor.d/opt.dsf.bin.DuetPluginService`)
and a systemd sandbox around the plugin service. Refusals show up as
`apparmor="DENIED"` in `journalctl -k`.

Adding another Meltingplot plugin to an image means adding its files to the
build, a read rule for them and one for its endpoint sockets below `/run/dsf`
to the `dsf_plugin_py` profile, and its id to the Duet Web Control factory
defaults in `sys/dwc-defaults.json`. That last file is what makes a fresh
printer load the plugin's web part: DWC keeps its own list of enabled plugins,
and the SBC autostart list in `plugins.txt` says nothing to it. Build with
`-- IGconf_dsf_plugin_policy=complain` to collect what a plugin needs first;
never ship that.

## What is deliberately missing

- `duetpimanagementplugin`: it manages the network, the hostname and apt
  updates. All three are fleet-managed here, and none of them work on a
  read-only root.
- On-device apt upgrades: the root filesystem is read-only and the software
  bill of materials has to keep describing what is installed. Updates arrive as
  images.
- Firmware upload through Duet Web Control: the firmware belongs to the image
  and is flashed by `mp-dsf-firmware`, so a rollback puts the matching
  firmware back. A build that has to differ from the package goes through
  `firmware.list`, see above. Nothing in DSF itself flashes on a version mismatch;
  the `AutoUpdateFirmware` setting in `config.json` is not read by
  DuetControlServer 3.7.
- Wi-Fi and Bluetooth on the printer computer: it is wired to the operator
  panel on its own network segment.
