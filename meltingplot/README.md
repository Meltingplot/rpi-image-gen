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
| the files in `layer/mp-dsf.d/protected.list` | the machine | never touched |
| `/opt/dsf/sd/gcodes`, calibration files, `/opt/dsf/sd/Vigil`, `/home` | the machine | never touched |

That split is the reason a printer configuration change reaches every printer
through a release, while a customer's calibration, filament tuning and printer
name survive it. Editing an image-owned file on the device works until the next
boot, when it is put back.

## Building

The build needs a Debian or Ubuntu host with the rpi-image-gen dependencies
installed (`sudo ./install_deps.sh` in the repository root, plus
`qemu-user-static` and `binfmt-support` when building on x86).

```bash
./rpi-image-gen build -S ./meltingplot -c duet-pi5.yaml
```

Artefacts land in `work/deploy-<version>/`:

| File | Purpose |
|---|---|
| `mp-duet-pi5.img.zst` | full image, for writing to an SD card or NVMe drive |
| `mp-duet-pi5.update.tar.zst` | update bundle, for Raspberry Pi Connect |
| `mp-duet-pi5.idp.tar.zst` | provisioning archive, for rpi-sb-provisioner |
| `filesystem-<version>.sbom.zst` | software bill of materials |
| `release.json`, `SHA256SUMS` | what went into this build, and its checksums |

A build without a version is a development build. The release workflow passes
the version from the git tag.

### Versions and prereleases

Everything the image contains is pinned: the DuetSoftwareFramework version, the
Vigil release and its checksum, the dsf-python version, and the commit of the
printer configuration. A prerelease of any of them is allowed while the image
itself is a prerelease, and refused once it is not, so a customer image can
never quietly contain a release candidate. The check runs before the build
starts; see `hooks/prebuild05-mp-release-gate`.

Only published release assets are used. If a component has no release for the
Duet Web Control generation this image targets, the build stops rather than
falling back to something built locally.

Current pins are the defaults in `layer/mp-dsf.yaml`.

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
   publishes a release; a version with a suffix becomes a prerelease.
2. Register the artefact in the Raspberry Pi Connect dashboard under *Remote
   update*: the URL of `mp-duet-pi5-<version>.update.tar.zst` from the release,
   and its SHA-256 from `SHA256SUMS`.
3. Deploy it to a device. The device writes the bundle to the root filesystem it
   is not running from, restarts into it once, and keeps it if it comes up.

Roll out to a bench machine first, then to pilot customers. **Never deploy to a
printer that is printing**: applying an update reboots the machine.

To go back, deploy the previous artefact again. It stays registered.

### Rolling back by hand

```bash
sudo sh -c 'rpi-slot-tryboot > /bootfs/autoboot.txt'
sudo reboot '0 tryboot'
```

This starts the other root filesystem once. Running the same command again
after it comes up makes the choice permanent. The persistent partition is not
touched either way, so the machine keeps its data; image-owned configuration
returns to the version that slot carries.

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
build and a read rule to the `dsf_plugin_py` profile. Build with
`-- IGconf_dsf_plugin_policy=complain` to collect what it needs first; never
ship that.

## What is deliberately missing

- `duetpimanagementplugin`: it manages the network, the hostname and apt
  updates. All three are fleet-managed here, and none of them work on a
  read-only root.
- On-device apt upgrades: the root filesystem is read-only and the software
  bill of materials has to keep describing what is installed. Updates arrive as
  images.
- Firmware upload through Duet Web Control: the mainboard firmware belongs to
  the image, so a rollback puts the matching firmware back. It is flashed
  automatically when it does not match the control server.
- Wi-Fi and Bluetooth on the printer computer: it is wired to the operator
  panel on its own network segment.
