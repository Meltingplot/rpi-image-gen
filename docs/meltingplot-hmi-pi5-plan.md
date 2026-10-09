# Plan: Meltingplot A/B-Image „hmi-pi5“ (Phase 2) mit rpi-image-gen

## Kontext

Das HMI ist der Bedien-Pi am CHX350: ein Pi 5 mit Touchdisplay und Kamera. Er ist zugleich Router zwischen Kundennetz und Druckernetz und Proxy für DWC. Der Duet-Pi (Phase 1, [meltingplot-duet-pi5-plan.md](meltingplot-duet-pi5-plan.md)) sitzt im Druckernetz hinter ihm. Das HMI-Image entsteht als zweites Ziel im selben Projektbaum, gebaut mit `./rpi-image-gen build -S ./meltingplot -c hmi-pi5.yaml`. Es teilt `mp-base.yaml` und die Gerätelayer mit dem Duet-Pi.

Erprobt wird zuerst auf einem Dev-HMI am Bench: nur das HMI mit Display und Kamera, ohne Switch und ohne Duet-Pi, Boot von SD. Später folgt der volle Aufbau.

Das Labor-HMI (CHX350-002) wurde von Hand eingerichtet (bookworm, haproxy, motion, Chromium-Autostart). Es dient als Vorlage, wird aber nicht 1:1 übernommen.

## Entscheidungen (Tim, 2026-10-09)

| Thema | Entscheidung |
|---|---|
| Bildschirm | Chromium unter Wayland zeigt DWC über `http://10.42.0.1` (haproxy) in voller Bildschirmgröße. Die Bildschirmtastatur muss im Kiosk erscheinen. |
| Display | Waveshare 10,1″ DSI: `dtoverlay=vc4-kms-dsi-waveshare-panel,10_1_inch,dsi0` |
| Kamera | OV5647: `dtoverlay=ov5647`, ausgelesen und verteilt per motion |
| Netz | Ein Port. eth0 untagged = Kundennetz (Standard DHCP). VLAN 20 auf eth0 = Druckernetz 10.42.0.1/24 mit NAT, DHCP und DNS. Kunden-WLAN am Touchscreen wählbar. |
| Netz-Einstellungen | Schmale Pi-OS-Leiste mit Netzwerk, Tastatur und Uhr. Normalerweise ausgeblendet, eingeblendet per Wischgeste vom oberen Displayrand. Statische IP und WLAN werden dort eingestellt. |
| Connect | volles `rpi-connect` mit Bildschirmfreigabe |
| OTA | jederzeit im Packaged-Verhalten von Connect, ohne Gate. Der Druck läuft auf dem Duet-Pi weiter. |
| Root | `mpadmin` nur aus dem Druckernetz (VLAN 20), wie am Duet-Pi |
| Name im Kundennetz | Hostname und mDNS folgen dem Kundennamen aus `printer-name.g` des Duet-Pi |
| CORS | Regel auf allen HMI-Adressen, auch 10.42.0.1. Erlaubt sind nur die eigenen Origins des HMI. Der DWC-Dev-Server (`localhost:3000`) ist nicht erlaubt. |
| Strom | `usb_max_current_enable=1` im Image. `PSU_MAX_CURRENT=5000` setzt die Inbetriebnahme im EEPROM, zusammen mit dem Bootloader-Update. |
| Splash | eigenes Bild beim Boot, die Datei liefert Tim |
| Land und Tastatur | WLAN-Land DE und Tastaturlayout de als Standard, pro Gerät per `identity.conf` änderbar |
| Hostname | Kundenname mit Rollenendung, z. B. `halle-2-links-hmi` |
| Zeitzone | Standard Europe/Berlin, pro Gerät per `identity.conf` änderbar. Gilt auch für den Duet-Pi. |
| Ohne Duet-Pi | eigene Warteseite, die sich selbst neu lädt, bis DWC antwortet |

## Zielstruktur

Neu (●) und geändert (○) unter `meltingplot/`:

```
config/
  hmi-pi5.yaml                 ● Ziel, include mp-base.yaml, überschreibt layer.suite/connect/net/hw/app
layer/
  mp-suite-trixie-hmi.yaml     ● Suite ohne systemd-networkd und timesyncd, mit WLAN-Regulatory
  mp-hmi-net.yaml (+ .d/)      ● NetworkManager, VLAN-20-Profil, chrony als NTP-Server, Polkit/netdev
  mp-hmi-hw.yaml               ● config.txt: DSI-Panel, OV5647, usb_max_current_enable
  mp-hmi-proxy.yaml (+ .d/)    ● haproxy mit Backends und CORS-Liste
  mp-hmi-camera.yaml (+ .d/)   ● motion über v4l2-compat
  mp-hmi-kiosk.yaml (+ .d/)    ● labwc-Autologin, Chromium, squeekboard, wf-panel-pi, Geste, Splash
  mp-hmi-hostname (in .d/)     ● Kundenname vom Duet-Pi holen
  mp-connect.yaml              ○ RequiresProvider rpi-connect-client statt fest rpi-connect-lite
  mp-admin.yaml                ○ Prüfadresse aus dem Netz statt mpnet.gateway
.github/workflows/
  meltingplot-hmi-pi5.yml      ● CI, Tags hmi-pi5/v*
```

Warum eine eigene Suite: `systemd-net-min` und `network-manager` liefern beide `network-activator`. `systemd-timesyncd` und chrony liefern beide `time-daemon`. Ein NTP-Server für 10.42.0.0/24 braucht chrony, timesyncd ist nur Client.

## Netz (`mp-hmi-net`)

- **NetworkManager:** über den Upstream-Layer `network-manager`. Er legt `/etc/NetworkManager/system-connections` und `/var/lib/NetworkManager` schon slot-übergreifend auf `/persistent`, sodass Kundenprofile OTA und Rollback überstehen.
- **Kundennetz:** kein Profil im Image. NM legt für eth0 sein Standardprofil an (DHCP), Änderungen am Touchscreen landen in `/etc/NetworkManager/system-connections` und damit auf `/persistent`.
- **Achtung beim Ausliefern:** `rpi-persistent-shared-init` schiebt Dateien aus dem Image bei jedem Boot über abweichende Kopien. Ein im Image ausgeliefertes Kundenprofil würde jede Änderung beim nächsten Boot zurücksetzen.
- **Druckernetz:** Das Profil `vlan20` (eth0.20, `ipv4.method shared`, 10.42.0.1/24, `never-default`, IPv6 ignore) kommt aus dem Image. NM `shared` übernimmt DHCP und DNS (dnsmasq-base) sowie NAT.
  - Vorschlag: Das Profil liegt nach `/usr/lib/NetworkManager/system-connections` (read-only). Bei jedem Boot wird eine Kopie in `/etc` mit derselben UUID gelöscht, damit niemand das Druckernetz am Touchscreen verstellt.
  - Zu prüfen am Bench: ob NM 1.52 diesen Pfad liest, und welches Firewall-Backend `shared` nutzt (nftables).
- **NTP:** chrony mit `allow 10.42.0.0/24`. Quellen wie am Duet-Pi `ptbtime1-3.ptb.de`.
- **WLAN:** `wireless-regulatory` und wpasupplicant. Das Land muss voreingestellt sein, sonst ersetzt wfplug-netman auf 5-GHz-Hardware die WLAN-Liste durch „Click here to set Wi-Fi country“ (`raspi-config nonint get_wifi_country`). Standard ist DE, `identity.conf` kann es mit `wifi_country=` ändern. Zu klären: Wo raspi-config das Land auf einem read-only Root liest und setzt (cfg80211-Parameter in der cmdline oder `iw reg set` beim Boot).
- **Rechte:** Die Build-Prüfung von `mp-admin` verbietet dem Connect-Konto jede Gruppe außer `adm`, `sudo`, `users` und seiner eigenen, also auch `netdev`. Eine eigene Polkit-Regel (`50-mp-hmi-net.rules`) erlaubt diesem Konto deshalb NetworkManager-Aktionen nur aus einer lokalen, aktiven Sitzung, also der am Display. Aus der Connect-Shell und über SSH bleibt es verboten. Das ist am Bench zu prüfen.
  - Über die Bildschirmfreigabe kann der Support das Netz am Touchscreen ebenso einstellen. Das ist gewollt.

## Hardware (`mp-hmi-hw`)

config.txt-Zeilen per Layer, wie `mp-duet-hw`:
- `dtoverlay=vc4-kms-dsi-waveshare-panel,10_1_inch,dsi0`
- `dtoverlay=ov5647` mit `camera_auto_detect=0`
- `usb_max_current_enable=1`

**Display kopfüber (Tim, 2026-10-09):** Im CHX350 sitzt das Display um 180° gedreht. Das Image dreht alles mit: Bildschirm, Touch, Konsole und Splash. Die Splash-Vorlage im Repo bleibt aufrecht, die Drehung macht der Build. Am Bench ist zu prüfen, welche Stellen sich darum kümmern:
- **Overlay:** ob `vc4-kms-dsi-waveshare-panel` einen Parameter `rotation=180` hat. Er würde die DRM-Panel-Orientierung setzen, der fbcon folgt.
- **labwc:** dreht den Ausgang mit Transform 180, per kanshi oder `wlr-randr` im Autostart. wlroots wendet die Panel-Orientierung nicht von selbst an.
- **Touch:** `<touch mapToOutput="DSI-1"/>` in `rc.xml`, damit die Touch-Koordinaten der Drehung des Ausgangs folgen. Sonst die Invertierungsparameter des Overlays.
- **Kernel-Bootlogo:** Folgt es der Panel-Orientierung nicht, dreht der Build das TGA beim Umwandeln um 180°. Im Labor war das PNG deshalb von Hand gedreht.

`PSU_MAX_CURRENT=5000` gehört ins EEPROM und kommt in die Inbetriebnahme, in denselben Schritt wie das Bootloader-Update auf ≥ 2026-05-26 (Voraussetzung für Connect, siehe Duet-Plan).

## Kiosk (`mp-hmi-kiosk`)

Die Recherche vom 2026-10-09 stammt aus Quellen und Paketen, nichts davon ist auf Hardware getestet.

- **Sitzung:** labwc als Sitzung des Connect-Users `meltingplot`, gestartet von der systemd-Unit `mp-kiosk.service` auf tty1 mit `PAMName=login`. Das ergibt eine echte logind-Sitzung, lokal und aktiv am Seat. Die Bildschirmfreigabe braucht eine aktive grafische Sitzung desselben Users (`rpi-connect-wayvnc` startet nur bei vorhandenem `wayland-0/1` in dessen Runtime-Dir).
  - labwc liest seine Konfiguration per `-C /etc/meltingplot/labwc` aus dem Image. Im Home läge sie auf `/persistent`, und ein Update würde sie nie erneuern.
  - Upstream-`examples/webkiosk` nutzt cage. Das passt hier nicht, weil Panel und Tastatur Layer-Shell brauchen.
  - `contrib/cm5-programming-jig` nutzt den Pi-OS-Desktop (`rpd-wayland-core` mit lightdm). Das passt ebenfalls nicht: `rpd-common` zieht pcmanfm, lxterminal, pipewire, gvfs und NFS mit.
- **Warum kein echter Fullscreen:** labwc blendet den gesamten Layer-Shell-Top-Layer aus, sobald ein Fullscreen-Fenster oben liegt (`desktop_update_top_layer_visibility()`). Dort liegen squeekboard und wf-panel-pi im autohide. Mit `--kiosk` oder `--start-fullscreen` wird die Tastatur aktiviert, aber nie gezeichnet.
- **Start von Chromium:** `chromium --app=http://10.42.0.1 --start-maximized --noerrdialogs --hide-crash-restore-bubble`. Dazu eine labwc-windowRule: `serverDecoration="no"` plus Maximize. Chromium braucht die „System-Titelleiste“ (`browser.custom_chrome_frame=false`, wie `rpi-chromium-mods` sie setzt), sonst zeichnet es einen eigenen Rahmen.
  - Ungeprüft: die app_id der `--app`-Fenster.
  - squeekboard reserviert seine Höhe, labwc passt das maximierte Fenster an. Chromium rückt dadurch über die Tastatur.
- **Tastatur:** squeekboard (Pi-OS-Standard). Chromium ≥ 140 nutzt text-input-v3 ohne Flags. Das automatische Einblenden kommt über input-method-v2, eingeschaltet über die gschema-Einstellung `screen-keyboard-enabled=true`. Das Layout ist standardmäßig de, `identity.conf` kann es mit `keyboard=` ändern. Dasselbe gilt für `/etc/default/keyboard`, das rpi-connect liest.
- **Leiste:** wf-panel-pi in `~/.config/wf-panel-pi/wf-panel-pi.ini` (`[panel]`) mit `position=top`, `autohide=true`, `remainder=…` und `widgets_right=netman squeek clock`. Links bleibt sie leer, also ohne Menü und Starter.
  - Eine Wischgeste kennt weder labwc noch wf-panel-pi. Das Einblenden geht nur über ein GTK-Enter-Ereignis auf dem Reststreifen.
  - Kandidat A: Tippen auf den 5-px-Streifen. Ob die Leiste nach Touch-up wieder verschwindet, ist offen.
  - Kandidat B: `lisgd` (trixie main) erkennt einen Wisch von oben im 50-px-Band, fest einkompiliert. Ein Skript schaltet dann `autohide` in der ini um, und das Panel lädt sie bei Änderung neu. lisgd liest das evdev-Gerät und greift es nicht exklusiv: Chromium sieht den Wisch auch.
    - lisgd braucht die Gruppe `input`, die `mp-admin` dem Connect-Konto verbietet. Dafür bräuchte es einen eigenen Dienst-User.
  - Das erste Dev-Image nimmt Kandidat A (`/etc/xdg/wf-panel-pi/wf-panel-pi.ini`). B folgt nur, wenn A am Bench nicht reicht.
- **Netz-UI:** `wfplug-netman` (WLAN-Liste, Passwortdialog) und `lp-connection-editor` für statische IPv4. Beides sind GTK3-Dialoge, squeekboard sollte darin erscheinen.
- **Profil von Chromium:** Der Home liegt auf `/persistent`. Vorschlag: `--user-data-dir` unter `/run`, wie im Upstream-Beispiel. Das schont die SD und hinterlässt nach einem Absturz keinen Zustand. Verloren geht dabei nur der localStorage (Flow-Cache des CHX350), der sich selbst neu aufbaut.
- **Splash:** Upstream-Layer `rpi-splash-screen` statt eines eigenen Plymouth-Themes wie im Labor. Quelle ist `meltingplot/splash/hmi-splash.png` mit dem Scribus-Original `hmi-splash.sla`. Daraus wird `hmi-splash.tga` (24-bit, 1280x800, weniger als 224 Farben), gegebenenfalls um 180° gedreht, referenziert über `splash.image_path` in `hmi-pi5.yaml`. Der Layer legt das Bild in die initramfs und setzt die cmdline.
  - Der erste PNG-Export hatte 1024x768 und 1250 Farben, fast alles Kantenglättung um vier Grundfarben. Die 223 häufigsten decken 99,7 % der Pixel ab, das TGA ist also verlustarm möglich.
  - Tim exportiert die PNG aufrecht in 1280x800 neu aus Scribus.

## Kamera (`mp-hmi-camera`)

- **Version:** motion 4.7.0 (trixie) liest libcamera nicht direkt. Erst motion 5 und MotionPlus können `libcam_device`, beide gibt es für trixie nicht als Paket.
- **Weg:** motion liest V4L2 über das v4l2-compat von libcamera. Paket `libcamera-v4l2`, im Unit `LD_PRELOAD=/usr/libexec/aarch64-linux-gnu/libcamera/v4l2-compat.so`, ohne libcamerify und damit ohne Qt aus libcamera-tools. JPEG wird nur kodiert, solange jemand den Stream oder `/current` abruft.
  - Rückfallweg ist ein picamera2-MJPEG-Server als netcam, so wie das Labor-Gadget es macht (`capture_rate` dann über der Quell-fps).
- **motion.conf (Entwurf):** `video_device /dev/video0`, 1280x960 bei 15 fps. Das ist volles Bildfeld (2x2-Binning), 1296x972 ist nicht durch 8 teilbar. Dazu `pause on` (keine Bewegungserkennung), `picture_output off`, `movie_output off`, `stream_port 8081`, `stream_localhost on`, `stream_quality 75`, `stream_maxrate 15`, `webcontrol_port 0`, `log_file syslog`, `target_dir /run/motion`.
- **Unit:** Drop-in für Debians `motion.service` mit `Restart=always`, `RuntimeDirectory=motion` und Härtung.
  - Falle: Kann motion die Logdatei nicht öffnen, beendet es sich mit Exit 0 und startet nicht neu. Deshalb `log_file syslog`.
- **Zu prüfen am Bench:** ob `/dev/video0` die Kamera ist, und motion 4.7.0 mit v4l2-compat 0.7.2 auf dem Pi 5. Bestätigt ist bisher nur eine OV5647 an einem Pi 4.

## Proxy (`mp-hmi-proxy`)

haproxy auf :80, alle Adressen. Grundlage ist der optimierte Laborstand vom 2026-09-26:

| Pfad | Backend | Limits |
|---|---|---|
| `Upgrade: websocket` | Duet-Pi | ohne maxconn, `timeout tunnel 1h` |
| `/machine/code` | Duet-Pi | ohne maxconn, `timeout server 30m` (ein Makro hält die Anfrage, M112 darf nie warten) |
| übrige, bis 4 offen | Duet-Pi | `maxconn 4 maxqueue 2`, `timeout server/queue 10m` |
| übrige, ab 4 offen | Duet-Pi | `maxconn 10`, `timeout server 10s` |
| `/webcam` | motion 127.0.0.1:8081 | – |
| `/snapshot` | motion, Pfad → `/0/current` | – |

- **Nicht überliefert:** die genaue Bedingung fürs Ausweichen (Vorschlag `be_conn(backend_servers) ge 4`) und die `defaults`-Timeouts. Beides wird mit dem Labor-HMI abgeglichen.
- **CORS:** Für erlaubte Origins beantwortet haproxy die Preflights selbst (204) und setzt `Access-Control-Allow-Origin` in den Antworten. Alle anderen Origins bekommen keinen Header. Erlaubt sind:
  - `http://10.42.0.1`,
  - die aktuellen Kunden-IPs auf eth0 und WLAN,
  - `http://<hostname>.local`.

  Weil IPs und Hostname wechseln, schreibt `mp-hmi-origins` bei jeder Änderung (NetworkManager-Dispatcher, Boot) die Listen nach `/run/mp-hmi-proxy/` und lädt haproxy neu.
- **Abweisen statt nur Header weglassen** (Sicherheitsprüfung 2026-10-09): Ohne CORS-Header kann eine fremde Seite die Antwort nicht lesen, ein einfacher `POST /machine/code` würde aber trotzdem ausgeführt (CSRF). Deshalb gilt zusätzlich:
  - Eine Anfrage mit fremdem `Origin` bekommt 403.
  - Eine Anfrage mit fremdem `Host` bekommt ebenfalls 403. Das schützt gegen DNS-Rebinding, bei dem ein fremder Name auf das HMI zeigt und der Browser die Seite für gleichen Ursprung hält.
  - Erlaubte Hosts sind die eigenen Adressen (IPv4 und IPv6), `<hostname>`, `<hostname>.local`, `localhost` und `127.0.0.1`.
  - Anfragen ohne `Origin` (Navigation, GET, Werkzeuge wie der QA-Abruf von `/snapshot`) laufen weiter, solange der Host passt.
  - Folge: Ein eigener DNS-Name des Kunden für das HMI (z. B. `drucker1.firma.lan`) wird abgewiesen, bis er auf der Liste steht. Offen ist, ob es dafür einen Schlüssel in `identity.conf` gibt.
- **Warteseite:** Ohne Duet-Pi (Boot, Bench, Defekt) liefert haproxy statt 503 eine eigene kleine Seite (`errorfile 503`) im Meltingplot-Look: „Drucker startet …“. Sie lädt sich alle paar Sekunden neu, bis DWC antwortet.

## Hostname (`mp-hmi-hostname`)

- **Herkunft:** Der Kundenname liegt in `sys/overrides/printer-name.g` auf dem Duet-Pi. Das HMI liest ihn per HTTP von DSF (`/machine/file/0:/sys/overrides/printer-name.g`) und bildet daraus wie `mp-hostname` mit `mp_slug` den Hostnamen, plus `-hmi`. Aus „Halle 2 links“ wird `halle-2-links-hmi`, im Kundennetz `halle-2-links-hmi.local`.
- **Ablauf:** Beim Boot gilt zuerst der zwischengespeicherte Name, sonst der Default aus `identity.conf` (`meltingplot-chx-350-<serial>-hmi`). Ein Timer holt den Namen nach, sobald der Duet-Pi antwortet, und danach regelmäßig.
- **Nach einer Änderung:** `hostname` setzen, Avahi neu ankündigen und die CORS-Liste aktualisieren.
- **Connect-Gerätename:** bleibt fest `meltingplot-chx-350-<serial>-hmi`.

## Zugang und Identität

- **mp-identity:** `mpid.role=hmi`. Neu für beide Images sind drei Schlüssel in `identity.conf`: `timezone=` (Standard Europe/Berlin), `wifi_country=` (Standard DE) und `keyboard=` (Standard de).
  - `/etc/localtime` liegt auf dem read-only Root. Vorschlag: Im Image ist es ein Symlink auf `/persistent/common/etc/localtime`, und mp-identity setzt diesen Link auf die passende Zone.
  - Zu prüfen: ob glibc und `timedatectl` mit dieser Symlink-Kette zurechtkommen.
  - Für den Duet-Pi ist das eine Änderung gegenüber heute (Europe/London). Sie kommt als eigener PR.
- **mp-admin:** `mpnet.address=10.42.0.1/24`. Erlaubt ist `mpadmin@10.42.0.0/24`, abgewiesen werden Verbindungen von 10.42.0.1 selbst. Die Build-Prüfung braucht eine Adresse aus dem Netz, die nicht die eigene ist. Bisher nimmt sie `mpnet.gateway`, das HMI hat im Druckernetz aber kein Gateway. Deshalb wird die Adresse künftig aus dem Netz berechnet. Für den Duet-Pi ändert sich dabei nichts.
- **mp-connect:** Mit `RequiresProvider: rpi-connect-client` funktioniert der Layer mit `rpi-connect-lite` (Duet-Pi) und mit `rpi-connect` (HMI). Für die Bildschirmfreigabe zusätzlich `wayvnc` und eine gültige `/etc/default/keyboard`, weil `rpi-connect-env` sie unter `set -eu` einliest.
  - Die Prüfung von `AutoReboot`/`AutoCommit` bleibt bestehen. Am HMI ist das Packaged-Verhalten gewollt.

## Release und CI

- **Tags und Workflow:** Tags `hmi-pi5/v<X.Y.Z>` (annotiert), eigener Workflow `meltingplot-hmi-pi5.yml` nach dem Muster des Duet-Pi. Image-Name `mp-hmi-pi5-${IGconf_image_version}`.
- **Release-Hooks:** Zu prüfen ist, was `prebuild05-mp-release-gate` und `deploy20-mp-release` voraussetzen, z. B. DSF-Pins. Der Gate-Hook prüft heute DSF- und Plugin-Pins und muss für ein Image ohne `mp-dsf` greifen, ohne zu scheitern.
- **Lizenzen:** Das HMI enthält keine Meltingplot-Firmware. Lizenzhinweise kommen aus der SBOM.

## Erster Dev-Build (Bench, nur HMI)

1. **Bauen:** `./rpi-image-gen build -S ./meltingplot -c hmi-pi5.yaml`, lokal nativ in WSL.
2. **Inbetriebnahme:** SD flashen, `identity.conf` mit Seriennummer und optional Connect-Key auf `/bootfs`.
3. **Prüfen am Bench:**
   - Display und Touch.
   - Kiosk startet, Tastatur erscheint in einem Textfeld.
   - Leiste per Geste.
   - WLAN und statische IP über die Leiste, beides nach Reboot und nach OTA noch da.
   - `/webcam` und `/snapshot` liefern Bilder, CPU-Last von motion mit `pidstat`.
   - Connect-Anmeldung und Bildschirmfreigabe.
   - CORS: erlaubter Origin bekommt den Header, fremder nicht.
   - `mpadmin` aus dem Kundennetz abgewiesen.
4. **Nicht prüfbar ohne Duet-Pi:** DWC über den Proxy, Hostname vom Duet-Pi, NAT, DHCP und DNS im VLAN 20. Ein Laptop im VLAN 20 kann den Duet-Pi spielen, sobald ein Switch da ist.

## Offen

- **Splash:** Neuexport der PNG in 1280x800, aufrecht.
- **Drehung:** Stellen am Bench klären (siehe Hardware).
- **Laborabgleich:** haproxy mit dem Labor-HMI abgleichen.
- **Geste:** Kandidat A oder B, entschieden nach dem Bench-Test.
- **Zeitzone per Symlink auf `/persistent`:** am Bench prüfen.

## Stand nach der ersten Runde am Bench (2026-10-09)

Dev-HMI am Bench, nur das HMI, Seriennummer 003. Gebaut wurde lokal, Ergebnisse von Build 3 und Build 6.

**Läuft:**
- Bild (180°), Touch und Bildschirmfreigabe über Connect.
- Die Warteseite ohne Duet-Pi.
- `/snapshot` liefert 1280x960 in 0,5 s, die OV5647 läuft über v4l2-compat in motion 4.7.
- 403 für fremden Host oder fremden Origin, Preflight für eigenen Origin.
- labwc als logind-Sitzung auf seat0/tty1, der Ausgang heißt `DSI-1`.
- Zeit über PTB synchronisiert, `eth0.20` mit 10.42.0.1 aktiv, DNS und mDNS über systemd-resolved.

**Am Bench gefunden und behoben:**
- **Gerätename:** Die Netzwerkkarte hieß `end0` statt `eth0`. Jetzt sind wie in `systemd-net-min` `99-default.link` und `73-usb-net-by-mac.link` auf `/dev/null` gesetzt.
- **resolv.conf:** `/etc/resolv.conf` kam vom Build-Rechner. Jetzt nimmt die Suite `systemd-resolved` auf, NetworkManager läuft mit `dns=systemd-resolved` und mDNS.
- **Hostname:** NetworkManager hat ihn auf `/etc/hostname` zurückgesetzt. Abhilfe ist `hostname-mode=none`.
- **squeekboard:** Das postinst brauchte `/etc/xdg/autostart`, das jetzt ein essential-hook anlegt.
- **wayvnc:** Das Paket aktivierte einen systemweiten VNC-Server an allen Adressen. Er ist jetzt maskiert, Connect nutzt seinen eigenen in der User-Sitzung.
- **Connect:** `/dev/vcio_crypto` war nur für root zugänglich, das gilt auch für den Duet-Pi. Der Fix steht in PR #82 und ist im Branch enthalten.

**Leiste:** Per Tipp auf den 5-px-Streifen war sie kaum zu treffen. Deshalb gibt es jetzt Kandidat B:
- `lisgd` erkennt Wischen vom oberen Rand nach unten (zeigen) und nach oben (verstecken, sonst nach 60 s von selbst).
- **Zugriff:** Den Touchscreen öffnet eine udev-Regel per `uaccess` nur der Sitzung am Seat (`71-mp-kiosk-touch.rules`), ohne Gruppe `input`.
- **Drehung:** Sie wird im Build eingerechnet, bei 180° ist die Geste roh DU an der Kante B.
- Noch ungetestet.

**Offen:**
- Die Bildschirmtastatur in Chromium. Ohne Duet-Pi gibt es dort kein Textfeld, Ersatztest ist der Netzwerkdialog.
- `printer_name` auf dem HMI ignorieren, weil der Name vom Duet-Pi kommt.
- `COMMISSIONED` steht vor der Zeitsynchronisation, gilt beide Images.
- Der Hostname vom Duet-Pi.
- Overrides für Zeitzone, WLAN-Land und Tastatur per `identity.conf`.
- Eigene DNS-Namen des Kunden.
