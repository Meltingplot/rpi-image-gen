# Plan: Meltingplot A/B-Image „duet-pi5“ (Phase 1) mit rpi-image-gen

## Kontext

Im Vorgriff auf die EU-Maschinenverordnung sollen die Drucker-Rechner (je Drucker: Pi5 HMI inkl. Kameramodul via `motion`, Pi5 Duet3D-DSF) als A/B-Images mit Rollback, später Secure Boot und OTA-Updates über Raspberry Pi Connect ausgeliefert werden. Ein separates Kamera-Pi gibt es nicht mehr. Phase 1 bildet **DuetPi Lite (trixie, ohne GUI)** für einen **Pi5 am Duet3-Board** auf dem `image-rota`-Layout von rpi-image-gen ab. RPi Connect soll auf jedem Image automatisch aktiv und mit dem Meltingplot-Account verknüpft sein.

Ergebnisse der Recherche, die den Plan prägen:

- rpi-image-gen (dieses Repo, v2/YAML) bringt alles Nötige mit: A/B-Layout `image-rota` ([image/gpt/ab_userdata/image.yaml](image/gpt/ab_userdata/image.yaml)), Slot-Mapper mit tryboot ([layer/rpi/device/ab-slots.yaml](layer/rpi/device/ab-slots.yaml)), `rpi-connect-lite` + `rpi-connect-ota` ([layer/rpi/device/services/](layer/rpi/device/services/)), OTA-Bundle-Erzeugung (`<image>.update.tar.zst`), IDP-Archiv für rpi-sb-provisioner (Secure Boot später), SBOM.
- DuetPi (pi-gen, Branch trixie, geklont im Scratchpad `duetpi/`) besteht im Kern aus: Apt-Repo `https://pkg.duet3d.com/ stable armv7` (arm64-Index unter `dists/stable/armv7/binary-arm64/`; Release Candidates liegen in der Suite `unstable`), Paketen `duetsoftwareframework` + `duetpimanagementplugin`, `dtparam=spi=on`, `spidev bufsiz=8192`, `kernel.panic=1`, avahi-Service, Aktivierung von `duetcontrolserver duetwebserver duetpluginservice(-root)`, User in Gruppe `dsf`, Default-`config.g`, RRF-/DWC-Download von GitHub nach `/boot/firmware`.
- Das Debian-Paket `reprapfirmware` (Abhängigkeit von `duetsoftwareframework`) liefert die Duet-Board-Firmware bereits nach `/opt/dsf/sd/firmware`; `duetwebcontrol` liefert DWC nach `/opt/dsf/dwc`. Der GitHub-Download aus DuetPi entfällt damit. **Korrektur (2026-09-11):** `AutoUpdateFirmware` in `config.json` wird von DCS 3.7 nirgends ausgewertet; DSF flasht von sich aus nie. Der Versionsvergleich läuft nur in `DuetControlServer -u` (Update-Modus), den DuetPi aus dem Postinst von `reprapfirmware` aufruft und den unser Image per `mp-dsf-firmware.service` nach dem Commit des Slots aufruft. Ohne Terminal auf stdin flasht `-u` alle abweichenden Boards ohne Rückfrage; die Y/n-Frage erscheint nur interaktiv.
- **DuetWebServer liefert DWC aus dem virtuellen `www`-Verzeichnis** des Objektmodells (`directories.web` = `0:/www` → `/opt/dsf/sd/www`, per `ResolvePath` von DCS aufgelöst); `/opt/dsf/dwc` ist nur der `DefaultWebDirectory`-Fallback, wenn DCS nicht erreichbar ist. DWC-Plugin-Dateien werden vom PluginService ebenfalls nach `/opt/dsf/sd/www` kopiert. `/opt/dsf/sd/www` muss daher im Image die DWC-Dateien enthalten **und** slot-übergreifend beschreibbar sein.
- Die Basis-Suite setzt `APT::Install-Recommends=false` → `duetpluginservice` (nur Recommends) muss explizit gelistet werden, wenn gewünscht.
- **Stolperstein Immutable Root:** `/`, `/opt`, `/boot/firmware` sind read-only (erofs). DSF schreibt nach `/opt/dsf/sd`. Slot-übergreifende Verzeichnisse werden per `/etc/rpi-image-gen/slot-shared.d/*.conf` gebunden, aber `rpi-persistent-shared-init` ([image.d/postbuild.overlay/usr/sbin/rpi-persistent-shared-init](image/gpt/ab_userdata/image.d/postbuild.overlay/usr/sbin/rpi-persistent-shared-init)) rsynct **bei jedem Boot mit `--checksum`** vom Image-Pfad nach `/persistent/shared/<pfad>` → im Image liegende Dateien überschreiben Nutzeränderungen. Daher: Nutzerdaten-Pfade im Image leer lassen, Skelett separat ablegen, per Oneshot ohne Überschreiben seeden.
- **Drucker-Konfiguration aus `Meltingplot/chx350-config`** (Branch `3.7`, aktuell identisch mit `3.6`, Commit `a889995`): `sys/`, `macros/`, `filaments/` sollen **fest im Image** liegen, damit Nutzer sie nicht überschreiben. Bisher übernimmt das DWC/DSF-Plugin `MeltingplotConfig` (`dwc-meltingplot-config`) den Git-Sync mit einer Schutzliste maschinenlokaler Dateien. Im A/B-Image ersetzt die Boot-Push-Semantik von `rpi-persistent-shared-init` genau diesen Sync: Repo-Dateien liegen im Image unter `/opt/dsf/sd/{sys,macros,filaments}`, werden bei jedem Boot per Checksum nach `/persistent/shared/...` geschrieben (Nutzeränderungen sind nach dem nächsten Boot weg, OTA liefert neue Stände), während die **Schutzliste des Plugins** (`sys/config-override.g`, `sys/meltingplot/{machine-override,dsf-config-override.g,global-override.g}`, `filaments/*/config-override.g`, `filaments/*/temps.g`) sowie alle maschinenlokal erzeugten Dateien (`nozzle<n>.g`, `last-filament-temp.g`, `config-auto-*.g`, `nozzle-<key>.g`, `szp_*_calibration_*.g`, `heightmap.g`, `dwc-settings.json`) **nicht** im Image liegen und nur einmalig geseedet werden.
- Das Plugin `MeltingplotConfig` ist ein SBC-Plugin (Python-Daemon, braucht `git`, `launchProcesses`); seine Aufgabe (Config-Sync) übernimmt das OTA-Update. Es wird im Duet-Image nicht installiert.
- **`Vigil` (`Meltingplot/dwc-vigil`) wird vorinstalliert ausgeliefert.** Es ist ebenfalls ein SBC-Plugin: `sbcExecutable: vigil-daemon.py`, `sbcPythonDependencies: [dsf-python]`, Rechte `commandExecution, objectModelReadWrite, registerHttpEndpoints, fileSystemAccess` (kein `launchProcesses`, kein SuperUser). Daten liegen unter `/opt/dsf/sd/Vigil/` (`vigil_data.json` + Backup/Parität, Monats-History). DSF startet Python-Plugins aus der dsf-Instanz des PluginService via `/bin/bash -c "<plugindir>/venv/bin/python <exe>"`. Release-Zips heißen `Vigil-<ver>-dwc36.zip` / `-dwc37.zip`; Pre-Release `v1.3.0-beta.1` (2026-09-10) liefert erstmals ein `-dwc37`-Asset.
- **Plugin-Policy präzisiert:** Von Meltingplot im Image ausgelieferte SBC-Plugins (aktuell Vigil) dürfen laufen; nachträglich installierte Plugins dürfen nur reine DWC-Plugins sein. Durchsetzung per AppArmor-Kette, die Python-Prozesse des PluginService nur die freigegebenen Plugin-Verzeichnisse lesen lässt (s. `mp-dsf`).
- **Stolperstein UIDs:** `dsf` wird vom Postinst via `systemd-sysusers` mit dynamischer UID angelegt; zwischen Builds kann sie sich ändern → Dateien auf `/persistent` gehörten nach OTA dem falschen User. Lösung: `dsf` mit fester UID/GID (992 wie DuetPi) in einem `essential-hook` vor der Paketinstallation anlegen (sysusers wird dann zum No-op). `user1uid/gid` ebenfalls pinnen.
- `IGconf_device_storage_type` beeinflusst nur das IDP-Dokument (Zielgerät für rpi-sb-provisioner) und eMMC-Write-Protect, nicht das Image (Root wird über GPT-PARTLABEL `system_a/b` gefunden). **Ein Image läuft auf SD und NVMe.** Der Pi5-Trait setzt kein `hw:storage:nvme`; `storage_type: nvme` braucht später einen Trait-Override, nur für die Provisionierung.
- Netzwerk am Duet-Pi: statische IP 10.42.0.2/24, Gateway + DNS 10.42.0.1 (HMI-Pi), WLAN/BT aus. **Empfehlung: systemd-networkd** (minbase-Default, eine statische `.network`-Datei im Image, kein Laufzeitzustand, kleiner). NetworkManager lohnt nur bei Laufzeit-Umkonfiguration (M587/Management-Plugin), was hier nicht gewünscht ist.
- image-rota erlaubt nur `class` `cm4|pi4|cm5|pi5`; da beide verbleibenden Ziele Pi5 sind, ist das unkritisch.

Entscheidungen des Users: **nie Passwort-Login** auf den Geräten (Konto gesperrt, SSH nur mit Key via `ssh.pubkey_only: y`, deshalb `user1sudo: nopasswd`; der Layer `device-user-admin` warnt bei nopasswd ohne Passwort nur, bricht nicht ab); Projekt **innerhalb** von rpi-image-gen; **DSF/RRF 3.7, aktuell `3.7.0~rc.1`** aus der Suite `unstable` (Stand 2026-09-10: `duetsoftwareframework 3.7.0~rc.1` hängt exakt von `duetcontrolserver/duettools/duetwebserver/duetwebcontrol = 3.7.0~rc.1`, `duetsd = 1.1.0`, `reprapfirmware 3.7.0~rc.1-N`); RRF-Firmware **versionsgepinnt bündeln** (erfüllt durch gepinntes `reprapfirmware`-Paket); **ein Image für SD und NVMe**; networkd oder NM (→ networkd); **`duetpimanagementplugin` wird nicht installiert** (liefert Funktionen wie apt-Updates, WLAN-/Hostname-Verwaltung, FTP/Telnet, die nicht gewollt sind und auf dem Immutable Root nicht funktionieren). Linux-Username **`meltingplot`**, UID/GID 1000 (bestätigt).

## Zielstruktur (neu, alles unter `meltingplot/` in diesem Repo)

Gebaut wird mit `./rpi-image-gen build -S ./meltingplot -c duet-pi5.yaml` (`-c` relativ zu `<src>/config`; Suchpfade `-S`: `config/`, `layer/`, `hooks/`, `rootfs-overlay/`; vgl. [examples/ota/](examples/ota/), [examples/webkiosk/](examples/webkiosk/)).

```
meltingplot/
  README.md                          Build/Flash/OTA/Rollback-Anleitung
  .gitignore                         secrets/, .cache/
  config/
    mp-base.yaml                     gemeinsam für alle Ziele: image-rota, User, SSH, Connect, Größen
    duet-pi5.yaml                    Phase-1-Ziel (include mp-base.yaml)
  layer/
    mp-suite-trixie.yaml             Basis-Suite ohne WLAN (Ersatz für trixie-minbase)
    mp-net-static.yaml               statisches eth0, WLAN/BT aus, NTP → HMI
    mp-connect.yaml                  rpi-connect-lite + rpi-connect-ota
    mp-identity.yaml                 First-Boot: Identity-Datei von /bootfs übernehmen, Hostname, /persistent vergrößern
    mp-identity.d/customize.overlay/ mp-identity.service, mp-hostname.service, mp-growfs.service + Skripte unter /usr/sbin/ (inkl. mp-set-printer-name)
    mp-duet-hw.yaml                  Pi-seitige SPI-Anbindung (config.txt, spidev, sysctl)
    mp-duet-hw.d/customize.overlay/  etc/modprobe.d/spidev.conf, etc/sysctl.d/10-panic.conf
    mp-dsf.yaml                      Duet3D-Repo, DSF-Pakete (gepinnt), Persistenz, Seeding
    mp-dsf.d/
      apt/duet3d.sources             DEB822 (X-IG-Signed-By: /usr/share/keyrings/duet3d.gpg)
      apt/duet3d.gpg                 aus DuetPi stage-dsf/01-dsf/files/duet3d.gpg
      protected.list                 maschinenlokale Dateien (Schutzliste, s. Persistenz)
      skel/conf/plugins.txt          Autostart-Liste, Inhalt `Vigil` (wird geseedet, nie überschrieben)
      (Vigil-Zip wird beim Bauen aus dem GitHub-Release geladen und per sha256 geprüft, kein Asset im Repo)
      customize.overlay/etc/apparmor.d/opt.dsf.bin.DuetPluginService   Profilkette PluginService → bash → python
      customize.overlay/etc/rpi-image-gen/slot-shared.d/dsf.conf
      customize.overlay/etc/systemd/system/duetpluginservice.service.d/mp-harden.conf (+ -root)
      customize.overlay/etc/avahi/services/duet3.service
      customize.overlay/usr/lib/systemd/system/mp-dsf-seed.service
      customize.overlay/usr/lib/systemd/system/duetcontrolserver.service.d/mp.conf
      customize.overlay/usr/sbin/mp-dsf-seed
      hooks/postbuild50-dsf-assert   Build-Zeit-Prüfungen
  hooks/prebuild05-mp-release-gate   finales artefact.version (ohne Suffix) nur mit finalen Pins
  hooks/deploy20-mp-release          schreibt release.json + SHA256SUMS ins Deploy-Verzeichnis
  keys/authorized_keys               öffentliche SSH-Keys der Meltingplot-Admins (kein Geheimnis, wird committet)
  chx350-config/                     git-Submodule Meltingplot/chx350-config, Branch 3.7 (Commit gepinnt)
  identity.conf.example              Vorlage für die Inbetriebnahme-Datei auf BOOTCONFIG
.github/workflows/meltingplot-duet-pi5.yml   CI-Build + GitHub-Release (s. Release-Pipeline)
```

Das Repo ist ein **öffentlicher** Fork `Meltingplot/rpi-image-gen` (Branch `meltingplot`, Upstream per Merge nachgezogen): GitHub Releases dienen als OTA-Hosting, daher dürfen keinerlei Geheimnisse im Baum liegen (Auth-Keys kommen erst bei der Inbetriebnahme aufs Gerät, s.u.).

## Konfiguration

### `config/mp-base.yaml`

```yaml
device:
  layer: rpi5
  user1: meltingplot
  user1uid: 1000
  user1gid: 1000
  user1groups: adm,dialout,plugdev,spi,i2c,gpio,video,render,dsf
  user1sudo: nopasswd          # dauerhaft: kein Passwort-Login auf den Geräten, Zugang nur per SSH-Key, Konto bleibt gesperrt (kein user1pass/user1passhash)
  hostname: mp-unset           # wird zur Laufzeit gesetzt (s. mp-identity)
  storage_type: sd             # nur IDP-Metadatum; Image läuft auch auf NVMe

image:
  layer: image-rota
  rootfs_type: erofs
  boot_part_size: 128M
  system_part_size: 1G         # minbase ~400M + DSF/.NET/DWC ~200M + Reserve für HMI-Wiederverwendung
  data_part_size: 4G           # /persistent: G-Codes, Logs, DSF-SD; bei Bedarf 8G

ssh:
  pubkey_user1: ${@SRCROOT}/keys/authorized_keys
  pubkey_only: y

connect:
  on: y                        # kein authkey im Build; kommt per identity.conf bei der Inbetriebnahme

artefact:
  version: 0.0.0-dev.$(date -u +%Y%m%d%H%M)   # lokale Builds sind immer Dev-Stände; CI überschreibt per Tag

layer:
  suite: mp-suite-trixie
  connect: mp-connect
  identity: mp-identity
```

Hinweise: `data_part_size` ist nur die Startgröße im Image. Raspberry Pi OS vergrößert sein Root-FS beim ersten Boot über die eigene `resize`-Logik in `cmdline.txt` (unabhängig vom Imager); rpi-image-gen bringt nichts Vergleichbares mit, und `expand-to-fit` greift nur beim Provisionieren über rpi-sb-provisioner/IDP ([provisionmap-clear.json](image/gpt/ab_userdata/image.d/device/provisionmap-clear.json)). Das Äquivalent für das A/B-Layout ist der First-Boot-Oneshot `mp-growfs` (Layer `mp-identity`), der die letzte Partition `persistent` auf die Mediengröße zieht; Root bleibt fest (A/B-Slots). `packages:`-Listen in nur **einer** Datei der Include-Kette definieren (Listen werden positionsweise gemerged); hier gar nicht nötig, die Pins liegen im Layer.

### `config/duet-pi5.yaml`

```yaml
include:
  file: mp-base.yaml
image:
  name: mp-duet-pi5
mpnet:
  address: 10.42.0.2/24
  gateway: 10.42.0.1
  dns: 10.42.0.1
  ntp: 10.42.0.1
layer:
  net: mp-net-static
  hw: mp-duet-hw
  app: mp-dsf
```

`artefact.version` (→ Deploy-Verzeichnis, Image-Version, Release-Gate) ist lokal `0.0.0-dev.<Zeitstempel>`; CI setzt per Tag `-- IGconf_artefact_version=0.1.0-rc.1` (bzw. final `0.1.0`). Der Upstream-Default `git describe` würde im Fork Upstream-Tags liefern und das Release-Gate fälschlich auslösen.

## Layer

### `mp-suite-trixie` (Kategorie suite)
Kopie von [layer/suite/debian/trixie-minbase.yaml](layer/suite/debian/trixie-minbase.yaml) ohne `wireless-regulatory` und `iwd`:
`Requires: debian-trixie-arm64-multi, rpi-debian-trixie, rpi-misc-utils, rpi-essential-base, rpi-misc-skel, systemd-net-min, openssh-server, systemd-timesyncd`.
Nicht übernommen aus DuetPi: dnsmasq/hostapd/proftpd/telnetd/inetd (dort ohnehin deaktiviert; Angriffsfläche), `06-rpi-libs` (VideoCore-Legacy-Libs), `unattended-upgrades`/`python3-pip` (kein apt auf dem Gerät), `pmount`-USB-Automount (ggf. später), `minicom/vim/bossa-cli`, `libcamera-*` (Kamera-Ziel).

### `mp-net-static` (Kategorie connectivity)
- `VarPrefix: mpnet`; Variablen `address`, `gateway`, `dns`, `ntp` (Valid: string, Set: y).
- `Requires: systemd-net-min, systemd-timesyncd, rpi-boot-firmware`; `AfterProvider: device` (damit wir nach [layer/rpi/device/family-base.yaml](layer/rpi/device/family-base.yaml) laufen, das `01-eth0.network`/`02-wlan0.network` via `netgen` schreibt).
- customize-hooks: `01-eth0.network` mit `[Network] Address=/Gateway=/DNS=` überschreiben, `02-wlan0.network` löschen; `/etc/systemd/timesyncd.conf.d/mp.conf` mit `NTP=${IGconf_mpnet_ntp}`; an `/boot/firmware/config.txt` anhängen: `[all]`, `dtoverlay=disable-wifi`, `dtoverlay=disable-bt`. (Firmware-Pakete `firmware-brcm80211`/`bluez-firmware` bleiben, da von `rpi-device-base` verlangt; harmlos.)

### `mp-connect` (Kategorie service)
- `Requires: rpi-connect-lite, rpi-connect-ota` (Muster [examples/ota/layer/ota.yaml](examples/ota/layer/ota.yaml)). Keine eigenen Hooks; `rpi-connect-lite` legt für `meltingplot` Linger, `rpi-connect.service` und `rpi-connect-signin.path` an – Letzteres meldet das Gerät automatisch an, sobald `~/.config/com.raspberrypi.connect/auth.key` erscheint. Genau das nutzt `mp-identity` (kein Auth-Key im Build, kein per-Gerät-Build).
- Auth-Keys: Organisations-Keys (`rpoak_…`, 1–90 Tage gültig, einer je Gerät, per Dashboard oder Management-API `POST /organisation/auth-keys` mit `device_name`); persönliche Keys (`rpuak_…`) gelten nur 6 h. Für die Serie später: Geräteidentitäten (`POST /organisation/device-identities`, OTP-Public-Key, Registrierung durch rpi-sb-provisioner via `RPI_CONNECT_API_KEY`) – dann entfällt der Key ganz.

### `mp-identity` (Kategorie device) – Inbetriebnahme auf dem Gerät
- `Requires: rpi-misc-skel, device-user-admin`; `RequiresProvider: systemd` (läuft damit nach dem Skel-Layer, dessen `127.0.1.1`-Zeile in `/etc/hosts` entfernt wird). Pakete: `cloud-guest-utils` (`growpart`), `gdisk` (`sgdisk -e`), `libnss-myhostname`.
- **Identity-Datei** `/bootfs/meltingplot/identity.conf` (BOOTCONFIG-Partition, FAT, rw, vom PC beschreibbar; Vorlage `identity.conf.example`):
  ```
  printer_serial=042            # Meltingplot-Seriennummer des CHX350 (Pflicht)
  printer_name=Halle 2 links     # optional: Anzeigename in DWC/PanelDue (M550); Default "Meltingplot CHX-350 042"
  connect_authkey=rpoak_...      # optional, einmalig; wird nach Übernahme aus der Datei entfernt
  ```
- `mp-identity.service` (Type=oneshot, DefaultDependencies=no, `RequiresMountsFor=/bootfs /persistent`, After=`persistent.mount machine-id-sync.service`, Before=`mp-hostname.service`), Skript `/usr/sbin/mp-identity`:
  1. Datei vorhanden → `printer_serial` validieren (genau drei Ziffern, `^[0-9]{3}$`) und nach `/persistent/common/etc/mp-identity` (`PRINTER_SERIAL=…`, `ROLE=sbc`, optional `PRINTER_NAME=…`, druckbare Zeichen ohne `"`) sowie Hostname `meltingplot-chx-350-<serial>-sbc` nach `/persistent/common/etc/hostname` schreiben (nur wenn dort noch nichts steht; eine einmal vergebene Seriennummer lässt sich über die Datei nicht mehr ändern, da der Kunde die BOOTCONFIG-Partition beschreiben kann). `PRINTER_NAME` wird von `mp-dsf-seed` beim Anlegen von `printer-name.g` verwendet, sonst der Default mit Seriennummer.
  2. `connect_authkey` gesetzt → `install -o meltingplot -g meltingplot -m 0600` nach `/home/meltingplot/.config/com.raspberrypi.connect/auth.key`; `rpi-connect-signin.path` übernimmt die Anmeldung, sobald das Netz steht. Danach die Zeile in `identity.conf` durch `connect_authkey=<applied YYYY-MM-DD>` ersetzen (Geheimnis verlässt die FAT-Partition).
  3. Ohne Datei: nichts tun (Fallback-Hostname `meltingplot-unprovisioned-<Pi-Serial>-sbc` aus `mp-hostname`, damit ein nicht in Betrieb genommenes Gerät sofort erkennbar ist).
- `mp-hostname.service` (Before=`network-pre.target systemd-hostnamed.service`, After=`mp-identity.service`), Skript `/usr/sbin/mp-hostname`: Hostname-Quelle in dieser Reihenfolge: (1) `M550 P"…"` aus `/persistent/shared/opt/dsf/sd/sys/meltingplot/printer-name.g` (Kundenname, s. `mp-dsf`), (2) `PRINTER_NAME` bzw. Default `meltingplot-chx-350-<serial>-sbc` aus `/persistent/common/etc/mp-identity`, (3) `meltingplot-unprovisioned-<letzte 6 Zeichen aus /proc/device-tree/serial-number>-sbc`. Ableitung: Nicht-Alphanumerisches → `-`, zusammenfassen, trimmen, ≤ 63 Zeichen; setzt den Kernel-Hostname (`hostname`). `/persistent/common/etc/hostname` dient nur noch als Cache des zuletzt gesetzten Werts. Schema-Default: `meltingplot-chx-350-<serial>-<rolle>` mit Rolle `sbc` (Duet-Pi) bzw. `hmi`. `/etc/hosts` ist read-only und bekommt im Image keinen `127.0.1.1`-Eintrag (der `rpi-misc-skel`-Eintrag mit dem Build-Hostnamen wird entfernt); die Auflösung des eigenen Namens übernimmt `libnss-myhostname` (`myhostname` in `/etc/nsswitch.conf`). Vorbild: `machine-id-sync.service` in [image.d/postbuild.overlay/](image/gpt/ab_userdata/image.d/postbuild.overlay/). Ergebnis: **ein Image und ein OTA-Bundle für alle Drucker**; Hostname = DWC-Anzeigename = Kundenname (DCS erzwingt die Übereinstimmung, s. `mp-dsf`), Meltingplot-Identität über Seriennummer in `mp-identity` und Connect-Tags.
- `mp-growfs.service` (Type=oneshot, After=`persistent.mount`, `ConditionPathExists=!/persistent/common/.growfs-done`), Skript `/usr/sbin/mp-growfs`: Boot-Disk aus `/dev/disk/by-slot/persistent` ableiten, `sgdisk -e <disk>` (Backup-GPT ans Medienende), `growpart <disk> <partnr>`, `resize2fs /dev/disk/by-slot/persistent` (online), Marker schreiben. Nötig, weil beim Flashen per Imager/dd kein `expand-to-fit` greift (nur rpi-sb-provisioner/IDP). Auf NVMe identisch.

### `mp-duet-hw` (Kategorie hw)
- `Requires: rpi-boot-firmware`; `RequiresProvider: hw:device:rpi:pi5`. Paket `gpiod` (Diagnose).
- customize-hook: `sed -i 's/^#dtparam=spi=on/dtparam=spi=on/' $1/boot/firmware/config.txt` (Pi5: SPI0 am RP1 → `/dev/spidev0.0`).
- Overlay: `/etc/modprobe.d/spidev.conf` (`options spidev bufsiz=8192`), `/etc/sysctl.d/10-panic.conf` (`kernel.panic=1`).
- customize-hook: `lsm=apparmor` in `/boot/firmware/cmdline.txt` einfügen (vor `rootwait`; der Slot-Postprocess schreibt nur `root=` um) – Voraussetzung für die Plugin-Sperre in `mp-dsf`. `cgroup_enable=memory` aus DuetPi wird nicht übernommen.

### `mp-dsf` (Kategorie app)
- `Requires: mp-duet-hw, device-user-admin, rpi-debian-trixie, sys-build-base`; `RequiresProvider: systemd`; `VarRequires: IGconf_sys_apt_keydir, IGconf_device_user1`.
- `VarPrefix: dsf`; Variablen `assetdir: ${DIRECTORY}/${STEM}.d` (Valid: dir; Muster [device/pi5/device.yaml](device/pi5/device.yaml)), `version: 3.7.0~rc.1`, `suite: unstable` (Valid: `stable,unstable`), `uid: 992` (int:100-999), `config_dir: ${@SRCROOT}/chx350-config` (Valid: dir; Checkout von `Meltingplot/chx350-config`, als Submodule gepinnt → reproduzierbar ohne Netzzugriff im Build; der Commit landet in der Manifest-/SBOM-Ausgabe). Die Sources-Datei wird aus `apt/duet3d.sources.in` mit `Suites: ${IGconf_dsf_suite}` gerendert (setup-hook, `envsubst`), damit der Wechsel auf `stable` beim 3.7.0-Final eine Config-Zeile ist.
- `mirrors: [ ${IGconf_dsf_assetdir}/apt/duet3d.sources ]`; setup-hook installiert `duet3d.gpg` nach `$1/usr/share/keyrings/` **und** `$IGconf_sys_apt_keydir` (Muster [layer/app-container/docker/engine-trixie.yaml](layer/app-container/docker/engine-trixie.yaml); `cleanup10-deb822-signedby` setzt `Signed-By`). Sources-Datei:
  ```
  X-IG-Signed-By: /usr/share/keyrings/duet3d.gpg
  Types: deb
  URIs: https://pkg.duet3d.com/
  Suites: unstable          # ${IGconf_dsf_suite}; RC-Pakete liegen nur hier
  Components: armv7
  Architectures: arm64
  ```
- essential-hook: `groupadd -g 992 dsf; useradd -r -u 992 -g dsf -d /opt/dsf -s /usr/sbin/nologin dsf`.
- Pakete gepinnt über `${IGconf_dsf_version}`: `duetsoftwareframework`, `duetcontrolserver`, `duetwebserver`, `duetwebcontrol`, `duettools`, `duetruntime`, `duetpluginservice` (=3.7.0~rc.1), `duetsd=1.1.0`, `reprapfirmware` (apt löst `3.7.0~rc.1-N` über die exakte Abhängigkeit von `duetsoftwareframework`), `avahi-daemon`, `apparmor`, `python3`, `python3-venv` (für Vigil).
- Weitere Variablen: `vigil_version: 1.3.0-beta.1` (Required), `vigil_sha256: acc7e7c16dd851474d4157188e365309de76246de1245ff04144832ea42cca32` (Required; Asset `Vigil-1.3.0-beta.1-dwc37.zip`, 300 147 Bytes, Pre-Release vom 2026-09-10), `dsf_python_version: 3.7.0b1` (Required). **Versionspinning gilt auch für das Plugin:** Der Layer lädt ausschließlich das offizielle Release- oder Pre-Release-Asset `https://github.com/Meltingplot/dwc-vigil/releases/download/v${vigil_version}/Vigil-${vigil_version}-dwc${MAJOR}${MINOR}.zip`, wobei `MAJOR.MINOR` aus `dsf_version` abgeleitet wird (3.7.0~rc.1 → `dwc37`). Liefert der Download 404 (kein Release für diese DSF/DWC-Generation) oder stimmt die sha256 nicht, **bricht der Build mit einer klaren Fehlermeldung ab** („Vigil ${vigil_version} hat kein Release-Asset für DWC ${MAJOR}.${MINOR}“). Keine lokal gebauten oder unveröffentlichten Artefakte. Gleiche Regel für `dsf-python`: exakte Version aus PyPI (aktuell nur `3.7.0b1` verfügbar), Fehler bei Nichtverfügbarkeit.
- **Release-Gate (Pre-Release-Regel):** Pre-Releases (Duet-Suite `unstable`/`~rc`, Vigil `-rc.`/`-dev`, PyPI `b`/`rc`) sind zulässig, solange das Image selbst Dev-/RC-Stand ist, d.h. `artefact.version` einen Vorab-Suffix trägt (`0.1.0-rc.1`, `0.1.0-dev.20260910`). Trägt `artefact.version` keinen Suffix (finales Release), prüft ein Hook (`prebuild05-mp-release-gate` im Quellbaum) alle Pins: `dsf_suite` muss `stable` und `dsf_version` ohne `~` sein, `vigil_version` ohne `-rc`/`-dev`/`-beta`, `dsf_python_version` ohne `a`/`b`/`rc`, chx350-config-Commit auf einem Release-Tag – sonst Abbruch mit Auflistung der verletzenden Pins. Damit kann der Durchstich sofort mit `3.7.0~rc.1` + Vigil `1.3.0-beta.1` + `dsf-python 3.7.0b1` laufen, ein finales Kundenrelease aber nie versehentlich Vorabversionen enthalten.
- Konsistenzprüfung chx350-config: der Submodule-Commit muss auf dem Branch `${MAJOR}.${MINOR}` (z.B. `3.7`) liegen (`git branch -r --contains HEAD`), sonst Build-Abbruch. Zusätzlich `/etc/apt/preferences.d/duet3d` mit `Pin: version 3.7.0~rc.1*` Priority 1001 für die DSF-Pakete, damit `unstable` nie eine neuere Beta/RC hineinzieht. **Kein** `duetpimanagementplugin`.
- customize-hooks:
  1. `enable-units duetcontrolserver duetwebserver duetpluginservice duetpluginservice-root mp-dsf-seed avahi-daemon apparmor`; `adduser dsf video`; Assert `id -u dsf` == 992.
  2. **Persistenz / Drucker-Konfiguration:** vom Paket `duetsd` gelieferte Platzhalter (`/opt/dsf/sd/sys/config.g` u.ä.) entfernen. Dann `sys/`, `macros/`, `filaments/` aus `${IGconf_dsf_config_dir}` nach `/opt/dsf/sd/` kopieren (ohne `.git`, `CLAUDE.md`, `LICENSE`, `.gitignore`) – diese Dateien sind **image-owned**: sie werden bei jedem Boot in den Shared-Pfad gepusht, Nutzeränderungen halten also nur bis zum nächsten Boot, OTA liefert neue Stände. Alle Pfade aus `protected.list` anschließend aus `/opt/dsf/sd/` nach `/usr/share/meltingplot/dsf-skel/sd/` **verschieben** (so liegen sie nicht im Image-Pfad und werden nicht gepusht). `protected.list` (initial, deckungsgleich mit der Schutzliste von `dwc-meltingplot-config` plus Druckername): `sys/config-override.g`, `sys/meltingplot/machine-override`, `sys/meltingplot/dsf-config-override.g`, `sys/meltingplot/global-override.g`, `sys/meltingplot/printer-name.g`, `filaments/*/config-override.g`, `filaments/*/temps.g`. `/opt/dsf/sd/{gcodes,menu}` und `/opt/dsf/plugins` leer anlegen; alles `dsf:dsf`, Verzeichnisse 2770, Dateien 0660 (passt zu DSF `UMask=0002`). `/opt/dsf/sd/firmware` (aus `reprapfirmware`) und `/opt/dsf/bin` bleiben immutable im Image, je Slot. Hinweis: in `dsf-config-override.g` bleibt `M552/M554` auskommentiert, die IP kommt von systemd-networkd; die `M550`-Zeile wandert nach `printer-name.g` (s. Kundenspezifischer Druckername).
  2b. **DWC-Verzeichnis:** `/opt/dsf/sd/www` als echtes Verzeichnis anlegen (falls das Paket dort einen Symlink auf `/opt/dsf/dwc` setzt, diesen ersetzen) und den Inhalt von `/opt/dsf/dwc` hineinkopieren; `/opt/dsf/dwc` durch einen Symlink auf `/opt/dsf/sd/www` ersetzen (spart ~35 MB, Fallback-Pfad bleibt gültig). `www` wird slot-shared (s.u.): `rpi-persistent-shared-init` pusht bei jedem Boot die DWC-Dateien des aktiven Slots per Checksum nach `/persistent/shared/opt/dsf/sd/www` – gewollt, damit OTA und Rollback jeweils ihre DWC-Version ausliefern; von Plugins hinzugefügte Dateien liegen nicht im Image und bleiben erhalten (kein `--delete`).
  2c. **Vigil vorinstallieren** (Nachbau der DSF-Installationslogik im Chroot, da DCS beim Bauen nicht läuft): Release-Zip laden (s. Versionspinning, Abbruch bei fehlendem Asset), sha256 prüfen, `plugin.json` im Zip gegen `vigil_version` (`"version": "1.3.0-beta.1"`) und `dwcVersion`/`sbcDsfVersion` (`"3.7"`) gegen die DSF-Generation prüfen, entpacken. Zip-Layout (verifiziert): `plugin.json`, `dsf/<dsfFiles>` (flach, kein Architektur-Unterordner, reines Python), `dwc/js/*.js(.map)`, `dwc/css/*.css` (Liste in `dwcFiles`), `rrfFiles: []`. `plugin.json` → `/usr/share/meltingplot/dsf-skel/plugins/Vigil.json`; `dsf/*` → `.../plugins/Vigil/dsf/` (`vigil-daemon.py` 0770); die in `dwcFiles` gelisteten Dateien → `/opt/dsf/sd/www/<pfad>` (image-owned, wird gepusht); venv am **endgültigen Pfad** `/opt/dsf/plugins/Vigil/venv` anlegen (`python3 -m venv`, `pip install dsf-python==${dsf_python_version}`; venv enthält absolute Pfade), danach nach `.../dsf-skel/plugins/Vigil/venv` verschieben; alles `dsf:dsf`. `mp-dsf-seed` installiert bzw. **aktualisiert** das Plugin auf `/opt/dsf/plugins/`, wenn dort kein `Vigil.json` liegt oder dessen `version` vom Skelett abweicht (Plugin-Dateien werden bewusst nicht jeden Boot gepusht, weil DSF im Manifest `data` schreibt). Autostart: `plugins.txt` im Skelett enthält `Vigil`. DWC-Seite: `enabledPlugins: ["Vigil"]` in einer geseedeten `sd/sys/dwc-settings.json` (prüfen, ob DWC 3.7 die Liste dort erwartet). Vigil-Daten: `/opt/dsf/sd/Vigil` wird slot-shared, liegt nicht im Image → Betriebsstundenzähler überleben OTA und Rollback.
  3. `config.json` (DCS, gehört uns): `PluginSupport: true`, `RootPluginSupport: false`, `DisablePluginInstallations: false`; `GpioChipDevice`/`TransferReadyPin 25`/`SpiDevice /dev/spidev0.0` Default belassen, auf Hardware prüfen. `plugins.json` (DuetPluginService, gehört uns): `DisableAppArmor: true` (DSF könnte seine Per-Plugin-Profile nicht nach `/etc/apparmor.d` schreiben), `PreinstallPackageCommand`/`InstallPackageCommand`/`InstallLocalPackageCommand`/`InstallPythonPackageCommand` auf `/bin/false` (Plugins mit Paketabhängigkeiten scheitern bei der Installation).
- **Plugin-Policy** (User-Vorgabe: nachträglich nur reine DWC-Plugins; von Meltingplot ausgelieferte SBC-Plugins wie Vigil laufen): DSF kennt keinen DWC-only-Modus; jede Installation läuft über DuetPluginService (dsf- und root-Instanz), DWC-Dateien werden nach `/opt/dsf/sd/www` kopiert, SBC-Dateien nach `/opt/dsf/plugins/<id>/dsf`; Python-Plugins startet die dsf-Instanz via `/bin/bash -c "<plugindir>/venv/bin/python <exe>"`. Da AppArmor weder Bash- noch Python-Argumente filtern kann, wird über **Leserechte** eingeschränkt. Umsetzung:
  - **AppArmor-Profilkette** in `/etc/apparmor.d/opt.dsf.bin.DuetPluginService` (enforce, gilt für beide Instanzen, da gleiches Binary): (1) `DuetPluginService`: Lesen `/opt/dsf/**`, `/usr/lib/**`, `/etc/**`; Schreiben `/opt/dsf/plugins/**`, `/opt/dsf/sd/**`, `/opt/dsf/conf/plugins.txt`; Unix-Socket `/run/dsf/**`; einzige `x`-Regel: `/bin/bash Cx -> dsf_launcher`. (2) Kindprofil `dsf_launcher` (bash): einzige `x`-Regel `/usr/bin/python3* Cx -> dsf_plugin_py`, sonst nichts. (3) Kindprofil `dsf_plugin_py`: Lesen nur `/usr/lib/python3*/**`, `/opt/dsf/plugins/Vigil/**` (pro freigegebenem Plugin ein Eintrag, aus dem Layer generiert), rw `/opt/dsf/sd/Vigil/**`, Socket `/run/dsf/dcs.sock`, r `/proc/**`, `/sys/class/thermal/**`, `/sys/class/hwmon/**` (Vitals), **keine `x`-Regel**, `deny /opt/dsf/plugins/** r` für alles Übrige. Ergebnis: Vigil läuft; ein nachträglich installiertes SBC-Plugin kann sein eigenes Skript nicht lesen bzw. sein Binary nicht ausführen und startet nie (Denial in `journalctl -k`); DWC-only-Plugins funktionieren. Voraussetzung: `lsm=apparmor` (mp-duet-hw) und `apparmor.service` (lädt die Profile aus dem Image).
  - **systemd-Härtung** als zweite Schicht per Drop-in für `duetpluginservice.service` und `duetpluginservice-root.service`: `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ReadWritePaths=/opt/dsf/plugins /opt/dsf/sd /opt/dsf/conf`, `NoExecPaths=/opt/dsf/sd /persistent /home /tmp /var` (nicht `/opt/dsf/plugins`, dort liegt Vigils venv-Python-Symlink).
  - Fallback, falls der DSF-Installationspfad auf dem Immutable Root nicht sauber läuft: `DisablePluginInstallations: true`; Vigil und gewünschte DWC-Plugins kommen dann ausschließlich per OTA ins Image.
- Overlay:
  - `slot-shared.d/dsf.conf`: `Version=1` + `Path=/opt/dsf/sd/sys`, `/opt/dsf/sd/gcodes`, `/opt/dsf/sd/macros`, `/opt/dsf/sd/filaments`, `/opt/dsf/sd/menu`, `/opt/dsf/sd/www`, `/opt/dsf/sd/Vigil`, `/opt/dsf/plugins`, `/opt/dsf/conf` (bewusst nicht `firmware`, damit ein Rollback die zum Slot passende Firmware flasht). Im Image liegende Dateien unter shared Pfaden sind ausschließlich solche, die wir besitzen und die bei jedem Boot gepusht werden sollen: `conf/config.json`, `conf/plugins.json`, `sd/www/**` (DWC), `sd/{sys,macros,filaments}/**` aus chx350-config abzüglich `protected.list`. Geschützte und maschinenlokal erzeugte Dateien liegen nicht im Image und bleiben Nutzerzustand. Da der Push kein `--delete` macht, bleiben aus dem Repo entfernte Dateien auf dem Gerät liegen – bei Bedarf eine `obsolete.list` im Layer pflegen, die `mp-dsf-seed` löscht.
  - `mp-dsf-seed.service` (Type=oneshot, After=`local-fs.target persistent-shared-init.service mp-identity.service mp-hostname.service`, Before=`duetcontrolserver.service duetwebserver.service duetpluginservice.service`, WantedBy=`sysinit.target`, da DCS an `sysinit.target` hängt): `/usr/sbin/mp-dsf-seed` = `cp -an /usr/share/meltingplot/dsf-skel/sd/. /opt/dsf/sd/` und `cp -an .../conf/. /opt/dsf/conf/` (no-clobber) + `chown -R dsf:dsf`. Zusätzlich: fehlt `sys/meltingplot/printer-name.g`, wird es mit `M550 P"<PRINTER_NAME aus mp-identity, sonst meltingplot-chx-350-<serial>-sbc>"` angelegt – das ist der **Anzeigename** (Objektmodell `network.name`, DWC-Titelzeile, PanelDue) und zugleich die Quelle des Linux-Hostnamens (s. Kopplung unten). Da `mp-dsf-seed` nach `mp-hostname` läuft, setzt `mp-hostname` beim allerersten Boot den Hostnamen direkt aus `mp-identity` (`PRINTER_NAME` bzw. Default) – dieselbe Ableitung, damit Hostname und `M550` schon beim ersten Start übereinstimmen. Ersetzt DuetPis `replace-dsf-configs` und den Git-Sync des `MeltingplotConfig`-Plugins, überschreibt nie.
  - **Kundenspezifischer Druckername – Kopplung an den Hostnamen:** DCS prüft bei `M550`, dass Buchstaben und Ziffern des Namens mit dem Linux-Hostnamen übereinstimmen (`Environment.MachineName`, Fehler „Machine name must consist of the same letters and digits as configured by the Linux hostname“); DCS setzt den Hostnamen nicht selbst. Der DWC-Anzeigename ist deshalb immer der Hostname bis auf Satzzeichen/Leerzeichen. Konsequenz: `printer-name.g` (geschützt, überlebt OTA/Rollback) ist die **einzige Quelle** für beides. `mp-hostname` liest beim Boot aus dem persistenten Pfad `/persistent/shared/opt/dsf/sd/sys/meltingplot/printer-name.g` den `M550 P"…"`-Wert, leitet den Hostnamen ab (Nicht-Alphanumerisches → `-`, Mehrfach-`-` zusammenfassen, Ränder trimmen, Kleinschreibung – der DCS-Vergleich ist `CurrentCultureIgnoreCase` –, ≥ 1 Buchstabe/Ziffer; DCS begrenzt den `M550`-Namen auf 40 Zeichen, das Makro validiert ASCII-Buchstaben/Ziffern/Leerzeichen/`-` und ≤ 40 Zeichen) und setzt ihn; anschließend führt RRF `M550` mit dem Originaltext aus, der die DCS-Prüfung besteht. Fehlt die Datei, gilt der Default `M550 P"meltingplot-chx-350-<serial>-sbc"` (identisch zum Hostnamen-Schema). Drei Wege, den Namen zu setzen: (a) bei der Inbetriebnahme über `printer_name=` in `identity.conf`, (b) der Kunde bearbeitet die Datei in DWC (System → `sys/meltingplot/printer-name.g`; wirksam nach Reboot, bis dahin meldet `M550` den Fehler – das Makro vermeidet das), (c) Makro `macros/meltingplot/maintenance/set-printer-name` (M291-Texteingabe, schreibt die Datei per `echo >`, meldet „Neustart erforderlich“ und bietet `M999`/Reboot an). Ein Kunde mit zehn Druckern sieht damit in DWC, Browser-Tab und PanelDue seine eigenen Namen. Entscheidung (User): Der SBC sitzt nicht kundenseitig im Netz (eigenes VLAN hinter dem HMI), sein Hostname ist für den Kunden reine DWC-Anzeige und daher **frei wählbar**; der Hostname ist **nicht** mehr die Meltingplot-Identität; die Seriennummer steht in `/persistent/common/etc/mp-identity`, in `release.json`-/Vigil-Auswertungen und in Raspberry Pi Connect als Tag/Beschreibung (`chx-350-<serial>`, bei der Registrierung per API oder im Dashboard gesetzt). Der **Connect-Gerätename bleibt fest** `meltingplot-chx-350-<serial>-sbc` bzw. `-hmi`: er wird beim Anlegen des Auth-Keys bzw. der Geräteidentität als `device_name` gesetzt (plus Tag `chx-350-<serial>`) und folgt späteren Hostnamen-Änderungen nicht. Support-Weg per Connect-Shell/SSH: `sudo mp-set-printer-name "Halle 2 links"` (Skript in `mp-identity`, schreibt `printer-name.g` in den persistenten Pfad, setzt den Hostnamen sofort transient und weist auf den nötigen DCS-Neustart hin). Ein direktes `hostnamectl set-hostname` funktioniert nicht, weil `/etc/hostname` auf dem Read-only-Root liegt; `hostnamectl --transient` wäre nur bis zum Reboot wirksam. Voraussetzung in `chx350-config` (Branch 3.7, kleine Änderung): `dsf-config.g` ruft nach `dsf-config-override.g` per `if fileexists(...)`/`M98` die Datei `printer-name.g` auf, und `dsf-config-override.g` verliert die `M550`-Zeile mit dem `xxx`-Platzhalter. Der Linux-Hostname, der Connect-Gerätename und `<hostname>.local` bleiben davon unberührt (Flottenidentität); in Connect kann Meltingplot bei Bedarf zusätzlich den Anzeigenamen des Geräts pflegen.
  - `duetcontrolserver.service.d/mp.conf`: `[Unit] After=mp-dsf-seed.service opt-dsf-sd-sys.mount opt-dsf-conf.mount` (DCS hat upstream kein `After=`).
  - `/etc/avahi/services/duet3.service` (aus DuetPi `02-mdns`).
- `hooks/postbuild50-dsf-assert`: Build bricht ab, wenn unter einem shared Pfad reguläre Dateien außer `conf/config.json`, `conf/plugins.json`, `sd/www/**` und den chx350-config-Dateien liegen (insbesondere nichts unter `/opt/dsf/plugins`), eine Datei aus `protected.list` noch unter `/opt/dsf/sd` liegt, `/opt/dsf/sd/sys/config.g`, `/opt/dsf/sd/www/index.html` oder `dsf-skel/plugins/Vigil.json` fehlt, `dsf-skel/plugins/Vigil/venv/bin/python` nicht auf `/usr/bin/python3*` zeigt, `dsf`-UID ≠ 992, `dtparam=spi=on` oder `lsm=apparmor` fehlt, oder das AppArmor-Profil eine `x`-Regel enthält.
- Konsequenzen (dokumentieren): Firmware-Upload per DWC funktioniert nicht (`/opt/dsf/sd/firmware` liegt im EROFS); `M997` bzw. `DuetControlServer -u` flashen aus genau diesem Verzeichnis und sind der Weg, den `mp-dsf-firmware` nutzt. Updates kommen als OTA-Bundle. Nachträglich installierte SBC-Plugins werden nie ausgeführt, DWC-Plugins und das mitgelieferte Vigil funktionieren. DWC-Settings, Heightmaps etc. liegen unter `sd/sys` → persistent.

## Inbetriebnahme eines Druckers (Phase 1: SD/NVMe per Imager)

Befund: Connect-Deployments und Auth-Keys sind pro Gerät; beim IDP-Provisioning über rpi-sb-provisioner gibt es keine Hooks, die in Partitionen schreiben (`bootfs-mounted`/`rootfs-mounted` existieren dort nicht, nur `post-flash` auf dem Host mit Serial/MAC/Image-SHA). Deshalb trägt die BOOTCONFIG-Partition (`/bootfs`, 32 MB FAT, rw, enthält sonst nur `autoboot.txt`) die gerätespezifischen Daten, und der erste Boot übernimmt sie (Layer `mp-identity`).

Ablauf (README-Kapitel „Inbetriebnahme“):
1. Release-Asset `mp-duet-pi5-<ver>.img.zst` laden, SHA256 gegen `SHA256SUMS` prüfen.
2. Auf SD oder NVMe (USB-Adapter) schreiben: Raspberry Pi Imager („Use custom“, `.zst`-Support prüfen) oder `zstdcat … | sudo dd of=/dev/sdX bs=4M conv=fsync`. Keine Imager-OS-Anpassungen verwenden (zielen auf RPi-OS-`firstrun.sh`, hier wirkungslos).
3. Erste Partition `BOOTCONFIG` mounten, `meltingplot/identity.conf` aus der Vorlage anlegen: `printer_serial`, optional `printer_name` (Kundenwunsch, wird DWC-Name und Hostname), optional `connect_authkey` (Organisations-Key aus dem Connect-Dashboard bzw. `POST /organisation/auth-keys` mit `device_name=meltingplot-chx-350-<serial>-sbc` und `tags: ["chx-350-<serial>", "sbc"]`, `ttl_days` kurz). Die Seriennummer als Connect-Tag ist die Flottenidentität, unabhängig vom späteren Hostnamen.
4. Medium in den Pi5 am Duet, Duet-Board und HMI-Netz (10.42.0.1) verbunden, einschalten. Erster Boot: `machine-id-sync` → `mp-identity` (Hostname, Auth-Key) → `mp-hostname` → `mp-growfs` → `persistent-shared-init` → `mp-dsf-seed` (Vigil, `M550` mit Serial) → DCS. Anmeldung bei Connect erfolgt automatisch, das Gerät erscheint als `meltingplot-chx-350-<serial>-sbc`.
5. Abnahme: DWC unter `http://10.42.0.2/`, `M115`/`M122`, Connect-Remote-Shell, Vigil-Dashboard; Ergebnis im Inbetriebnahmeprotokoll (Serial, Pi-Serial, Image-Version, Datum) festhalten.

Rollen: die Rolle ist im Image fest (`sbc` im Duet-Image, `hmi` im HMI-Image), die Identity-Datei ist für beide gleich (nur `printer_serial`, optional `connect_authkey`); Hostname `meltingplot-chx-350-<serial>-hmi` beim HMI.
Später (Phase 1b, Secure Boot): rpi-sb-provisioner (`RPI_DEVICE_FAMILY=5`, `RPI_DEVICE_STORAGE_TYPE=sd|nvme`, IDP-Archiv als `GOLD_MASTER_OS_FILE`, `RPI_CONNECT_API_KEY` für die automatische Geräteidentität) ersetzt Schritte 2–3; `expand-to-fit` übernimmt die Vergrößerung, `mp-growfs` erkennt das (Marker) und tut nichts. Die Identity-Datei kann dann im `post-flash`-Hook nicht mehr geschrieben werden → `printer_serial` entweder über `RPI_CONNECT_DESCRIPTION`/`device_name` in Connect pflegen oder die Datei nachträglich per Connect-Shell anlegen (vor dem ersten Boot mit Identität, da eine vergebene Seriennummer nicht überschrieben wird).

## OTA-Prozess und Release-Pipeline

### Versionierung und Artefakte
- Quelle der Wahrheit: Git-Tag `duet-pi5/v<X.Y.Z>` im öffentlichen Fork; CI setzt `IGconf_artefact_version=<X.Y.Z>` und `SOURCE_DATE_EPOCH` = Commit-Zeit des Tags. `image.name` bleibt `mp-duet-pi5`; Dateien werden beim Release mit Version umbenannt.
- Deploy-Verzeichnis (`work/deploy-<ver>/`, aus [layer/base/deploy-base.d/hooks/](layer/base/deploy-base.d/hooks/) und [image.d/hooks/deploy05-update](image/gpt/ab_userdata/image.d/hooks/deploy05-update)): `mp-duet-pi5.img.zst`, `mp-duet-pi5.update.tar.zst` (Bundle: tar mit `boot` + `system` als Android-Sparse, ohne Manifest/Signatur), `mp-duet-pi5.idp.tar.zst`, `filesystem-<ver>.sbom.zst` (SPDX-JSON, syft), `manifest.zst` (Paketliste), `config.yaml.zst`, `deployed.json` (nur SHA-1).
- Eigener Deploy-Hook `meltingplot/hooks/deploy20-mp-release` (Quellbaum-Hooks laufen nach den Layer-Hooks, vor `deploy99-manifest`): schreibt `release.json` mit Version, Image-Name, Commit des Forks, Commit des chx350-config-Submodules, DSF/RRF/DWC-Versionen (aus `manifest`), Vigil- und dsf-python-Version, `SOURCE_DATE_EPOCH`, sowie `SHA256SUMS` über alle Artefakte. Optional `SHA256SUMS.minisig` (minisign, Schlüssel als GitHub-Secret) als Herkunftsnachweis – Connect selbst prüft nur SHA-256.
- Release-Assets (alle < 2 GiB): `mp-duet-pi5-<ver>.update.tar.zst`, `-<ver>.img.zst`, `-<ver>.idp.tar.zst`, `-<ver>.sbom.spdx.json.zst`, `-<ver>.manifest.zst`, `release.json`, `deployed.json`, `SHA256SUMS(.minisig)`. Release-Notes aus `RELEASE.md`/Tag-Message mit Änderungen an DSF-Version und chx350-config.

### CI (`.github/workflows/meltingplot-duet-pi5.yml`)
- Trigger: Push auf `meltingplot`-Branch und PRs (voller Build ohne Release, damit fehlende Release-Assets oder Pin-Fehler früh auffallen), Tag `duet-pi5/v*` (Build + Release; Tags mit Vorab-Suffix erzeugen ein GitHub-Pre-Release), `workflow_dispatch`.
- Runner `ubuntu-24.04-arm` (wie [.github/workflows/build.yml](.github/workflows/build.yml); für öffentliche Repos kostenlos). Schritte: `actions/checkout` mit `submodules: recursive`; `sudo chmod o+x /home/runner`; `sudo ./install_deps.sh`; `./test/run-all.sh` (Metadaten-/Layer-Lint) ; `actions/cache` für `meltingplot/.cache/apt` (Key: Hash der Layer-Dateien + Datum) und `work/<gnutype>` (Host-Tools inkl. syft); Build:
  ```
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) ./rpi-image-gen build -S ./meltingplot -c duet-pi5.yaml -B "$RUNNER_TEMP/work" \
    -- IGconf_artefact_version="$VER" IGconf_sys_apt_cachedir="$PWD/meltingplot/.cache/apt"
  ```
  Danach Artefakte umbenennen, `SHA256SUMS` prüfen, bei Tag `gh release create duet-pi5/v$VER --verify-tag --notes-file …` mit allen Assets; auf Branch/PR nur `actions/upload-artifact` (Retention 14 Tage).
- Keine Secrets im Build nötig (SSH-Public-Keys sind committet); optional `MINISIGN_KEY` für die Signatur. Concurrency-Gruppe pro Ref, Timeout 120 min.
- Reproduzierbarkeit: Pins (DSF, Vigil, dsf-python, Submodule) + `SOURCE_DATE_EPOCH` + Debian-Mirror nicht gepinnt → Debian-Pakete können zwischen zwei Builds derselben Version abweichen; für Auditzwecke ist die SBOM des jeweiligen Builds maßgeblich. Härtere Reproduzierbarkeit später über `debian-trixie-arm64-minbase-snapshot` (snapshot.debian.org).

### Rollout über Raspberry Pi Connect (Organisations-Account)
1. Artefakt registrieren (Dashboard → Remote update): Name `mp-duet-pi5 <ver>` (muss eindeutig sein), URI `https://github.com/Meltingplot/rpi-image-gen/releases/download/duet-pi5%2Fv<ver>/mp-duet-pi5-<ver>.update.tar.zst`, SHA-256 aus `SHA256SUMS`. Artefakte sind nach dem ersten Deploy nicht mehr löschbar (Nachvollziehbarkeit).
2. Deployment **pro Gerät** (Devices → Deploy; es gibt derzeit weder API noch Gruppen-Rollouts, nur ein anstehendes Deployment je Gerät). Gestufter Rollout organisatorisch: erst Labor-Drucker, dann Pilotkunden, dann Rest; Tags im Dashboard zur Kennzeichnung (`duet`, `pilot`, `prod`).
3. Gerät (Stand 2026-09-11, aus `rpi-connect-ota` 1.3.14 ermittelt): `rpi-connectd` meldet das Deployment per D-Bus an den Root-Dienst `rpi-ota-connector`, der das Bundle streamend nach `/dev/disk/by-slot/other/{boot,system}` schreibt. Mit dem Paket-Default `AutoReboot=true` folgt sofort `reboot '0 tryboot'`; unser Layer `mp-connect` setzt `AutoReboot=false` in `/etc/rpi-connect/rpi-ota-connector.config`, dann wartet der Connector auf die D-Bus-Methode `Reboot` (`com.raspberrypi.ota`, nur root). `mp-ota-gate.timer` (Layer `mp-dsf`, minütlich) liest `/bootfs/ota_state`, fragt per `CodeConsole -c 'M409 K"state.status"'` den Druckerzustand ab und ruft `Reboot` nur bei `idle`. Nach dem Boot in den neuen Slot erkennt der Connector den Tryboot (Device-Tree `/chosen/bootloader/tryboot`, Zustandsdatei) und committet mit `AutoCommit=true` sofort per `rpi-slot-tryboot > /bootfs/autoboot.txt`. Der „Health-Check“ ist damit nur: Linux kam bis zum Start des Connectors. Tryboot selbst erkennt nichts, es ist ein einmaliges Bootloader-Flag; ohne neu geschriebene `autoboot.txt` startet der nächste Reset den alten Slot. Ein Hänger ohne Panic bleibt hängen (kein Hardware-Watchdog konfiguriert), erst ein Stromzyklus bringt Slot A zurück.
4. Voraussetzung auf dem Gerät: `RPI_CONNECT_EXPERIMENTAL_OTA=t` (Layer) bzw. `rpi-connect ota on`; Zustände im Dashboard: Pending → In Progress (auch während das Gate wartet) → Succeeded/Failed; Logs `journalctl -t rpi-ota-connector -t mp-ota-gate -t mp-dsf-firmware`.
5. Timing für Drucker: Der Neustart wird technisch durch `mp-ota-gate` zurückgehalten, solange RRF nicht `idle` meldet (Druck, Pause, Abbruch, Update, oder DCS nicht erreichbar). Organisatorisch bleibt „Labor zuerst, dann Piloten“. **Im Labor zu verifizieren:** (a) `cat /bootfs/ota_state` während ein Deployment bei laufendem Druck wartet – erwartet eine Zeile `state=…WAIT` oder `…PROMPT`, sonst Muster in `mp_ota_restart_pending` anpassen; (b) `busctl introspect com.raspberrypi.ota /com/raspberrypi/ota` zeigt `Reboot` ohne Argumente, sonst Aufruf in `mp-ota-gate` anpassen; (c) nach Druckende startet die Maschine binnen einer Minute neu, Journal `mp-ota-gate`; (d) `getcap /opt/dsf/bin/DuetControlServer` zeigt die File-Capabilities aus dem Postinst (sonst behandelt DCS `-u` als externes Programm, was für M997 reicht, aber protokolliert werden soll).
6. Firmware: `mp-dsf-firmware.service` (Layer `mp-dsf`, jeder Boot, nach `duetcontrolserver` und `rpi-connect-ota`) wartet bis zu fünf Minuten, bis `autoboot.txt` den laufenden Slot als Default nennt (Vergleich mit `rpi-slot-tryboot`), dann bis RRF `idle` meldet, und ruft `DuetControlServer -u` auf. Jeder Slot flasht so seine eigene Firmware, auch nach einem Rollback (Vergleich ist „ungleich“, nicht „neuer“). Der Flash liegt zeitlich nach dem Commit; ein abgebrochener Flash wird vom Bootloader nicht zurückgenommen.
7. **TODO (nach dem Laborlauf, nicht vorher):** `AutoCommit=false` und eigener Commit erst nach erfolgreichem Firmware-Flash: `mp-dsf-firmware` ruft nach `DuetControlServer -u` und `M115`-Kontrolle die D-Bus-Methode `Commit` auf `com.raspberrypi.ota`, bei Fehlschlag `Rollback`. Damit respektiert der Tryboot die Firmware wirklich. Hängt an undokumentiertem Verhalten des Connectors (Zustände `TRYBOOTED`/`COMMITWAIT`, Verhalten bei Stromausfall vor dem Commit: Slot A würde dann mit neuer Firmware starten und sie per eigenem `mp-dsf-firmware` zurückflashen, was den Mechanismus symmetrisch hält). Erst umsetzen, wenn (a) bis (d) aus Punkt 5 bestätigt sind.

### Rollback
- Automatisch: Bootloader-Tryboot fällt bei Boot-Fehler (Panic → `kernel.panic=1` → Reset) auf `[all] boot_partition` zurück. Einen eigenen Health-Check hat rpi-connect-ota nicht; es committet, sobald es nach dem Boot läuft (unser Bundle trägt keine `checkboot`-Scripts).
- Manuell per Connect: vorheriges Artefakt erneut deployen (Artefakte bleiben registriert). Der Neustart wartet auch dabei auf `idle`.
- Manuell per Shell: `rpi-slot-tryboot > /bootfs/autoboot.txt` und `reboot '0 tryboot'` (Wechsel in den anderen Slot; Commit durch erneutes Schreiben nach erfolgreichem Boot). `/persistent` bleibt bei beidem unangetastet; Konfigurationsdateien werden beim Boot vom dann aktiven Slot gepusht (ältere DWC/Config zurück), geschützte Dateien bleiben. Die Firmware folgt beim nächsten Boot nach dem Commit oder sofort mit `systemctl start mp-dsf-firmware`.

### Nachweise (Maschinenverordnung)
Je Release unveränderlich im GitHub-Release: SBOM, `release.json`, `deployed.json`, `SHA256SUMS(.minisig)`, Build-Log (Workflow-Run), Tag. Je Gerät: Connect-Deployment-Historie plus Inbetriebnahmeprotokoll. Damit ist für jeden Drucker jederzeit belegbar, welcher Softwarestand (inkl. RRF-Firmware und CHX350-Konfiguration) wann ausgerollt wurde.

## Vorbereitung Secure Boot / weitere Ziele (nur Notizen)

- IDP bleibt aktiv (Default bei `hw:device:rpi`); Deploy liefert `<name>.idp.tar.zst` für rpi-sb-provisioner. Secure Boot später: `image.pmap: cryptdata` (LUKS auf `/persistent`, Hardware-Key via `rpifwcrypto`, [builtin/hooks/customize50-cryptroot](builtin/hooks/customize50-cryptroot)), Signierung von boot.img/EEPROM durch den Provisioner; `lock_device_private_key=1` ist im config.txt-Template bereits gesetzt. NVMe-Provisionierung: Variante mit `trait: { hw:storage:nvme: true }` + `storage_type: nvme`.
- SBOM (syft, `sbom-base`) pro Build archivieren – Nachweis für die Maschinenverordnung.
- HMI (Phase 2): `mp-base.yaml` teilen; Ziel-Config `hmi-pi5.yaml` mit eigenen App-Layern (GUI, NetworkManager/WLAN + NAT/DNS/NTP für 10.42.0.0/24, `motion` mit Kameramodul via libcamera/`camera_auto_detect=1`, Stream-Verteilung). `mp-net-static` entfällt dort. `system_part_size` beim HMI deutlich größer (GUI-Stack).

## Erster Durchstich – was fehlt (Stand 2026-09-10)

Ziel des Durchstichs: lokaler Build → SD flashen → Pi5 bootet, DSF spricht mit dem Duet-Board, DWC erreichbar, Connect angemeldet.

**Harte Blocker**
1. **Build-Umgebung WSL2** (Ubuntu 24.04, systemd läuft, 864 GB frei): keines der Build-Werkzeuge ist installiert (`podman`, `mmdebstrap`, `qemu-user-static`, `zstd`; binfmt für aarch64 nicht registriert). Nötig: `sudo apt-get install binfmt-support qemu-user-static debian-archive-keyring`, `sudo update-binfmts --enable qemu-aarch64`, `sudo ./install_deps.sh`, rootless-podman prüfen (`/etc/subuid`, `podman unshare true`). Erster Smoke-Test: `./rpi-image-gen build -c config/trixie-minbase-ab.yaml` (unverändertes Upstream-Beispiel).
2. **Vigil für DWC 3.7**: erledigt – Pre-Release `v1.3.0-beta.1` (2026-09-10) mit `Vigil-1.3.0-beta.1-dwc37.zip`, SHA-256 `acc7e7c1…ca32`, ist gepinnt (Pre-Releases sind für RC-Images erlaubt, s. Release-Gate).
3. **`dsf-python` für DSF 3.7**: Pin `3.7.0b1` (einzige 3.7-Version auf PyPI); Kompatibilität mit DSF `3.7.0~rc.1` im Labor prüfen.
4. **Implementierung** selbst: alle Layer, Configs, Overlays, Hooks aus diesem Plan (Schritte 1–5 unten), inkl. Klärung der Chroot-Unbekannten (`/opt/dsf/sd/www`-Symlink, DSF-Postinst, 3.7-Schema von `config.json`/`plugins.json`).

**Eingaben, die nur du liefern kannst**
5. SSH-Public-Keys der Admins für `keys/authorized_keys` (ohne Key kein Zugang, Konto hat kein Passwort).
6. Raspberry-Pi-Connect-Konto: für Labor reicht ein persönlicher Auth-Key (`rpuak_…`, 6 h gültig); für die Serie ein Organisations-Account (`rpoak_…`, API-Token).
7. Labornetz: der Duet-Pi erwartet Gateway/DNS/NTP 10.42.0.1 mit Internet (für Connect). Ohne HMI-Pi entweder einen Laborrouter auf 10.42.0.1 legen oder für den Durchstich `mpnet.*` per CLI (`-- IGconf_mpnet_address=… IGconf_mpnet_gateway=…`) auf das vorhandene Netz setzen.
8. Hardware: Pi5, SD ≥ 16 GB (Connect-OTA-Mindestgröße), Duet-3-Board am SBC-Ribbon. Board-Firmware wird von `mp-dsf-firmware` beim ersten Boot auf 3.7.0-rc.1 gebracht (Slot A ist ab Werk committet); `chx350-config` ist auf RRF 3.6.1 geschrieben – Fehler in `config.g` unter 3.7 sind möglich, blockieren den Durchstich aber nicht.

**Nicht nötig für den Durchstich** (danach): öffentlicher Fork + CI + Release, OTA-Zyklus über Connect (braucht zwei Builds), `mp-growfs`-Feinschliff, Secure Boot, HMI.

## Umsetzungsschritte

0. Diesen Plan als `docs/meltingplot-duet-pi5-plan.md` ins Repo übernehmen und auf einem neuen Branch `meltingplot` committen (Master bleibt Upstream-Stand).
1. `meltingplot/`-Baum, `.gitignore` (`secrets/`), Key + avahi-Service aus dem DuetPi-Klon übernehmen; Submodule `meltingplot/chx350-config` (Branch `3.7`) anlegen und Commit pinnen.
2. Layer `mp-suite-trixie`, `mp-net-static`, `mp-connect`, `mp-identity` (+ Overlay mit Identity-/Hostname-/Growfs-Units und Skripten, `identity.conf.example`).
3. Layer `mp-duet-hw`, `mp-dsf` (+ `mp-dsf.d/` mit apt, skel, Overlay, Postbuild-Assert).
4. Configs `mp-base.yaml`, `duet-pi5.yaml`; Deploy-Hook `hooks/deploy20-mp-release`; Validierung ohne Build: `./rpi-image-gen layer --describe mp-dsf`, `./rpi-image-gen metadata --lint`, `./rpi-image-gen config -S ./meltingplot -c duet-pi5.yaml`.
5. Lokaler Build (WSL2), Flash per Imager + Identity-Datei, Gerätetests (unten).
6. CI-Workflow `.github/workflows/meltingplot-duet-pi5.yml`, erster Tag `duet-pi5/v0.1.0-rc.1` → GitHub-Pre-Release (Release-Gate erlaubt Vorabversionen); Artefakt in Connect registrieren, OTA-Zyklus im Labor. Finale Tags ohne Suffix erst, wenn DSF 3.7.0, Vigil und dsf-python final sind.
7. README mit Build-, Inbetriebnahme-, OTA- und Rollback-Ablauf; Inbetriebnahmeprotokoll-Vorlage.

## Verifikation

Build (WSL2/x86: `install_deps.sh`, binfmt/qemu-user-static, podman; vgl. [getting_started.adoc](getting_started.adoc)):
```
./rpi-image-gen build -S ./meltingplot -c duet-pi5.yaml            # lokal: artefact.version = 0.0.0-dev.<Zeitstempel>
./rpi-image-gen build -S ./meltingplot -c duet-pi5.yaml -- IGconf_artefact_version=0.1.0-rc.1
```
Für den Durchstich ohne HMI-Netz zusätzlich `-- IGconf_mpnet_address=… IGconf_mpnet_gateway=… IGconf_mpnet_dns=… IGconf_mpnet_ntp=…` auf das Labornetz setzen. Erwartete Artefakte im Deploy-Verzeichnis: `mp-duet-pi5.img.zst`, `mp-duet-pi5.update.tar.zst`, `mp-duet-pi5.idp.tar.zst`, SBOM, Manifest, `release.json`, `SHA256SUMS`. Build-Zeit: Postbuild-Assert grün, Größe von `system.erofs` vs. `system_part_size` prüfen. Gegenprobe Release-Gate: `-- IGconf_artefact_version=0.1.0` muss mit Auflistung der Vorab-Pins abbrechen; ein absichtlich falscher `vigil_sha256` ebenfalls.

Auf dem Gerät (Pi5 an Duet3, erst SD, dann derselbe Image-Stand auf NVMe):
- `findmnt / /boot/firmware /persistent /opt/dsf/sd/sys`: `/` erofs ro aus `/dev/disk/by-slot/active/system`, `sd/sys` bind aus `/persistent/shared/...`; `journalctl -u persistent-shared-init -u mp-dsf-seed`; `ls -ln /opt/dsf/sd/sys` → UID/GID 992, `config.g` vorhanden; `/opt/dsf/sd/firmware/Duet3Firmware_*.bin` vorhanden.
- `ls -l /dev/spidev0.0 /dev/gpiochip0` (Gruppe gpio, 0660), `cat /sys/module/spidev/parameters/bufsiz` = 8192 (falls spidev built-in: `spidev.bufsiz=8192` in cmdline).
- `systemctl status duetcontrolserver duetwebserver`; `journalctl -u duetcontrolserver` zeigt „Connection to Duet established“; DWC über `http://10.42.0.2/` und `http://<hostname>.local/`; `M115` liefert Board-Version; `journalctl -u mp-dsf-firmware` zeigt den Vergleich und ggf. den Flash („All boards are up-to-date!“ oder „Updating firmware on mainboard…“).
- Zugang: `ssh meltingplot@10.42.0.2` nur mit Key; Passwort-Login per SSH abgelehnt (`PasswordAuthentication no`), lokaler Login am Konto gesperrt (`passwd -S meltingplot` → `L`), `sudo -n true` funktioniert ohne Passwort.
- `ip a`: nur eth0 mit 10.42.0.2, kein wlan0; `resolvectl status` DNS 10.42.0.1; `timedatectl` synchron; `rfkill list` leer.
- Inbetriebnahme: mit `identity.conf` (`printer_serial=042`, `connect_authkey=rpoak_…`) auf BOOTCONFIG booten → `hostname` = `meltingplot-chx-350-042-sbc`, `/persistent/common/etc/mp-identity` vorhanden, `identity.conf` enthält keinen Key mehr, `rpi-connect status` als `meltingplot` → signed in (`loginctl show-user meltingplot` Linger=yes), Gerät erscheint im Dashboard als `meltingplot-chx-350-042-sbc`, Remote-Shell funktioniert. Ohne Datei: Hostname `meltingplot-unprovisioned-<Pi-Serial>-sbc`, kein Sign-in. `lsblk`/`df -h /persistent` zeigt nach dem ersten Boot die volle Mediengröße (`mp-growfs`), `sgdisk -v` ohne Warnungen; auf 32-GB-SD und auf NVMe.
- Persistenz-Regressionstest: `sys/meltingplot/global-override.g` und `filaments/PETG/config-override.g` in DWC editieren, G-Code hochladen, Nozzle-Durchmesser setzen (`nozzle0.g`), zweimal rebooten → alles bleibt erhalten. Gegenprobe: `sys/config.g` in DWC editieren, rebooten → Änderung ist zurückgesetzt (image-owned). `printer-name.g` enthält nach dem ersten Boot `M550 P"meltingplot-chx-350-042-sbc"`, DWC zeigt diesen Namen, `M550` liefert keinen Fehler im Journal von DCS. Name per Makro auf „Halle 2 links“ setzen, rebooten → `hostname` = `halle-2-links`, DWC-Titel „Halle 2 links“, kein DCS-Fehler; dasselbe per `sudo mp-set-printer-name` über die Connect-Shell; Gerät heißt in Connect weiterhin `meltingplot-chx-350-042-sbc` und trägt Tag `chx-350-042`; OTA-Slotwechsel und Rollback → Name bleibt. Gegenprobe: `M550 P"anderer Name"` in der Konsole → DCS-Fehlermeldung wie erwartet. Board bootet mit der CHX350-Konfiguration durch (`M122`, keine Fehler aus `config.g`, `daemon.g` läuft).
- DWC-Auslieferung: `findmnt /opt/dsf/sd/www` ist bind aus `/persistent/shared/...`, DWC lädt im Browser mit der 3.7-Version; nach OTA auf eine neue DWC-Version zeigt der Browser die neue Version, nach Rollback wieder die alte.
- Vigil: nach dem ersten Boot `ls /opt/dsf/plugins` zeigt `Vigil.json`, `Vigil/`; `journalctl -u duetpluginservice` ohne Traceback; `ps -o user,label,cmd -C python3` zeigt den Daemon als `dsf` unter Profil `dsf_plugin_py`; DWC → Plugins → Vigil ist gestartet, Dashboard zeigt Zähler; `/opt/dsf/sd/Vigil/vigil_data.json` wächst; nach OTA/Rollback bleiben die Zähler erhalten. Upgrade-Test: zweites Image mit höherer `vigil_version` → nach Boot ist die neue Version aktiv, Daten unverändert.
- Plugin-Policy: `aa-status` zeigt `DuetPluginService`, `dsf_launcher`, `dsf_plugin_py` im Enforce-Modus; ein DWC-only-Plugin-Zip über DWC installieren → erscheint in DWC, Dateien unter `/opt/dsf/sd/www`; ein fremdes SBC-Plugin (z.B. MeltingplotConfig-Zip, Python) installieren → Start schlägt fehl, `journalctl -k` zeigt `apparmor="DENIED"` (`open` auf `/opt/dsf/plugins/MeltingplotConfig/...` bzw. `exec`); ein Plugin mit Paketabhängigkeiten → Installation schlägt fehl. Nach Reboot in den anderen Slot bleibt das DWC-Plugin erhalten.
- OTA: zweiten Build mit neuer `artefact.version` erzeugen; erst manuell: `system.sparse`/`boot.sparse` per `simg2img`/`dd` auf `/dev/disk/by-slot/other/{system,boot}`, `rpi-slot-tryboot > /bootfs/autoboot.txt`, `reboot '0 tryboot'` → `readlink /dev/disk/by-slot/active/system` zeigt den anderen Slot, DSF verbunden, `/persistent/shared/opt/dsf` unverändert; Rollback durch Reboot ohne Commit prüfen. Danach über Raspberry Pi Connect: Artefakt aus dem GitHub-Release registrieren (URL + SHA-256 aus `SHA256SUMS`), pro Gerät deployen, Zustand Pending → Succeeded, `journalctl -t rpi-ota-connector`, aktiver Slot gewechselt, `/bootfs/autoboot.txt` committet; danach Rollback-Test durch Deploy des vorherigen Artefakts. Dabei per `dpkg -L rpi-connect-ota` und Journal die Health-/Commit-Logik dokumentieren.
- Pipeline: Tag `duet-pi5/v0.1.0-rc.1` → Workflow grün, GitHub-Pre-Release mit allen Assets, `release.json` enthält DSF `3.7.0~rc.1`, Vigil `1.3.0-beta.1`, chx350-config-Commit; Bundle-URL aus dem Release ist ohne Anmeldung abrufbar und die SHA-256 stimmt mit `SHA256SUMS`. Ein Tag ohne Suffix (`duet-pi5/v0.1.0`) schlägt am Release-Gate fehl, solange Vorab-Pins gesetzt sind.

## Risiken / beim Umsetzen klären

- DSF-Postinst unter mmdebstrap (`systemctl start`, `udevadm trigger`, `chown -R /opt/dsf/conf`) – im Build-Log prüfen; Fallback: Installation in einem customize-hook.
- `useradd` im `essential-hook` verfügbar (passwd ist Essential) – sonst `usermod -u 992` + `chown -R` im customize-hook vor der Skelett-Verschiebung.
- gpiochip-Nummerierung auf Pi5 mit Trixie-6.12-Kernel (`gpiochip0` = RP1; bei 6.6 war es `gpiochip4`) – mit `gpioinfo` prüfen, `GpioChipDevice` in `config.json` ggf. anpassen (Datei gehört uns, per OTA korrigierbar).
- .NET (`duetruntime`) auf dem 16K-Page-Size-Kernel `rpi-2712` – sollte laufen; Fallback v8-Kernel (siehe [examples/slim](examples/slim/)).
- 3.7 ist Release Candidate: Plugin-/Config-Schema (`config.json`, `plugins.json`) und die oben aus dem `master`-Quellcode zitierten Settings gegen die installierten Dateien im Chroot abgleichen; beim 3.7.0-Final `dsf_version`/`dsf_suite` umstellen und OTA-Bundle neu bauen.
- Apt mit `Architectures: arm64` gegen ein Repo ohne `binary-armhf` in einer multi-arch-Basis – prüfen, dass apt nicht meckert; sonst `debian-trixie-arm64` (nicht multi) verwenden.
- Auth-Key-Semantik (ein Gerät, Ablauf) und das „experimental“ Commit/Rollback-Verhalten von rpi-connect-ota – manuellen tryboot-Zyklus zuerst testen.
- avahi neben systemd-resolved: mDNS in resolved ist per Link standardmäßig aus, kein Port-5353-Konflikt – verifizieren.
- Vigil: `dsf-python==3.7.0b1` ist Beta; wenn Vigils Daemon damit gegen DSF 3.7.0~rc.1 Fehler zeigt, bleibt nur Warten auf ein neueres PyPI-Release (kein Fork/Patch im Image). DWC-seitige Aktivierung (`enabledPlugins`) auf dem Gerät verifizieren; notfalls einmal manuell „Start“ in DWC und die resultierende `dwc-settings.json` ins Skelett übernehmen.
- AppArmor auf dem `rpi-2712`-Kernel: `lsm=apparmor` muss greifen (`cat /sys/kernel/security/lsm`); das Profil darf DuetPluginService selbst nicht behindern (Socket-Zugriff, Zip-Entpacken); Denials im Labor mit `aa-complain` einsammeln, dann `enforce`.
- Wie `duetsd`/`duetwebcontrol` `/opt/dsf/sd/www` anlegen (Symlink auf `/opt/dsf/dwc`, echtes Verzeichnis oder gar nicht) war aus den Build-Skripten nicht ersichtlich – im ersten Chroot mit `ls -la /opt/dsf/sd` prüfen; der Hook 2b muss alle drei Fälle abdecken.
- DCS ruft beim Installieren beide PluginService-Instanzen; prüfen, dass die root-Instanz mit `DisableAppArmor: true` und totgelegtem apt für DWC-only-Plugins fehlerfrei durchläuft.
- `mp-growfs`: `growpart` auf GPT mit verschobenem Backup-Header – Reihenfolge `sgdisk -e` → `growpart` → `resize2fs` online im Labor auf SD und NVMe prüfen; bei Problemen alternativ `parted ---pretend-input-tty resizepart`.
- Raspberry Pi Imager: `.zst`-Support für „Use custom“ prüfen; sonst `zstdcat | dd`. Die Imager-eigenen Anpassungen (Hostname, WLAN, SSH) dürfen nicht genutzt werden.
- rpi-connect-ota: Ablauf, Zustände und D-Bus-Schnittstelle sind aus den Binaries von 1.3.14 rekonstruiert (siehe Rollout, Punkte 3 bis 7), nicht dokumentiert; die dort genannten Prüfungen (a) bis (d) vor dem ersten Kundenrollout im Labor abarbeiten. Das Format von `_contents_.yaml` ist in `raspberrypi/utils` (otamaker) dokumentiert; der Schlüssel `reboot_prompt` im artefact-Block ist ein Text für das Dashboard, kein Script-Hook auf dem Gerät, deshalb liegt das Reboot-Gate im Image und nicht im Bundle. Deployments nur pro Gerät und ohne API → Rollout-Aufwand skaliert linear mit der Flotte; Management-API auf Deployment-Endpunkte beobachten.
- Öffentliches Repo: Review-Regel, dass nie Auth-Keys, private Schlüssel oder Kundendaten committet werden (`secrets/` bleibt gitignored, `keys/` enthält nur Public Keys); Secret-Scanning in GitHub aktivieren.
- `libnss-myhostname`/`/etc/hosts`: prüfen, dass `sudo` und DSF ohne `127.0.1.1`-Eintrag keine Auflösungsverzögerung zeigen; sonst `/etc/hosts` über `mp-hostname` nach `/run` rendern und per Bind-Mount überlagern.
