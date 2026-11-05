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
6. Die Karte nutzt das `rpi-fastbootd`-Paket, das Raspberry Pi für den Provisioner baut, auch wenn es dadurch GPLv3 ist. Das Image soll ohnehin nicht geschlossen sein: Sein Quelltext liegt auf GitHub, und GPLv3-Programme wie `bash` und `coreutils` sind schon enthalten.

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

## Installation aus dem IDP

Die Installerkarte schreibt heute das ganze Image mit `zstd -dc | dd` und lässt nur `audit` aus, wenn sie gen3 übernimmt. Damit würde sie auch 16 GiB Nullen für die Reserve schreiben und beim Prüfen zurücklesen.

Jedes Release enthält schon das IDP-Archiv (`<image>.idp.tar.zst`, beim HMI 665 MB statt 1,3 GB für `.img.zst`). Es beschreibt das Layout (PMAP) und trägt je Partition ein Abbild im Android-Sparse-Format, das nur belegte Blöcke enthält. `rpi-sb-provisioner` installiert damit; Upstream nennt das ausdrücklich schneller als `dd` bei Abbildern mit viel Leerraum (`docs/provisioning/index.adoc`).

- **LY-10** Ab gen4 installiert die Karte aus dem IDP, mit der Software von Raspberry Pi und ohne eigenen Nachbau (Tim, 2026-11-05: so nah wie möglich an `rpi-sb-provisioner`):
  - Gerätseitig `rpi-fastbootd`, derselbe Dienst, den `rpi-sb-provisioner` in seinem Fastboot-Gadget auf das Gerät bringt. Auf der Karte läuft er lokal im TCP-Modus (`fastbootd -i tcp`, Port 5554, so dokumentiert).
  - Clientseitig der `fastboot`-Client aus Debian und `bin/idp.sh` aus rpi-image-gen gegen `tcp:127.0.0.1`: Beschreibung übergeben, `oem idpinit`, `oem idpwrite` (legt die Partitionstabelle an), je Partition `fastboot flash` mit dem Sparse-Abbild, `oem idpdone`. Das sind dieselben Schritte wie in `rpi-idp-provisioner.sh`.
  - `reserve` und `audit` haben kein Abbild und werden nicht beschrieben.
  - Eine Abweichung vom Provisioner: kein `fastboot erase` vorab. `rpi-idp-provisioner.sh` löscht damit den ganzen Datenträger; das Audit-Log ginge bei einer Neuinstallation verloren (AL-18). `bin/idp.sh` löscht nicht, und `oem idpwrite` legt nach dem Quelltext nur die Partitionstabelle neu an und hängt die Partitionen der Reihe nach an. Liegt `audit` an derselben Stelle, bleibt sein Inhalt erhalten.
  - Das Ziel legt die Beschreibung fest, nicht die Karte: `rpi-fastbootd` beschreibt nur `/dev/mmcblk0` (Speichertyp `sd` oder `emmc`) oder `/dev/nvme0n1` (Typ `nvme`), gewählt über `IGconf_device_storage_type` (Quelltext, `idpstorage.h`). gen4 setzt deshalb `device.storage_type: nvme`; bisher steht dort `sd`, das im Image nur in diese Beschreibung eingeht. Die Karte selbst läuft von `/dev/mmcblk0` und kann sich so nicht selbst überschreiben. Eine SSD am USB ist kein Ziel.
  - Unser eigener Teil bleibt die Bedienung der Karte: LEDs, Bildschirm, `identity.conf`, Bootloader-Update, Freigabe einer belegten SSD, `installer.txt`, `layout.txt`.

  Karte und späteres Secure-Boot-Provisioning nutzen damit dieselbe Layoutquelle und dieselbe Software auf dem Gerät.

`rpi-fastbootd` braucht kein Secure Boot (Quelltext und `rpi-sb-provisioner` 2.3.4, geprüft 2026-11-05): Die Gerätesperre ist fest aus (`GetDeviceLockStatus()` gibt `false` zurück). Den Geräteschlüssel im OTP verlangt `oem idpinit` nur für verschlüsselte Container, die gen4 nicht hat. Der Provisioner signiert Boot-Slots nur bei `PROVISIONING_STYLE=secure-boot`. Mit Secure Boot müssen die Boot-Slots signiert ins IDP; das kann der Build über `bootsign_cmd`.

Woher `rpi-fastbootd` kommt (geprüft 2026-11-05): Im apt-Archiv von Raspberry Pi gibt es kein eigenes Paket; `rpi-sb-provisioner` 2.3.4 und `librpifwcrypto0` sind dort. Der Provisioner installiert auch nichts auf dem Gerät. Er startet es per `rpiboot` über USB mit einem Fastboot-Gadget aus seinem Paket (`/var/lib/rpi-sb-provisioner/fastboot-gadget-pi5-family.img`), das im RAM läuft und `fastbootd -v -i usb+tcp` startet. Das Gadget baut Raspberry Pi mit `pi-gen-micro` (Konfiguration `fastboot`); `rpi-fastbootd` liegt dort als fertiges Paket im Repository: `internal/packages/rpi-fastbootd_14.0.0~git20261026.adf29cb_arm64.deb`.

Die Karte nimmt genau dieses Paket, gepinnt über Dateiname und sha256, ohne eigenen Build (Festlegung 6). Es ist mit `libcryptsetup` (GPL-2+) gelinkt; weil Apache 2.0 nur mit GPLv3 vereinbar ist, steht das Programm damit unter GPLv3. Seine `copyright`-Datei nennt trotzdem nur Apache-2.0. Im Lizenzhinweis steht es deshalb als GPLv3, und sein Quelltext (rpi-fastbootd, Commit adf29cb) kommt ins Quellarchiv des Releases. Die übrigen Abhängigkeiten kommen aus Debian (`android-libbase`, `android-libcutils`, `android-liblog`, `libcryptsetup12`) und aus dem Archiv von Raspberry Pi (`libblockdeviceid1`, `libflashrom1`, `raspi-utils-core`, `librpifwcrypto0`).

Raspberry Pi Imager ist dafür kein Ersatz: Er schreibt ebenfalls das ganze entpackte Image, und auf der Karte ohne Bildschirm wäre er als Qt-Anwendung eine schwere Abhängigkeit.

## Übergang

Die Laborgeräte ziehen erst mit gen4 um, nicht vorher noch einmal auf gen3; der Labor-Duet-Pi bleibt bis dahin auf der SD-Karte (Tim, 2026-11-05).

Alle Bestandsgeräte gehen nach Festlegung 20 des Audit-Logs ohnehin noch einmal über die Installerkarte. gen4 kommt in diesen Durchgang; einen weiteren gibt es dafür nicht.

- gen1, gen2: werden komplett neu geschrieben.
- gen3 (nur das Bench-HMI): `audit` hat in gen4 eine andere Größe und wird neu angelegt; auf dem Bench-HMI liegt nur ein Testlog. `persistent` rückt nach hinten und wird neu geschrieben.
- Ab gen4 übernimmt jede Neuinstallation `audit` (AL-18), solange das Layout gleich bleibt.
- Für die Laborgeräte bleibt es beim Sichern und Zurückspielen von `/persistent` von Hand.

## Größe von `audit`

LY-06 verlangt, dass das eigene Log (256 MiB nach AL-40) und die Kopie des Partners (noch einmal 256 MiB, AL-07) in das Dateisystem passen. Mit 512 MiB und 487 MiB Nutzfläche ging das nicht. Mit 1 GiB (Festlegung 5) sind 973 MiB nutzbar: Die Anteile bleiben wie entworfen, und etwa 460 MiB bleiben für Archive nach einem Löschen nach AL-17.

## Offene Prüfpunkte

1. genimage: eine Partition ohne Abbild (nur Größe) für `audit` und `reserve`, ohne dass das Image dadurch beschrieben wird.
2. PMAP und `rpi-sb-provisioner`: eine Partition ohne Abbild, Reihenfolge und Größen wie beschrieben.
3. Was an der Nummer von `persistent` hängt (7 → 8). `mp-growfs` liest sie aus sysfs, `/dev/disk/by-slot` geht über Namen.
4. IDP: eine Partition ohne Abbild in der Beschreibung (`reserve`, rohes `audit`), und dass `oem idpwrite` den Inhalt von `audit` an gleicher Stelle stehen lässt.
5. `rpi-fastbootd` im TCP-Modus auf der Karte, mit dem Image der Karte (trixie, `librpifwcrypto0` aus dem Archiv).

Punkte 4 und 5 sollten auf einer leeren USB-SSD am Bench-HMI laufen (Tim, 2026-11-05). Das geht nicht: `rpi-fastbootd` kann `/dev/sda` nicht ansprechen, und die Größe des Ziels liest es aus `/sys/block/<name>`, sodass auch ein umgelenkter Gerätename nicht hilft. Getestet wird deshalb wie im Feld: ein Pi 5, der von einer SD-Karte läuft, mit der leeren SSD im NVMe-Steckplatz.

Erst beim ersten Umzug eines Slots in die Reserve zu klären, für gen4 nicht nötig (Tim, 2026-11-05):

- Wie der Connect-Updater den Zielslot findet: über Namen oder Nummern.
- Ob der Bootloader des Pi 5 Boot-Partitionen mit höheren Nummern annimmt (`autoboot.txt`). Heute sind die Boot-Slots zu 38 % belegt.

## Umsetzung

1. Layout, allgemein für Upstream wie `private_part`: eine Variable für die Größe der Reserve (leer = keine) und eine Möglichkeit, die private Partition ohne Dateisystem auszuliefern. `mp-base.yaml` setzt 16G, `audit` roh mit 1G und `device.storage_type: nvme`.
2. `rpi-fastbootd`: das Paket aus `pi-gen-micro` pinnen (Dateiname, sha256) und im Lizenzhinweis als GPLv3 führen (LY-10, Festlegung 6).
3. Installerkarte: aus dem IDP (LY-10), gen4 erkennen, `layout.txt` schreiben (LY-05), Mindestgröße (LY-08).
4. Build-Prüfung der Nutzfläche (LY-06).
5. `mp-bundle-guard`: Layoutprüfung (LY-07), kann nach gen4 kommen.
