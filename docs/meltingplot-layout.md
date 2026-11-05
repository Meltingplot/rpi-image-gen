# Speicherlayout der Drucker-Pis: Reserve und Regeln für Änderungen

Stand 2026-11-05, Entwurf zur Abstimmung mit Tim. Gilt für beide Images (`duet-pi5.yaml`, `hmi-pi5.yaml`), die sich das Layout über `mp-base.yaml` teilen.

## Anlass

Jede Änderung am Layout hat bisher einen Besuch mit der Installerkarte gebraucht, weil ein Update das Partitionslayout eines Geräts nicht ändert:

- gen1 → gen2: Systemslots von 1G (Duet-Pi) bzw. 2G (HMI) auf 4G (PR #111).
- gen2 → gen3: neue Partition `audit` mit 512 MiB (PR #123). Ausgeliefert leer, genutzt erst per OTA in Phase 2 des Audit-Logs.

Der Bench-Test von HMI rc.12 am 2026-11-04 hat dazu gezeigt, dass auch das Dateisystem einer Partition beim Build festgelegt wird: Upstream formatiert jede ext4-Datenpartition mit `-b <Seitengröße>`, auf dem Pi 5 also mit 16-KiB-Blöcken. Das Journal wächst damit auf 64 MiB, von den 512 MiB der Audit-Partition sind nur 440 MiB nutzbar.

Weitere Änderungen werden kommen. Daraus folgt ein Layout, das spätere Änderungen ohne Kartenbesuch zulässt.

## Festlegungen (Tim, 2026-11-05)

1. Das Layout bekommt eine Reserve, gedacht für spätere Änderungen.
2. Die Reserve liegt zwischen `audit` und `persistent`, ungefähr 8 bis 16 GB.
3. Sie wird leer ausgeliefert und erst per OTA genutzt, wie die Audit-Partition in Phase 1 und 2.
4. Zielmedium ist immer eine SSD mit mindestens 128 GB, in der Regel 256 GB. SD-Karten sind kein Zielmedium; die Karte im Labordrucker wird ersetzt.
5. Mit gen4 wächst `audit` von 512 MiB auf 1 GiB, damit eigenes Log und Kopie des Partners sicher Platz haben.
6. Die Installerkarte bleibt bei ihrem bisherigen Weg (`zstd -dc | dd`) und lässt `audit` und `reserve` aus (Option a nach dem Bench-Test vom 2026-11-05, siehe LY-10). Aus dem IDP installiert erst das Provisionieren mit `rpi-sb-provisioner` über USB, etwa für Secure Boot.

## Layout gen4

Am Beispiel der 256-GB-SSD des Bench-HMI (238,5 GiB):

| Nr. | Name | Größe | Inhalt bei Auslieferung | heute belegt |
|---|---|---|---|---|
| 1 | `bootconfig` | 32 MiB | FAT, `autoboot.txt`, `identity.conf`, `installer.txt` | – |
| 2, 3 | `boot_a`, `boot_b` | je 128 MiB | FAT mit `boot.img` | 49 MiB (38 %) |
| 4, 5 | `system_a`, `system_b` | je 4 GiB | erofs | 0,45 GB Duet-Pi, 0,7 GB HMI |
| 6 | `audit` | 1 GiB | **kein Dateisystem** | – |
| 7 | `reserve` | 16 GiB | **kein Dateisystem, nie eingehängt** | – |
| 8 | `persistent` | Rest | ext4, wächst beim ersten Boot bis zum Plattenende | 254 MB |

Gegenüber gen3 neu sind `reserve`, das rohe `audit` und seine Größe von 1 GiB statt 512 MiB. `persistent` wird damit Partition 8 statt 7 und bleibt die letzte Partition: `mp-growfs` und `expand-to-fit` beim Provisionieren bleiben unverändert.

16 GiB sind 12,5 % einer 128-GB-SSD und 6,7 % einer 256-GB-SSD. Begründung der Größe unter LY-03.

## Regeln

- **LY-01** Die Reserve ist eine Partition namens `reserve` ohne Dateisystem. Sie wird nie eingehängt; ihr Inhalt ist undefiniert. Weder Installer noch Image schreiben Daten hinein.
- **LY-02** Nur ein Update nimmt sich Platz aus der Reserve, nie ein Mensch von Hand. Es verkleinert den GPT-Eintrag `reserve` und legt die neue Partition daneben an, oder es lässt `audit` direkt in die Reserve hineinwachsen. Das geht im laufenden Betrieb, weil die Reserve nie eingehängt ist (`sgdisk`, `partx`). Jeder solche Schritt
  - ändert nur Partitionen, die nicht eingehängt sind,
  - lässt sich nach einem Stromausfall an jeder Stelle wieder aufnehmen und ist wiederholbar,
  - schreibt die neue Generation fort (LY-05) und einen Eintrag ins Audit-Log.
- **LY-03** Wofür die Reserve reicht, mit 16 GiB:
  - neue Partitionen, wie `audit` in gen3;
  - `audit` vergrößern, ohne Umkopieren, weil es direkt davor liegt;
  - beide Systemslots verdoppeln, mit 8 GiB: `system_b` neu in der Reserve, umschalten, dann `system_a` über die alte Fläche von A und B;
  - `persistent` verschlüsseln (LUKS, Upstream-Layout `cryptdata`): Inhalt in eine neue verschlüsselte Partition in der Reserve kopieren, das alte `persistent` löschen, die neue Partition über dessen Fläche bis zum Plattenende vergrößern. Das geht, weil beide nebeneinander liegen, und ohne Verkleinern eines Dateisystems.
- **LY-04** Partitionen, die erst später genutzt werden, werden ohne Dateisystem ausgeliefert. Der Dienst, der sie nutzt, formatiert sie selbst, mit den Vorgaben des Geräts. Für `audit` tut `mp-auditd` das schon (AL-37); auf dem Pi 5 entstehen dann 4-KiB-Blöcke und ein 16-MiB-Journal. Nutzbar sind dann 973 MiB von 1 GiB (gemessen mit `mkfs.ext4 -b 4096`; zum Vergleich 487 MiB bei 512 MiB).
- **LY-05** Die Generation steht ausdrücklich auf dem Gerät: `meltingplot/layout.txt` auf `bootconfig` mit `layout=gen4`. Der Installer schreibt sie, jede spätere Änderung nach LY-02 schreibt sie fort. Erkennen über Partitionsgrößen bleibt nur für gen1 bis gen3.
- **LY-06** Geplant wird nach Nutzfläche, nicht nach Partitionsgröße. Der Build prüft für jede Partition mit festem Zweck, dass ihr Dateisystem fasst, was geplant ist. Für `audit`: Die Anteile des eigenen Logs und die Kopie des Partners (AL-07, AL-40) passen in ein Dateisystem, wie es das Gerät anlegt. Sonst bricht der Build ab.
- **LY-07** Ein Update muss zum Layout passen. `mp-bundle-guard` verweigert ein Bundle, dessen Boot- oder Systemabbild nicht in die Slots des Geräts passt oder das eine neuere Generation verlangt, als das Gerät hat.
- **LY-08** Der Installer schreibt nur auf eine SSD mit mindestens 120 000 000 000 Bytes (eine 128-GB-SSD hat etwas mehr) und bricht sonst ab.
- **LY-09** Notweg, wenn die Reserve einmal nicht reicht: `persistent` als letzte Partition von hinten verkleinern, offline in der Boot-Ramdisk (`resize2fs`, dann `sgdisk`). Das ist riskant, weil ein Stromausfall während `resize2fs` das Dateisystem beschädigen kann. Daher nur beschrieben, nicht gebaut.

## Installation mit der Karte

Die Karte schreibt das Image mit `zstd -dc | dd`. Bisher lässt sie nur `audit` aus, wenn sie gen3 übernimmt.

- **LY-10** Ab gen4 schreibt die Karte die Reserve nie. Sie überspringt sie im Datenstrom, statt 16 GiB Nullen zu schreiben, und verwirft sie danach auf der SSD (`blkdiscard`), damit nichts von einem früheren Layout darin lesbar bleibt. `audit` lässt sie auf einem gen4-Laufwerk ebenso aus, wenn es dort liegt, wo das Image es hat; so behält jede Neuinstallation das Audit-Log (AL-18). Auf gen1 bis gen3 schreibt sie `audit` neu: Das Image hat dort Nullen, und `mp-auditd` formatiert die Partition beim ersten Start. Geprüft wird über die geschriebenen Bereiche. Die Lage der Bereiche misst der Build aus der Partitionstabelle des Images (`mp-installer-measure`, Variablen `mpinst.keep_part` und `mpinst.skip_parts`).

  Liegt die Reserve auf einem gen4-Laufwerk nicht dort, wo das Image sie hat, wurde das Layout im Feld nach LY-02 schon weiterentwickelt. Die Karte schreibt dann nicht: Sie würde Partitionen überschreiben, die sie nicht kennt.

### Warum nicht aus dem IDP

Geprüft am 2026-11-05 am Bench-HMI, das dafür von einer USB-SSD mit Raspberry Pi OS Lite lief, mit der eigenen NVMe als Ziel.

Jedes Release enthält ein IDP-Archiv (`<image>.idp.tar.zst`): die Layoutbeschreibung (PMAP) und je Partition ein Abbild im Android-Sparse-Format. `rpi-sb-provisioner` installiert damit über `rpi-fastbootd` auf dem Gerät. Auf der Karte müsste `rpi-fastbootd` lokal laufen, also im TCP-Modus (`fastbootd -i tcp`).

- Das Paket installiert und startet sich unter trixie, und `oem idpinit` erkennt das richtige Ziel.
- Den Ablauf durchziehen lässt es sich so aber nicht. Jede TCP-Verbindung bekommt in `rpi-fastbootd` ein frisches Gerätobjekt ohne Zustand: TCP ist dort die Datenebene, den Zustand hält nur die USB-Steuerverbindung. Und der `fastboot`-Client schickt pro Aufruf nur einen OEM-Befehl. `oem idpwrite` kommt so nie bei einem initialisierten Gerät an.
- `bin/idp.sh` und `rpi-idp-provisioner.sh` setzen beide die USB-Steuerverbindung von einem zweiten Rechner voraus. Ein eigener Client, der eine Verbindung offen hält, wäre ein Nachbau.

Raspberry Pi Imager ist ebenfalls kein Ersatz: Er schreibt das ganze entpackte Image, und auf der Karte ohne Bildschirm wäre er als Qt-Anwendung eine schwere Abhängigkeit.

### Für das spätere Provisionieren aus dem IDP

Was der Test und der Quelltext von `rpi-fastbootd` dafür ergeben haben:

- Das Ziel legt die Beschreibung fest: `rpi-fastbootd` beschreibt nur `/dev/mmcblk0` (Speichertyp `sd` oder `emmc`) oder `/dev/nvme0n1` (Typ `nvme`), gewählt über `IGconf_device_storage_type` (`idpstorage.h`). gen4 setzt deshalb `device.storage_type: nvme`; bisher steht dort `sd`, das im Image nur in die Beschreibung eingeht. Eine SSD am USB ist kein Ziel.
- Jede Partition braucht in der Beschreibung ein Sparse-Abbild und wird geflasht. `audit` und `reserve` brauchen eines, das nur aus „Don't care“ besteht: Solche Abschnitte überspringt `rpi-fastbootd` per `lseek`, ohne zu schreiben oder zu löschen (`flashing.cpp`).
- `rpi-idp-provisioner.sh` löscht den Datenträger vorab mit `fastboot erase`. Eine Neuprovisionierung verliert damit das Audit-Log; dort gilt die Übergabe nach AL-64 ff.
- `rpi-fastbootd` braucht kein Secure Boot: Die Gerätesperre ist fest aus, den Geräteschlüssel im OTP verlangt `oem idpinit` nur für verschlüsselte Container. Mit Secure Boot müssen die Boot-Slots signiert ins IDP; das kann der Build über `bootsign_cmd`.
- `rpi-fastbootd` gibt es nicht im apt-Archiv von Raspberry Pi. Der Provisioner bringt es in seinem Fastboot-Gadget mit, das per `rpiboot` über USB im RAM startet; gebaut wird das Gadget mit `pi-gen-micro`, das Paket liegt dort fertig im Repository (`internal/packages/rpi-fastbootd_14.0.0~git20261026.adf29cb_arm64.deb`). Es ist mit `libcryptsetup` (GPL-2+) gelinkt und damit GPLv3, obwohl seine `copyright`-Datei nur Apache-2.0 nennt. Das ist kein Hindernis: Das Image soll ohnehin nicht geschlossen sein (Tim, 2026-11-05).
- Im TCP-Modus lauscht `rpi-fastbootd` ohne Anmeldung auf allen Schnittstellen (`*:5554`).

## Übergang

Die Laborgeräte ziehen erst mit gen4 um, nicht vorher noch einmal auf gen3; der Labor-Duet-Pi bleibt bis dahin auf der SD-Karte (Tim, 2026-11-05).

Alle Bestandsgeräte gehen nach Festlegung 20 des Audit-Logs ohnehin noch einmal über die Installerkarte. gen4 kommt in diesen Durchgang; einen weiteren gibt es dafür nicht.

- gen1, gen2: werden komplett neu geschrieben.
- gen3 (nur das Bench-HMI): `audit` hat in gen4 eine andere Größe und wird neu angelegt; auf dem Bench-HMI liegt nur ein Testlog. `persistent` rückt nach hinten und wird neu geschrieben.
- Ab gen4 übernimmt jede Neuinstallation `audit` (AL-18), solange das Layout gleich bleibt.
- Für die Laborgeräte bleibt es beim Sichern und Zurückspielen von `/persistent` von Hand.

## Größe von `audit`

LY-06 verlangt, dass das eigene Log (256 MiB nach AL-40) und die Kopie des Partners (noch einmal 256 MiB, AL-07) in das Dateisystem passen. Mit 512 MiB und 487 MiB Nutzfläche ging das nicht. Mit 1 GiB (Festlegung 5) sind 973 MiB nutzbar: Die Anteile bleiben wie entworfen, und etwa 460 MiB bleiben für Archive nach einem Löschen nach AL-17.

## Prüfpunkte

Erledigt am 2026-11-05:

1. genimage: Eine Partition ohne Abbild ist dort ein Loch. Die IDP-Beschreibung, die jeder Build gegen ihr Schema prüft, verlangt aber für jede Partition ein Abbild mit Typ und Sparse-Fassung. `audit` und `reserve` bekommen deshalb je eine Datei ihrer Größe, die nur aus einem Loch besteht (`truncate`), als genimage-Abbild vom Typ `file`: im `.img` ein Loch, im Sparse-Abbild „Don't care“. Das ist zugleich, was das spätere Provisionieren aus dem IDP braucht.
2. Die Nummer von `persistent` (7 → 8): Nichts hängt an ihr. `/dev/disk/by-slot` geht über GPT-Namen, `mp-growfs` liest die Nummer aus sysfs, der statische Rückfall `rpi-slot-static` kennt nur Boot- und Systemslots und greift nur mit `/boot/slot.map`.

Erledigt durch den Bench-Test vom 2026-11-05: ob `oem idpwrite` den Inhalt von `audit` stehen lässt und ob `rpi-fastbootd` im TCP-Modus auf der Karte taugt. Beides ist mit Option a hinfällig; die Befunde stehen unter „Für das spätere Provisionieren aus dem IDP“.

Erst beim Provisionieren aus dem IDP oder beim ersten Umzug eines Slots in die Reserve zu klären, für gen4 nicht nötig (Tim, 2026-11-05):

- PMAP und `rpi-sb-provisioner` mit den „Don't care“-Abbildern für `audit` und `reserve`.
- Wie der Connect-Updater den Zielslot findet: über Namen oder Nummern.
- Ob der Bootloader des Pi 5 Boot-Partitionen mit höheren Nummern annimmt (`autoboot.txt`). Heute sind die Boot-Slots zu 38 % belegt. Fehlen auf der ersten Partition `autoboot.txt` und `config.txt`, sucht er selbst die nächste startbare FAT-Partition („Partition walk“, im Test beobachtet).

## Umsetzung

1. Layout, allgemein für Upstream wie `private_part` (`image/gpt/ab_userdata`): `image.reserve_part_size` für die Reserve (leer = keine) und `image.private_part_fs: none` für eine private Partition ohne Dateisystem. `mp-base.yaml` setzt 16G, `audit` roh mit 1G und `device.storage_type: nvme`.
2. `layout.txt` kommt mit der Schicht `mp-layout` ins Image, auf `bootconfig` (LY-05). Ein Update lässt diese Partition, wie sie ist.
3. Installerkarte: Reserve nie schreiben und verwerfen, `audit` auf gen4 behalten, gen4 erkennen, im Feld veränderte Layouts nicht schreiben (LY-10), Mindestgröße 120 000 000 000 Bytes (LY-08, `mpinst.min_drive_bytes`).
4. Build-Prüfung der Nutzfläche (LY-06): Hook `customize90-audit-capacity` der Schicht `mp-audit` legt das Dateisystem so an, wie `mp-auditd` es tun wird, und vergleicht es mit `auditcore.SHARES` mal zwei.
5. Offen: `mp-bundle-guard` mit Layoutprüfung (LY-07), kann nach gen4 kommen.
