# CLAUDE.md – Übergabe für Claude Code

Familien-App „Familie“ (SwiftUI, iOS 17+) für Home Assistant unter `https://ha.mohs.es`. Nutzer: Jan (Besitzer, Admin), Vanessa, Emma, Leoni. **Sprache mit Jan: Deutsch, kurz, ohne Technik-Jargon.** Details zu Funktionen und Aufbau stehen in `README.md`.

## Arbeitsweise

- Jede Änderung an der App: `VERSION` um 1 hochzählen (aktuell 153), committen, `git push origin HEAD:main`.
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
- Offen bzw. angeboten:
  - Zuhause-Karten neu gestalten (pausiert)
  - Watch-Komplikationen
  - Garage- und Tor-Seite
  - ggf. größeres Ollama-Modell
- Entwürfe liegen auf den Design-Flächen „Technik – Netzwerk & Streaming Entwürfe“ und „Weltkarte – Design-Varianten“ in Jans Claude-Artefakten.
