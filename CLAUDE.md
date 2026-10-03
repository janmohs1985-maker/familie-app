# CLAUDE.md – Übergabe für Claude Code

Familien-App „Familie“ (SwiftUI, iOS 17+) für Home Assistant unter `https://ha.mohs.es`. Nutzer: Jan (Besitzer, Admin), Vanessa, Emma, Leoni. **Sprache mit Jan: Deutsch, kurz, ohne Technik-Jargon.** Details zu Funktionen und Aufbau stehen in `README.md`.

## Arbeitsweise

- Jede Änderung an der App: `VERSION` um 1 hochzählen (aktuell 176), committen, `git push origin HEAD:main`.
- Commit-Nachricht: `Update <VERSION>: <was>` und am Ende die Co-Authored-By-Zeile.
- Ein Push auf `main` startet `.github/workflows/build.yml` auf macOS 26 mit Xcode 26. Der Workflow baut, signiert, lädt zu App Store Connect hoch und gibt den Build in TestFlight für die interne Gruppe „Familie“ frei (`.github/scripts/testflight_assign.py`). Die App in App Store Connect heißt „Familie Mohs“, id 6818251048. Jan installiert über **TestFlight**.
- **Nicht auf den Build warten.** Direkt nach dem Push melden („Update N ist hochgeladen, kommt in ~15 Min.“). Den Status höchstens später prüfen: `curl -s https://api.github.com/repos/janmohs1985-maker/familie-app/actions/runs?per_page=1`.
- Commits ohne App-Änderung (z. B. Doku) mit `[skip ci]` in der Nachricht, damit kein doppelter Build entsteht.
- Neue Swift-Dateien einfach in `FamilyHub/` legen. Das Projekt nutzt File-System-Synchronized Groups, `project.pbxproj` muss also nicht angepasst werden. Ressourcen (`*.bin`) im selben Ordner landen automatisch im Bundle.
- Bloße Fragen beantworten und nicht gleich umbauen. Bei Design-Wünschen zuerst Entwürfe zeigen (Design-Fläche), dann bauen.

## Sicherheitsregeln (wichtig)

- **Niemals Passwörter, API-Schlüssel oder Tokens** eintragen, erfragen oder ausgeben. Dazu gehören HA-Benutzer, GitHub, UniFi-Key, APNs-Key, DoorBird, TeslaLogger-DB, Paperless, evcc-Admin, WireGuard-Keys und die IPTV-Zugangsdaten bzw. -Playlist. Das trägt Jan selbst ein.
- **Router und System nur mit ausdrücklichem OK.** Das gilt für UniFi (Routen, Firewall, Reihenfolge), HA-Core-Neustart und Firewall. Eine Routen-Änderung ohne Rückfrage hat schon einmal Jans Stream abgebrochen.
- In UniFi: Geräte mit fester IP bleiben fest (keine DHCP-Reservierungen). Geräte mit Namen oder fester IP nicht löschen.
- Nicht in die TeslaLogger-Datenbank schreiben (nur lesen).
- Tür-, Tor- und Test-Mitteilungen gehen nur an Jan, solange er nichts anderes sagt.
- Geheime Links privat halten (SideStore, Bilder-Ordner, Scans, Ekey-Webhook-IDs).

## Home Assistant und Family Hub

- **Family Hub** ist das lokale Add-on `local_familie_scanner`, Version 1.15.0. Den Quellcode bearbeitet man unter `/homeassistant/familie_scanner_addon/` (`server.py`, `config.yaml`, `translations/`). Flask läuft auf `127.0.0.1:8099` mit `host_network: true`.
  - Nach Änderungen an `server.py` das Add-on neu starten (Supervisor `/addons/local_familie_scanner/restart`).
  - Änderungen an `config.yaml` oder dem Dockerfile muss Jan nach `/addons/familie_scanner/` kopieren. Danach Add-on-Store neu laden und aktualisieren.
- Die App ruft Family Hub über **rest_commands** in `/homeassistant/includes/rest_commands.yaml` auf: POST `{"daten": …}` an `127.0.0.1:8099/<pfad>`, Antwort über `return_response`. Wichtige Befehle: `familie_iptv`, `familie_weltkarte`, `familie_syslog_probe`, `familie_unifi_flows`, `familie_vpn_route_ip`, `familie_netz_get`, `familie_tesla`, `familie_laden`, `familie_fw_logging`. Nach einer Änderung an der YAML-Datei `rest_command.reload` aufrufen.
- Zugriff während der Arbeit hatte Claude bisher über den Browser-Tab mit HA: `document.querySelector('home-assistant').hass` (callWS, callService) und das File-Editor-Add-on (Ingress) zum Lesen und Speichern von Dateien.
- **Push:** Family Hub schickt direkt über APNs. Geräte werden über den Push-Token erkannt, Dubletten werden entfernt. Mitteilungen laufen über `script.familie_mitteilung` bzw. `_melden(an, titel, text, link)` in `server.py`.

## Netzwerk (UniFi UDM Pro 10.10.2.1)

- Es gibt zwei Leitungen: wan1 = 1&1 Versatel (Haus), wan2 = Starlink. Starlink ist Reserve **und** wird dauerhaft vom Family-WLAN der Kinder genutzt (Netz „Mohs Family“ per Umleitung). Deshalb soll Starlink immer live angezeigt werden.
- **Syslog:** Die UDM schickt „Activity Logging (SIEM)“ an `10.10.2.10:5514/UDP`, Family Hub lauscht dort. Die Regel „Internet Out Log“ (Intern → Extern, Logging an) liefert die ausgehenden Verbindungen für die Weltkarte. „Block All Traffic“ mit Logging bei External → Gateway und External → Internal liefert die geblockten Zugriffe von außen. Die Standorte kommen aus der DB-IP-Lite-Datenbank unter `/data/dbip-city-lite.mmdb` im Add-on, ausgewertet mit einem eigenen MMDB-Leser in `server.py`.
- Traffic-Flows in UniFi enthalten nur Regeln mit Logging; „Flow Logging“ steht auf „Blocked only“. Für die App wird deshalb der Syslog genutzt.
- **IPTV:** Port 25461. Die VPN-Route „WireGuard de-fra-wg-202“ (Mullvad, id `6abf5eb58e5cac231c2b2566`) schickt Port 25461 über den Tunnel. Die Regel „Familie-App: IPTV-Log“ steht oben bei Intern → Extern. Der IPTV-Wächter in Family Hub prüft alle 10 s den Tunnel und speichert Seh-Sitzungen und Ruckler in `/data/iptv_protokoll.json`. Der Push bei Rucklern ist abschaltbar.
- Pi-hole (10.10.1.5/6) ist der DNS. Deshalb funktionieren Domain-Routen in UniFi nicht, Routen gehen über IPs bzw. Ports.

## Weitere Systeme

- **Tesla:** TeslaLogger-DB (MariaDB) auf der Synology unter 10.10.2.45:3306, nur lesend mit eigenem Lese-Benutzer. Die Live-Aktivität beim Laden läuft über Family Hub; die Lade-Modi kommen aus evcc (sunNight, sun, now, off).
- **evcc** läuft als Add-on. Die eigenen evcc-Benachrichtigungen soll Jan in der evcc-Oberfläche abschalten (Admin-Passwort, nicht anfassen).
- **Zigbee:** Zigbee2MQTT. Anlernen über `switch.zigbee2mqtt_bridge_permit_join`, Umbenennen per MQTT `zigbee2mqtt/bridge/request/device/rename` mit `homeassistant_rename: true`.
- **Paperless-ngx** läuft unter 10.10.7.61:8000. Für die KI-Vorschläge nutzt Family Hub Ollama `qwen2.5:7b` unter 10.10.7.60:11434.
- **Watch-App:** Target `FamilieWatch` (`es.mohs.familie.watchkitapp`). Die Zugangsdaten kommen per WatchConnectivity vom iPhone.

## Stand und Ideen

- Erledigt bis Update 149:
  - Netzwerk-Cockpit im App-Look mit Auswahl-Kacheln (Entwurf 9)
  - Weltkarte als Punktmatrix mit Lichtsäulen und als 3D-Globus, umschaltbar, plus Modus „Geblockt von außen“
  - Streaming-Seite mit Ruckler-Protokoll
  - Zigbee anlernen und umbenennen
  - Scan-Detail: Paperless-Knopf nicht mehr unter der Tab-Leiste
  - Zigbee: Anlernen über „+“, Raum pro Gerät ändern (150)
  - Zuhause → Sonstiges → „DB Status“: Bahnübergang Elchinger Straße Nersingen mit Schranke, Zeitstrahl, Live-Karte, Zugliste (151). Daten von Transitous (`api.transitous.org/api/v1/map/trips`, ohne Schlüssel), Schließzeiten geschätzt (`RailCrossing.swift`). Entwürfe: Design-Fläche „Bahnübergang Nersingen – Entwürfe“.
  - Musik-Player neu im Look „Cover-Glas“ (Entwurf 1B): Vollbild mit Cover-Farben, Bibliothek/Suche/Konto als Blatt von unten (`MusicPlayer.swift`, 154). Entwürfe: Design-Fläche „Musik-Player – 6 Entwürfe“.
  - Fitness-Bereich Schritt 1 (155, nur Jan/`isAdmin`): Zuhause-Karte „Fitness“ → Übersicht (Ziel 127 → 108 kg, Ringe, Erholung, Woche, Muskeln-Körper), Trainings, Detail (Karte, Puls, Zonen), Entwicklung. Daten direkt aus Apple Health (`Fitness.swift`, `FitnessViews.swift`, `BodyMap.swift`). Der Build schaltet HEALTHKIT an der App-ID ein und übernimmt Berechtigungen nur, wenn das Profil sie enthält. Schritt 2 (156): Trainingsplan `GymPlan.swift` im HA-Kalender `calendar.gym` (nur dort), Einheiten per Ziehen/Menü verschieben (WS `calendar/event/update`), „Woche planen“ aus Vorlage (Mo Gym A, Di Basketball, Mi Schwimmen, Do Gym B, Sa Padel, So Rad), „Als Vorlage“. Padel = Watch-Aufzeichnung „Sonstiges“ (`.other`), Basketball eigene Sportart. Schritt 3a (157): Gym-Training auf dem iPhone (`GymTraining.swift`, `GymTrainingViews.swift`): Anfängerplan A/B (Insignia-Geräte), Sätze abhaken, Gewichte merken + Steigerung, Pausen-Timer mit Mitteilung, Gerät-Bildschirm V7, Zusammenfassung mit Körper, optional als Krafttraining in Apple Health (nicht doppelt zur Watch). Verlauf in Application Support `gym_verlauf.json`. Ernährung & Körperwerte (158, `Nutrition.swift`): Yazio-Nährwerte, Kalorienziel = Ø Verbrauch 7 Tage − Defizit (550), Eiweiß 1,6 g/kg Zielgewicht, Mahlzeiten aus Zeit-Häufung, Woche, Renpho-Werte (Fett/Magermasse/BMI). 166: Ernährung „Tag“ mit Pfeilen und Wischen durch die letzten 35 Tage (Mahlzeiten je Tag über `FitnessModel.meals(on:)`). 167: Ketose-Schätzung (`KetoCard`): Netto-KH (KH − Ballaststoffe) der letzten 3 Tage (≤ 25 g wahrscheinlich, ≤ 50 g möglich) + Fasten-Timer seit letzter Mahlzeit (≥ 16 h möglich, ≥ 24 h wahrscheinlich). 3b Watch (159, `FamilieWatch/GymWatch.swift`, `WatchBodyMap.swift` = Kopie von `BodyMap.swift`): iPhone schickt Plan + Gewichte im WatchConnectivity-Kontext `gym` (UserDefaults `gymWatchPayload`, nur wenn `gymOnWatch`), Uhr zeichnet Krafttraining mit HKWorkoutSession auf (Puls/kcal), Gewicht per Krone, Pausenring, schickt Sätze per `transferUserInfo` `gymLog` zurück. Watch-Target: `FamilieWatch-Info.plist` (Workout-Hintergrund, Health-Texte), Berechtigung `FAMILIE_WATCH_ENTITLEMENTS` setzt der Build nur, wenn das Watch-Profil HealthKit enthält. Entwürfe: Design-Fläche „Fitness-Bereich – Entwürfe“. Wochenziel: 2× Gym, 1× Padel, 1× Schwimmen, 2× Rad.
  - 161: Plan-Einheiten mit eigenem ⇄-Knopf verschieben (Tage, Morgen, nächste Woche; Ziehen bleibt). Erholung ohne Uhr nachts: Ruhepuls + HRV gegen 30-Tage-Schnitt, Last gestern, Schlaf/„Im Bett“ vom iPhone, eigenes Gefühl (fit/okay/müde, `FitnessModel.recovery`). Jan trägt die Uhr nachts nicht.
  - 163: Trainingsplan neu „flexibel“ (`GymWeek.swift`, Entwürfe P2+P1): Heute-Karte (Los geht's/Später/Auf morgen mit Nachrücken/Fällt aus), Vorschlag aus offenem Wochen-Kontingent + Erholung, Marken (offen/geplant/erledigt), Woche, Demnächst. Kontingent einstellbar (`gymQuotas`), Basketball fest Di 19:00 wird automatisch eingetragen. Alte Vorlage (`gymTemplate`) wird nicht mehr genutzt. 164: „+ Extra“-Marke (jede Sportart zusätzlich), freie Sportarten als „+ Laufen“, mehrere Einheiten pro Tag (erledigt pro Einheit gezählt, „Danach heute“, „Noch was“). 165: Wochenleiste `WeekStrip` zeigt alle Einheiten pro Tag gestapelt, Tag antippen → `DayDetailSheet` (verschieben, dazu planen); auch in der Fitness-Übersicht. 168: Trainingsplan wieder mit Wochen-Blättern (‹ ›, bis nächste Woche), Karte „Alle Trainings (Apple Health)“ der Woche inkl. Spaziergänge/Sonstiges.
  - 169: Einstellungen → „Builds“ (nur Jan, `BuildsSection` in `AppUpdate.swift`): letzte GitHub-Actions-Läufe live (wartet/baut/fertig/Fehler, „installiert“), direkt von der öffentlichen GitHub-API, Link zu TestFlight.
  - 170: Sportart „Gehen“ (walking/hiking, `figure.walk`). 171: Training löschen (Detail-Mülleimer, langes Drücken in der Liste): eigene (Familie-App/Uhr) in Apple Health löschen + Gym-Verlauf, fremde nur ausblenden (`fitAusgeblendet`), Link zur Health-App.
  - 172: Musik – Haptik + Ladeanzeige beim Antippen; Titel aus Liste spielt weiter (`playFrom`): Playlist/Album ganz laden + `sonos.play_queue` ab Position, Lieblingssongs (nicht als Ganzes abspielbar) = Titel + nächste 40 per `enqueue: add`.
  - 174: Kameras (Frigate, nur Eltern): Technik → Karte „Kameras“ + Kacheln „Kameras“/„Kamera-Ereignisse“ (`Frigate.swift`, `FrigateViews.swift`). Übersicht (Raster, jüngste Bewegung groß), Kamera mit Live-Bild (HLS `camera/stream`) und wischbarer Zeitleiste (Aufnahmen über VOD `/api/frigate/<instanz>/vod/…`, Zoom per Fingern), Ereignis-Feed mit „neu“/„Alle gesehen“, Clip ansehen + teilen, PTZ (Dienst `frigate.ptz`, Positionen über WS `frigate/ptz/info`, sonst im Menü einschaltbar), Einstellungen = Frigate-Schalter/-Zahlen des Geräts. Kameras aus dem Entitäten-Register (Plattform `frigate`), Ereignisse per WS `frigate/events/get`, Bilder/Clips über `/api/frigate/notifications/<id>/…`. Instanz-ID „frigate“ (UserDefaults `frigateInstance`). Entwürfe: Design-Fläche „Frigate Kameras – Entwürfe“. Offen: Mitteilungen bei Personen über Family Hub. 175: Abspielen über MP4 der Integration (`/api/frigate/<instanz>/recording/<kamera>/start/<t>/end/<t>`, 5-Min.-Stücke, danach weiter bzw. live) statt VOD-HLS (Teilstücke brauchen Signatur → schlug fehl); Ausweich auf Ereignis-Clip, Fehlercode im Hinweis. 176: Frigate liefert MP4 am Stück ohne Länge und ohne Range, das spielt AVPlayer direkt nicht ab → `FrigateModel.asset` lädt Clip/Aufnahme erst in eine Datei (tmp/frigate, letzte 10), Stücke 2 Min., Ladekreis.
  - Family Hub `_w_builds` (im Wächter, alle 2 Min): fertige GitHub-Builds → Mitteilung nur an Jan („✅ Update N ist fertig“ / „⛔ … fehlgeschlagen“). Sicherung `server.py.vor_builds`.
  - Saugroboter-Live-Aktivität: Startzeit aus „Reinigungszeit“ statt altem „letzter Reinigungsbeginn“ (Family Hub `server.py`, Sicherung `server.py.vor_sauger_fix`).
- Frigate (Stand 2026-10-03): Add-on `ccab4aaf_frigate` 0.18 läuft wieder.
  - Coral USB steckt am Proxmox-Host (prox01) in der USB-3-Buchse 2-1. Die HA-VM 114 hat `usb3: host=2-1,usb3=1` und 14 GB RAM. Die Erkennung braucht ca. 19 ms pro Bild. Coral nicht umstecken, sonst kommt er nicht mehr in HA an.
  - Aufnahmen gehen auf die Synology über den HA-Netzwerkspeicher „frigate“ (Medien → `/media/frigate`).
  - Kameras: `cam_vorne` = RLC-823A dreh-/zoombar (10.10.3.21), `cam_einfahrt_garage_boden` = RLC-810A an der Einfahrt am Boden (10.10.3.22, go2rtc-Stream „hinten“, gerade offline), `cam_garage` = RLC-520A (10.10.3.23), `doorbird` = DoorBird DBIS (10.10.3.153).
  - Einstellungen ändert man über die Frigate-API `PUT /api/config/set` (`config_data`), dabei bleiben die Passwörter in der Datei unangetastet.
  - Garage erkennt nur Personen (`objects.track` und `review.detections.labels` = person), weil die geparkten Räder sonst ständig Einträge erzeugten.
  - Offen: Dreh-/Zoom-Steuerung über ONVIF (Passwort trägt Jan ein), alte Streams `einfahrt_garage_boden` (.161) entfernen, Zonen neu zeichnen, Push mit Bild. Paket-Erkennung gibt es nur mit Frigate+.
  - Nabu Casa läuft am 15.10.2026 ab, daran hängt ha.mohs.es.
- Offen bzw. angeboten:
  - Zuhause-Karten neu gestalten (pausiert)
  - Watch-Komplikationen
  - Garage- und Tor-Seite
  - ggf. größeres Ollama-Modell
- Entwürfe liegen auf den Design-Flächen „Technik – Netzwerk & Streaming Entwürfe“ und „Weltkarte – Design-Varianten“ in Jans Claude-Artefakten.
