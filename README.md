# Familie – iPhone-App für Home Assistant

Die Familien-App für Jan, Vanessa, Emma und Leoni. Alles kommt aus Home Assistant (`https://ha.mohs.es`). Die Familie braucht weder die HA-App noch die HA-Oberfläche. Jeder meldet sich mit seinem eigenen HA-Benutzer an, und die App erkennt daran, ob Eltern oder welches Kind sie benutzt.

- **Plattform:** iOS 17+, SwiftUI, keine Fremdbibliotheken
- **Bundle-ID:** `es.mohs.familie`
- **Gebaut und signiert:** automatisch per GitHub Actions
- **Verteilt:** über Home Assistant (Family-Hub-Add-on), Installation und Updates direkt auf dem iPhone

---

## Inhalt

1. [Funktionen](#funktionen)
2. [Rollen und Rechte](#rollen-und-rechte)
3. [Home-Assistant-Seite](#home-assistant-seite)
4. [Bauen, signieren, verteilen](#bauen-signieren-verteilen)
5. [Ein Update einspielen](#ein-update-einspielen)
6. [Anpassen](#anpassen)
7. [Projektaufbau](#projektaufbau)
8. [Sicherheit](#sicherheit)

---

## Funktionen

### Heute
Die Karten lassen sich anordnen und ausblenden. Jan legt die Anordnung zentral für alle fest, die Kinder sehen davon nur ihre eigenen Karten.

| Karte | Inhalt |
|---|---|
| Rauchmelder | erscheint nur bei Alarm oder Problemen (Batterie, offline, Störung) |
| Wetter | Dachwetterstation (Temperatur, Wind, Helligkeit), Blitzortung, Stunden- und Tagesvorhersage (Blatt beim Antippen) |
| Briefkasten | „Post ist da“ mit *Geleert*-Knopf |
| Klingel | Bild nach dem Klingeln |
| Wäsche | Waschmaschine/Trockner laufen, voraussichtliches Ende |
| Küche | Miele Geschirrspüler, Backofen, Dampfgarer: läuft / fertig um … |
| Unsere Aufgaben | offene Aufgaben von Jan & Vanessa |
| Musik | was gerade läuft |
| Saugroboter | Status, Hinweise (Wasser, Behälter) |
| Wer ist wo? | Profilbilder, Zone, Karte; bei den Kindern die letzte Türöffnung (ekey) |
| Stundenplan / Freizeit | Fächer, Schulschluss, Nachmittagstermine |
| Essen heute | aus dem Essensplan |
| Müllabfuhr | Morgen = orange, Heute = rot |
| Nächste Termine | mit kleinem Gesicht der Person bzw. Haus-Symbol für den Familienkalender |

Oben erscheint „Neue Version verfügbar“, sobald ein neues Update bereitliegt.

### Kalender
- **Die Woche auf einen Blick:** Mo–So untereinander, heute hervorgehoben, Termine als farbige Streifen. Zwischen den Wochen blättern (Pfeile oder Wischen).
- **Darunter alles Weitere nach Monaten:** etwa 4 Monate im Voraus, Schulferien als Zeitraum.
- **Kleines Gesicht bei jedem Termin:** Jan, Vanessa, Emma, Leoni; Familie = Haus.
- **Neue Termine:** mit **+** anlegen.
- **Stundenplan:** oben links.

### Aufgaben
- **Kinder:** Aufgaben mit Punkten, Serien, Belohnungen, wiederkehrende Aufgaben. Die Eltern bestätigen.
- **Wir (Jan & Vanessa):** gemeinsame Aufgabenliste mit Zuständigkeit (Ich / Partner / Beide, mit Gesichtern), Fälligkeit und Notiz. Der andere bekommt eine Mitteilung.

### Listen & Einkauf
- **Einträge:** Einkaufsliste mit Mengen („2x Milch“), Sortierung nach Gängen, Vorschlägen und Dubletten-Erkennung.
- **Pro Eintrag:** wer ihn hinzugefügt hat und wann.
- **Gesten:**
  - Kreis antippen oder nach rechts wischen = gekauft
  - „Haben wir noch“ (im Laden)
  - nach links = ändern/löschen

  Eine animierte Erklär-Karte zeigt die Gesten; sie lässt sich über ⋯ → „Wischen erklären“ wieder einblenden.
- **„Ich gehe einkaufen“:** Mitteilung an alle, plus Erinnerung in der Nähe des Supermarkts.
- **Weitere Listen:** alle To-do-Listen aus HA.

### Zuhause

**Übersicht**
- **Schalten:** *nur für die Kinder*. Das sind die Geräte, die Jan für sie freigibt, auf Wunsch mit Zeitfenster.
- **Haus:**

  | Kachel | Inhalt |
  |---|---|
  | Haus & Strom | PV, Speicher, Netz, evcc-Ladepunkte mit Modi; Verlauf nach Tagen und Monaten, Ladevorgänge mit Kosten |
  | Heizung | Proxon: Modus, Räume, Wärmeelemente an/aus (lange drücken), Tastensperre |
  | Beschattung | Adaptive Cover Pro: Status je Fenster, pausieren/fortsetzen |
  | Rauchmelder | 11 Melder, Sirene aus, Batterie; kritischer Alarm an alle Handys |
  | Zigbee-Geräte | Überblick über alle Geräte, nächtliche Prüfung |
  | Internet | beide WANs (1&1 / Starlink), pro Netz umschalten mit Notaus, Speedtest, VPN, Starlink-Steuerung, UDM, Gäste-WLAN |
  | Haushaltsgeräte | Waschmaschine & Trockner (Laufzeit, kWh, Kosten, Verlauf), Miele Geschirrspüler, Backofen, Dampfgarer, Wärmeschublade (Programm, Restzeit, Temperatur, Licht, Start/Stopp) |
  | Pool | Wasserwerte, Verläufe, Pumpe/Wärmepumpe über evcc, Wasser nachfüllen (5–20 min) |
  | Bewässerung | OpenSprinkler-Zonen, Regenpause |
  | Saugroboter | Roborock EG/OG: Status, Programme, Karte, Wartung |

- **Familie:**
  - **Schule & Kinder:** pro Kind Stundenplan & Freizeit (wöchentlich oder 14-tägig), Schulmappe, Aufgaben & Punkte, Türöffnungen.
  - **Essensplan, Musik, Haustür.**
- **Verwaltung** (Eltern):
  - Dokumente scannen, „Wo sind alle?“, Einstellungen
  - nur Jan: **„Für die Kinder“** (Schalter und Sichtbarkeit)

**Räume** (Eltern; Kinder nur mit Freigabe)
- **Stockwerke:** Keller, EG, OG, Garage, Garten. Je Stockwerk:
  - „Alle aus“
  - alle Rollläden hoch/runter
  - „Alle Fenster zu“ bzw. „2 Fenster offen“
- **Raumkacheln:** Licht an (gelb), Rollläden, Steckdosen, Temperatur, offenes Fenster.
- **Im Raum:**
  - Temperatur/Heizung
  - Licht (Helligkeit, Farbe, Weißton)
  - Steckdosen
  - **Rollläden & Raffstores** mit Hoch/Stopp/Runter direkt in der Zeile; Details mit Position, **Lamellen-Neigung** und der **Beschattungs-Automatik** (an/aus, pausieren 1 Std./3 Std./bis morgen, fortsetzen)
  - Fenster & Türen
- **Esstischlampe:** eigene Karte mit gezeichneter, animierter Lampe. An/Aus, heller/dunkler, warm/kalt, hoch/runter, aus-/einfahren, Stopp, Essens-Position.
- **Bearbeiten** (nur Jan):
  - Geräte hinzufügen, entfernen, umbenennen, sortieren, in andere Räume verschieben
  - Art festlegen (Lampe / Nur auslösen / Esstischlampe), eigenes Symbol, Nachfrage vor dem Schalten
  - Räume anlegen, umbenennen und sortieren
  - Fenster-/Türkontakte zuordnen

  Alles wird in Home Assistant gespeichert und gilt sofort auf allen Handys.

### Musik
Sonos Küche und Move 2 mit den Spotify-Bibliotheken von Jan und Vanessa sowie Suche über Music Assistant. **Zusammen abspielen:** Lautsprecher zusammenschalten, sodass die gleiche Musik überall läuft.

### Mitteilungen
Alle Mitteilungen laufen über `script.familie_mitteilung`. Antippen öffnet die passende Stelle der App (`familie://…`).

- **Direkt von „Familie“ (Push über Apple):** Das Skript ruft zuerst `rest_command.familie_push` auf. Family Hub schickt die Mitteilung an alle iPhones der Empfänger, die sich mit Push-Token gemeldet haben (Geräteliste `/geraete`). Nötig sind im Add-on die Optionen `apns_key` (Inhalt der .p8-Datei), `apns_key_id` und `apns_team_id`; die App braucht das Entitlement `aps-environment` (Datei `Familie.entitlements`) und im Apple-Konto „Push Notifications“ beim Identifier `es.mohs.familie`.
- **Über die Home-Assistant-App:** alle, die per Familie-App nicht erreicht wurden, außerdem kritische Mitteilungen (Rauchalarm, klingeln auch bei lautlos).
- **Bilder (Klingel):** Family Hub kopiert das Foto in einen geheimen Ordner unter `/local/familie-bilder-…` (3 Tage), die Mitteilungs-Erweiterung `FamilieMitteilung` (Bundle `es.mohs.familie.mitteilung`, eigenes Ad-hoc-Profil, App-ID legt der Build selbst an) lädt es. Knopf „Öffnen“ → App fragt nach und prüft Face ID.
- **Wächter in Family Hub** (braucht `homeassistant_api: true`): schaut jede Minute nach Änderungen – egal ob aus der App, per Alexa oder direkt im Kalender – und meldet sie gebündelt (2 Min. nach der letzten Änderung): Einkaufsliste → Eltern, Essensplan → alle außer dem, der es eingetragen hat, neue Termine (nächste 60 Tage) → Eltern, Klassenarbeit neu / gelernt → Eltern.
- **Morgen-Zusammenfassung** an alle, jeder seine Version (Termine, Klassenarbeiten, Müll, Essen, fällige Eltern-Aufgaben): Schultage 6:45, Wochenende/Ferien/Feiertage 8:30.
- **Ruhezeit 21:30–6:30:** normale Mitteilungen werden gesammelt und morgens als „Über Nacht“ nachgeliefert. Kritisches und Klingel kommen sofort.
- **Heimkommen / nicht daheim:** nur an den Elternteil, der gerade nicht zu Hause ist (`an: eltern_unterwegs`).
- **Lokale Erinnerungen** plant die App selbst: Klassenarbeit am Vorabend (18 Uhr), Mülltonne am Vorabend (19 Uhr, nur Eltern). Ein- und ausschalten unter Einstellungen → Mitteilungen; dort gibt es auch eine Test-Mitteilung.

Beispiele:
- Tür geöffnet (Emma/Leoni)
- Emma nach der Schule nicht daheim
- Wäsche fertig
- Küchengerät fertig
- „Ich gehe einkaufen“
- Rauchmelder
- Zigbee-Geräte offline

### Darstellung
Hell, Dunkel oder „Wie iPhone“ (Einstellungen → Darstellung), dazu eine Startanimation.

---

## Rollen und Rechte

| Rolle | Erkennung | Darf |
|---|---|---|
| **Jan** (Verwalter) | HA-Benutzer von `person.mohs` | alles, dazu Räume bearbeiten, „Heute“ anordnen, Kinder-Schalter und Sichtbarkeit festlegen |
| **Vanessa** | Elternteil | alles schalten und ansehen, aber nichts umbauen |
| **Emma, Leoni** | `person.emma` / `person.leoni` | nur freigegebene Bereiche und Schalter |

**Was die Kinder sehen dürfen** liegt in `input_text.familie_kinder_freigaben`:
- Standard: alles, außer „Räume“, das eigens freigegeben werden muss.
- Die Freigaben gelten pro Kind und sofort auf allen Handys.
- Zum Ausprobieren: „Für die Kinder“ → „App ansehen als“.

---

## Home-Assistant-Seite

### Family-Hub-Add-on (`local_familie_scanner`)
Ein lokales Add-on, das Flask auf `127.0.0.1:8099` betreibt. HA ruft es über `rest_command` auf, die App über Skripte.

| Pfad | Zweck |
|---|---|
| `/scan`, `/list`, `/prepare` … | Epson-Scanner, Dokumente nach Paperless (SMB) |
| `/schulmappe` … | Fotos der Schulmappe |
| `/guest_wifi`, `/guests` | Gäste-WLAN (UniFi) |
| `/netstatus`, `/net_routes`, `/net_mode`, `/speedtest` | Internet, Starlink/1&1 pro Netz |
| `/raeume` (GET/POST) | Räume-Einteilung lesen/speichern (legt vor jedem Speichern eine Sicherung an) |
| `/sidestore` (GET/POST) | App-Verteilung: neuestes Build von GitHub holen und bereitstellen |

- **Programmcode:** Er liegt in `/homeassistant/familie_scanner_addon/`. `run.sh` kopiert `server.py` beim Start von dort, sofern der Syntax-Check klappt. Für Änderungen an `server.py` reicht deshalb ein Neustart des Add-ons.
- **Einstellungen:** Die Add-on-Konfiguration enthält Scanner-IP, SMB, UniFi-API-Schlüssel, Gäste-SSID, GitHub-Repo und **GitHub-Token (nur Actions: lesen)** sowie die öffentliche Adresse.

### Dateien in `/homeassistant`
| Datei | Inhalt |
|---|---|
| `familie_raeume.json` | Stockwerke → Räume → Geräte (Name, Art, Symbol, Nachfrage), Heizung, Fenster-/Türkontakte |
| `familie_raeume_sicherung/` | die letzten 20 Stände der Räume |
| `includes/rest_commands.yaml` | `familie_*`-Befehle ans Add-on (Räume, Netz, Sidestore, evcc-Sitzungen …) |
| `includes/templates/templates.yaml` | u. a. Schulende-Sensoren für Emma und Leoni |
| `www/sidestore-<geheim>/` | Installationsseite, `manifest.plist`, `.ipa`, Symbol (der Link ist geheim und wird nur in der Familie geteilt) |

### Skripte und Helfer (Auswahl)
- **Skripte:**
  - `script.familie_mitteilung`: Mitteilungen (an: eltern/alle/jan/vanessa/emma/leoni, kritisch, link)
  - `script.familie_raeume`: Räume für die App
  - `script.familie_app_version`: neueste App-Version und Installations-Link
  - `script.familie_evcc_sessions`, `script.familie_zigbee` …
- **Helfer:**
  - `input_text.familie_kinder_freigaben`
  - `input_text.familie_heute_layout`
  - `input_boolean.<kind>_heute_keine_schule`
- **To-do-Listen:**
  - `todo.app_schalter` (Kinder-Schalter)
  - `todo.freizeit`
  - `todo.eltern_aufgaben`
  - `todo.einkauf_details`
  - `todo.waesche_verlauf`
  - `todo.tuer_verlauf`
  - `todo.klingel_verlauf`
- **Automationen:**
  - Rauchmelder
  - Wäsche fertig
  - Küchengerät fertig
  - Emma nach der Schule nicht daheim
  - Türöffnungen
  - Zigbee-Prüfung

### Anisette-Add-on
Das Add-on stammt aus der Zeit mit SideStore (kostenlose Apple-ID). Seit dem Entwicklerkonto wird es nicht mehr gebraucht und kann entfernt werden.

---

## Bauen, signieren, verteilen

```
push auf main
  → GitHub Actions (macOS): baut, signiert (Apple-Entwicklerkonto), lädt Familie.ipa als Artefakt hoch
  → Family Hub prüft alle 2 Minuten, holt das neueste Build, erzeugt Installationsseite + manifest.plist
  → App zeigt „Neue Version verfügbar“ → „Laden“ → iOS installiert das Update
```

- **Versionsnummer:** Die Datei `VERSION` enthält die Nummer des Update-Pakets, daraus wird zum Beispiel **1.0.59**. Die Build-Nummer ist die Nummer des GitHub-Laufs, damit Updates immer erkannt werden. In der App steht das unter Einstellungen → App, etwa „1.0.59 (55)“.
- **Signierung:** mit einem festen **Apple-Distribution-Zertifikat**. Das Ad-hoc-Profil mit allen eingetragenen iPhones holt der Workflow bei jedem Build selbst über die App-Store-Connect-API (`.github/scripts/adhoc_profile.py`), Methode *release-testing*. Es entstehen dabei keine neuen Zertifikate. Nötige **GitHub-Secrets**:
  - `APPLE_TEAM_ID`
  - `ASC_KEY_ID`
  - `ASC_ISSUER_ID`
  - `ASC_KEY_P8`
  - `DIST_P12`: das Zertifikat samt privatem Schlüssel als .p12, base64
  - `DIST_P12_PASSWORD`

  Fehlen alle, baut der Workflow unsigniert.
- **Neues iPhone:** Die UDID im Apple-Entwicklerkonto unter *Devices* eintragen, dann unter *Actions → Run workflow* neu bauen und die Installationsseite in **Safari** öffnen.
- **Gültigkeit:** Die App läuft ein Jahr, danach das Entwicklerkonto verlängern und neu bauen.

---

## Ein Update einspielen

Updates kommen als `familie-updateNN.zip`. Die Datei in *Downloads* speichern, dann in WSL:

```bash
cd /mnt/c/Users/janmo/Documents/app
unzip -o -q /mnt/c/Users/janmo/Downloads/familie-updateNN.zip
git add -A && git commit -m "Update NN: …" && git push
```

Meldet GitHub *Actions* einen Fehler, die Zeilen mit `error:` aus dem Log schicken.

---

## Anpassen

- **Räume, Geräte, Symbole, Fenster:** in der App unter Zuhause → Räume → Bearbeiten (nur Jan). Ohne neuen Build.
- **„Heute“:** in der App über „Heute anordnen“ (nur Jan).
- **Kinder-Schalter und Sichtbarkeit:** Zuhause → Verwaltung → „Für die Kinder“.
- **Feste Einstellungen im Code:** `FamilyHub/FamilyConfig.swift`:
  - Personen, Farben, Kalender und ihre Farben, Müll, Listen
  - Lautsprecher, Saugroboter
  - Rauchmelder (`Safety.swift`), Beschattung (`Shading.swift`)
  - Stundenpläne (`Timetable.swift`), Miele-Geräte (`Appliances.swift`)

---

## Projektaufbau

| Datei | Inhalt |
|---|---|
| `FamilyHubApp.swift`, `AppStore*.swift`, `HAClient.swift` | App-Start, Zustand, Home-Assistant-Anbindung (REST + WebSocket) |
| `TodayView.swift`, `TodayLayout.swift` | Heute und Anordnung |
| `CalendarView.swift` | Kalender (Woche + Monate) |
| `ChoresView.swift`, `ParentTodos.swift` | Aufgaben Kinder / Eltern |
| `Shopping.swift`, `Meals.swift` | Einkauf, Essensplan |
| `ControlsView.swift`, `Controls.swift` | Zuhause-Übersicht, Kacheln, Licht-/Rollladen-Blätter, Einstellungen |
| `Rooms.swift`, `RoomsEdit.swift`, `RoomsAdd.swift`, `DiningLamp.swift` | Räume, Bearbeiten, Symbole, Esstischlampe |
| `KidsHub.swift`, `KidPermissions.swift`, `Timetable.swift`, `Freizeit.swift`, `Schulmappe.swift` | Schule & Kinder, Freigaben |
| `Energy.swift`, `EnergyHistory.swift`, `Heating.swift`, `Shading.swift`, `Safety.swift`, `Network.swift`, `Pool.swift`, `Irrigation.swift`, `Vacuums.swift`, `Laundry.swift`, `Appliances.swift` | Haus-Bereiche |
| `Music.swift`, `MapAndDoorbell.swift`, `DoorOpenings.swift`, `Weather.swift`, `Documents.swift`, `GuestWifi.swift` | weitere Seiten |
| `DeepLink.swift`, `AppUpdate.swift` | `familie://`-Links, Update-Hinweis |
| `.github/workflows/build.yml` | Build und Signierung |
| `VERSION` | Update-Nummer = App-Version |

---

## Sicherheit

- **Anmeldung:** Jeder meldet sich mit seinem HA-Benutzer an. Die App speichert nur ein Token im iOS-Schlüsselbund, **nie das Passwort**. „Abmelden“ widerruft das Token in HA.
- **Keine Schlüssel im Repository:** Apple-Schlüssel liegen als GitHub-Secrets, GitHub-Token, UniFi-Schlüssel und SMB-Passwort in der Add-on-Konfiguration.
- **Rechte:** Home Assistant kennt keine Rechte pro Gerät. Die Einschränkungen für die Kinder setzt die App durch.
- **Installationslink:** Er ist geheim und nur für die Familie. Wer ihn hat, kann die App-Datei laden, ohne Zugang zu Home Assistant funktioniert sie aber nicht.
