# Familie – iPhone-App für Home Assistant

Eine schlanke App für die ganze Familie. Die Daten kommen aus Home Assistant, die Familie sieht aber nur diese App. Sie braucht weder die HA-App noch die HA-Oberfläche.

## Was die App kann

| Tab | Inhalt |
|---|---|
| **Heute** | Wetter, wer ist zuhause (mit Profilbildern), Schulende von Emma & Leoni, „Post ist da“-Hinweis mit *Geleert*-Knopf, Müllabfuhr (Morgen = orange, Heute = rot), nächste Termine |
| **Kalender** | Alle Kalender aus HA für die nächsten 3 Wochen, farbig nach Kalender. Mit **+** neue Termine anlegen (ganztägig oder mit Uhrzeit) |
| **Listen** | To-do-/Einkaufslisten aus HA: hinzufügen, abhaken, wischen zum Löschen, „Erledigte löschen“ |
| **Steuern** | Garagentor, Garagentür (Nuki), Briefkasten, Paketbote, Licht Eingang, Licht Gartenhaus. Tor und Tür nur nach Sicherheitsabfrage |

Die App aktualisiert sich alle 15 Sekunden, solange sie offen ist, und zusätzlich per Herunterziehen.

## Installieren (einmalig, am Mac)

1. **Xcode 16 oder neuer** aus dem Mac App Store installieren.
2. `FamilyHub.xcodeproj` per Doppelklick öffnen.
3. Links auf das Projekt **FamilyHub** klicken, dann **Signing & Capabilities** öffnen und bei **Team** deine Apple-ID auswählen. Falls sie fehlt: *Add Account…*.
   - Falls Xcode meldet, dass die Bundle-ID vergeben ist: `es.mohs.familie` z. B. in `es.mohs.familie2` ändern.
4. iPhone per Kabel anschließen, oben als Ziel auswählen und **▶︎ Run** drücken.
5. Beim ersten Start auf dem iPhone: **Einstellungen → Allgemein → VPN & Geräteverwaltung → Entwickler-App vertrauen**.
6. Ab iOS 16 zusätzlich: **Einstellungen → Datenschutz & Sicherheit → Entwicklermodus** einschalten.

### Auf die iPhones der Familie bringen

- **Kostenlose Apple-ID:** Du kannst jedes iPhone wie oben per Kabel bespielen. Die App läuft dann aber nur **7 Tage** und muss danach neu installiert werden. Außerdem sind maximal 3 Geräte möglich.
- **Apple Developer Program (99 €/Jahr):** Die App läuft ein Jahr. Am bequemsten verteilst du sie über **TestFlight**:
  1. In Xcode *Product → Archive* wählen und dann *Distribute App → TestFlight Internal Only*.
  2. Die Familie in App Store Connect als Tester einladen.
  3. Updates kommen dann automatisch über die TestFlight-App.

## Anmelden

Jeder meldet sich mit **seinem eigenen Home-Assistant-Benutzer** an (Benutzername + Passwort). Vanessa, Emma und Leoni haben bereits Benutzer. Die Server-Adresse `https://ha.mohs.es` ist schon eingetragen.

Die Anmeldung läuft genauso wie in der HA-Weboberfläche. Die App speichert nur ein Token im iOS-Schlüsselbund, **nie das Passwort**. Unter *Einstellungen → Abmelden* wird das Token in HA widerrufen.

Alternativ lässt sich auf dem Anmeldebildschirm ein langlebiges Token verwenden.

## Anpassen

Alles Hausspezifische steht in **`FamilyHub/FamilyConfig.swift`**:

- **Personen:** Farben und welcher Sensor das Schulende liefert.
- **Müll-Sensoren.**
- **Kalender:** Leer lassen heißt „alle anzeigen“. `hiddenCalendars` blendet einzelne aus.
- **To-do-Listen:** Leer lassen heißt „alle anzeigen“.
- **Schalter im Tab „Steuern“:** Eintrag kopieren, Entität und Symbol anpassen. Die Symbole sind SF Symbols, alle Namen zeigt die kostenlose App „SF Symbols“ von Apple. Mit `confirm: true` kommt eine Sicherheitsabfrage.

Danach einfach neu bauen.

## Wichtig: Kalender in Home Assistant einrichten

Die fünf Familienkalender (`calendar.jan`, `calendar.emma` …) **existieren in Home Assistant derzeit nicht mehr**. Deshalb zeigt auch der Wochenplaner im Dashboard nur „Keine Termine“. Im Moment findet die App nur den Feiertagskalender.

Sobald wieder Kalender in HA sind, erscheinen sie automatisch in der App, ohne neu zu bauen. Möglichkeiten:

- **Lokaler Kalender** (Einstellungen → Geräte & Dienste → Integration hinzufügen → „Local Calendar“), einmal pro Person. Mit der App kann man dann Termine **anlegen**.
- **Google Kalender** oder **CalDAV** (z. B. iCloud), falls ihr eure Termine dort führt. Anlegen geht dann je nach Integration.

Das **+** im Kalender erscheint nur, wenn mindestens ein Kalender das Anlegen von Terminen unterstützt.

## Hinweise

- Home Assistant kennt **keine Rechte pro Gerät**. Ein angemeldeter Nicht-Admin-Benutzer könnte technisch jeden Dienst aufrufen. Die App zeigt aber nur die in `FamilyConfig.swift` festgelegten Schalter.
- Die App wurde nicht auf einem Mac kompiliert, sondern gegen die Live-API von HA getestet. Meldet Xcode beim ersten Bauen einen Fehler, schick mir die Meldung, dann behebe ich ihn.
