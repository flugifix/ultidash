# UltiDash

LVGL-Dashboard-Widget für EdgeTX / Rotorflight (RadioMaster TX16S/TX15, EdgeTX 2.12).

UltiDash basiert auf **HeliDash** und integriert die Funktionen von drei Widgets von
Rob „bob00" Gayle:

| Quelle | Übernommene Funktion |
|-----------|----------------------|
| **HeliDash** | Grundgerüst, Layout, LVGL-Aufbau, Telemetrie, Flugstatistik |
| **ePowerbar** | Batterie-Modell (Reserve/Fuel), diskrete Farben, Cell-Check, Voice-/Vibrations-Alerts |
| **eBitmap** | Modell-/Heli-Bild aus `/images/` |
| **eStatus** | Throttle %, ESC-Fehler-Decoder (Multi-Hersteller), Arm-Disable-Gründe, Armed/Disarm-Ansage |

---

## 1. Dateien

| Datei | Inhalt |
|-------|--------|
| `main.lua` | Einstiegspunkt, registriert das Widget (`useLvgl = true`) |
| `ultidash.lua` | UI-Aufbau (Flight- & Stats-View), Lifecycle (create/update/refresh) |
| `ultidashFunctions.lua` | Telemetrie-Updates, Batterie-Logik, Callout-Engine, eStatus |
| `ultidashValues.lua` | Werte-Tabelle mit Formatierungs-/Farb-Gettern |
| `ultidashRf.lua` | RF-Service: Verbindungsstatus, MSP (Batterieprofil, Flugstatistik) |
| `ultidashOptions.lua` | Konfigurationsoptionen + Übersetzungen |
| `ultidashEsc.lua` | Multi-Hersteller-ESC-Status/Fehler-Decoder (aus eStatus) |

---

## 2. Konfiguration

Alle Optionen erscheinen in der EdgeTX-Widget-Konfiguration.

| Option | Typ | Default | Bereich | Bedeutung |
|--------|-----|---------|---------|-----------|
| **Timer** | TIMER | 0 | – | Welcher Modell-Timer für die Flugzeit-Reset-Erkennung genutzt wird (nicht mehr angezeigt) |
| **BGFilled** | BOOL | 0 (aus) | – | Hintergrundfarbe füllen |
| **Reserve** | VALUE | 20 | 0–40 | Reserve-Kapazität in %. 0 % Anzeige = Reserve erreicht (ePowerbar-Modell) |
| **CalloutInt** | VALUE | 6 | 1–60 | Mindestabstand zwischen Voice-Callouts (Sekunden) |
| **Haptic** | BOOL | 1 (an) | – | Vibration bei kritischen Alerts |
| **Mute** | CHOICE | None | None / Voltage alerts / Voltage and fuel alerts | Welche Voice-Alerts stummgeschaltet werden |
| **StatsViewMode** | CHOICE | On disarmed | Never / On disarmed / On disconnected | Wann die Statistik-Seite gezeigt wird |
| **VoltageDisplay** | CHOICE | Cell voltage | Cell voltage / Battery voltage | Ob Zell- oder Gesamtspannung angezeigt wird |
| **CellFull** | VALUE | 412 | 0–480 | Volle Zellspannung in **Centivolt** (4,12 V) – für Startup-Cell-Check |
| **CellLow** | VALUE | 345 | 0–440 | Untere Zellspannung in cv (3,45 V) – Low-Voltage-Alert |
| **CellCritical** | VALUE | 330 | 0–440 | Kritische Zellspannung in cv (3,30 V) – Critical-Alert |
| **StartupDelay** | VALUE | 4 | 1–20 | Dauer des Startup-Cell-Checks (Sekunden) |
| **LinkWarn** | BOOL | 1 (an) | – | Link-/Telemetrie-Warnungen ein/aus (Verlust + niedrige RQly) |
| **RQlyWarn** | VALUE | 50 | 0–100 | RQly-Warnschwelle in % (ELRS Link Quality) |
| **RQlyCrit** | VALUE | 30 | 0–100 | RQly-Kritisch-Schwelle in % (mit Vibration) |

> **Hinweis:** Zellspannungen werden in **Centivolt** angegeben (412 = 4,12 V).

---

## 3. Anzeige / Views

UltiDash hat zwei automatisch umgeschaltete Ansichten.

### Umschaltlogik (`StatsViewMode`)
- **armiert** → immer **Flight-View**
- **Never** oder noch nie armiert → immer Flight-View
- **On disarmed** → Stats-View sobald disarmed
- **On disconnected** → Stats-View nur bei getrennter Verbindung
- Im **Simulator** wechseln die Views alle 5 s automatisch (Vorschau)

### 3.1 Flight-View

```
┌───────────────────────────────────────┐
│ Datum/Zeit          Funken-Akku [###]  │  ← Top-Leiste
├─────────────┬──────────┬─────────────┤
│ STATUS      │  AKKU    │  WERTE      │
│ (links)     │ (mitte)  │  (rechts)   │
├─────────────┴──────────┴─────────────┤
│           Status-Leiste               │
└───────────────────────────────────────┘
```

**Top-Leiste** (ersetzt die EdgeTX-Topbar für den Vollbild-Betrieb):
- **links:** Datum + Uhrzeit (`getDateTime()`)
- **rechts:** Funken-(TX-)Batterie als kompaktes Icon mit **% direkt auf dem Icon**
  und Spannung daneben; Füllung grün/rot je nach Warnschwelle (aus `getGeneralSettings`)
- *Lautstärke ist bewusst nicht enthalten* – EdgeTX-Lua kann den Pegel nicht auslesen
  (kein `getVolume`); siehe Abschnitt 9.

**Links – Status-Panel** (von oben nach unten):
1. **Modell-Bild** (eBitmap) – fester reservierter Bereich (~32 % der Panel-Höhe),
   Bild oben verankert im echten Seitenverhältnis (kein Schweben). Der feste Bereich
   sorgt dafür, dass die Zeilen darunter bei unterschiedlichen Bildformaten **nicht
   verrutschen**.
2. **Flüge** + **Gesamtflugzeit** (aus RF-MSP-Flugstatistik) – direkt unter dem Bildbereich
3. **Headline-Zeile: Governor State** (links) + **Throttle %** (rechts)
4. **ESC-/Arming-Statuszeile** (volle Breite, farbig). Zeigt ESC-Fehler bzw.
   Arming-Disable-Gründe. Wenn nichts anliegt, ein gedämpfter Platzhalter:
   „No telemetry" (getrennt), „Ready" (disarmed, OK) oder „Armed - OK" (armiert, OK)
5. **Profile · Rate · Batt-Profil** in einer 3-Spalten-Reihe

**Mitte – vertikale Batterie** (siehe Abschnitt 4)

**Rechts – Werte-Panel** (5 Zeilen):
- Spannung (Zell- oder Gesamtspannung, farbcodiert)
- Headspeed
- Strom (Curr)
- ESC-Temperatur
- BEC-Spannung

**Status-Leiste unten:** `Model: <Name>` · Arm-Zustand (Armed/Disarmed) · `Skp: <n>`
(„Skp" = Zähler verworfener Telemetriepakete; die TX-Akku-Anzeige steckt jetzt oben in der Top-Leiste)
→ Bei Arming-Disable-Flags wird stattdessen die Warnung „Arming Disabled: …" angezeigt.

### 3.2 Stats-View

- **Kopfzeile:** Modellname · Gesamtflugzeit · Anzahl Flüge
- **Tabelle** (Actual / Min / Max) für: Spannung, Headspeed, Strom, ESC-Temp, BEC
- **Info-Karten:** Flugzeit · mAh verbraucht (%) · Batt-Profil
- **Status-Leiste:** TPWR+ · RQly- · Tmcu+ · Skp

> Die Stats-Karte „mAh Used (%)" zeigt den **rohen** Bat%-Wert (nicht reserve-bereinigt).
> Nur die Flight-View-Batterie nutzt den reserve-bereinigten Wert.

**„Flight Time" (lokaler Session-Timer):** wird hochgezählt, solange der **Rotor dreht**,
gemessen direkt am **Headspeed-Sensor** (`Hspd > 100 rpm`) — **RFTool-unabhängig**.
Fehlt der Headspeed-Sensor, greift als Fallback der RF-Governor-State (braucht
RFTool-Verbindung), sonst der RFTool-Armed-Status. Akkumuliert in Zentisekunden, läuft
auch im **Hintergrund** (nicht nur auf dem aktiven Screen). Reset bei
Telemetrie-(Wieder-)Verbindung und bei Reset des Modell-`Timer`.
Abzugrenzen von **„Total Flight Time"/„Flights"** in der Kopfzeile = kumulativ aus dem
RF-Flightcontroller (MSP).
> **Voraussetzung:** der `Hspd`-Sensor muss aktiv sein (rechtes Panel „Headspeed" zeigt
> einen Wert). Das ist jetzt die Hauptabhängigkeit der Flugzeit.

---

## 4. Zentrale Batterie-Anzeige (ePowerbar-Modell)

### Fuel-Berechnung (reserve-bereinigt)
```
roh        = Bat%-Sensor
fuel       = (roh − Reserve) / (100 − Reserve) × 100
```
- **0 % Anzeige = Reserve erreicht** (sicher landen)
- Bei `Reserve = 0` wird der rohe Wert genutzt

### Diskrete Farben (ePowerbar)
| Zustand | Farbe |
|---------|-------|
| `fuel ≤ kritisch` (kritisch = 0 wenn Reserve > 0) | **Rot** |
| `fuel ≤ kritisch + 20` | **Gelb** |
| sonst | **Grün** |
| Akku beim Start nicht voll | **Amber** |
| während Startup-Cell-Check | **Grau** |

### Overlays in der Batterie
- **oben:** Zellenzahl (z. B. „6S")
- **mitte:** großer Prozentwert (`--` während Cell-Check)
- **unten:** mAh-Zahl groß, Einheit „mAh" klein darunter
- Zellspannung wird **nicht** in der Batterie gezeigt (steht im rechten Werte-Panel);
  das rechte „Cell Voltage"-Label trägt keine „(NS)"-Endung mehr (Zellenzahl steht nun
  in der Batterie), damit es nicht umbricht
- Segmente sind bewusst grob (wenige, dicke Stufen) für einen kräftigen Look
- Leerer Balkenbereich = **hellgrau** (`0xC8C8C8`, wie ePowerbar) statt tiefem Schwarz
- Overlay-Texte = **schlichtes Schwarz** (keine Kontur) – auf hellgrau/grün/gelb klar
  lesbar; bei kritischem (rotem) Füllstand sitzt der Balken ohnehin fast leer, sodass
  die Texte überwiegend über dem grauen Bereich liegen

### Startup-Cell-Check
Beim Erscheinen der Spannung (Einschalten/Verbinden):
1. Grauer Fortschrittsbalken für `StartupDelay` Sekunden
2. Danach Vergleich Zellspannung vs. `CellFull`:
   - voll → grün
   - nicht voll → amber + **`batlow`-Ton** + gesprochene Gesamtspannung

---

## 5. Voice-Callouts & Vibration

Es gibt **sechs** Auslöser:

| # | Auslöser | Bedingung | Ausgabe | gated durch | Läuft im Hintergrund? |
|---|----------|-----------|---------|-------------|----------------------|
| 1 | **Startup-Cell-Check** | nach `StartupDelay`, wenn Zelle < `CellFull` | `batlow` + Spannung | – | nein (nur aktiver Screen) |
| 2 | **Fuel-Callout** | verbunden **und** armiert; je nach Füllstand | `battry`/`batlow`/`batcrt` + % (+ Vibration bei kritisch) | `Mute` ab „Voltage and fuel alerts" | **ja** |
| 3 | **Spannungs-Alert** | verbunden **und** armiert; Zelle ≤ `CellLow`/`CellCritical` | `batlow`/`batcrt` + Gesamtspannung (+ Vibration bei kritisch) | `Mute` ab „Voltage alerts" | **ja** |
| 4 | **Armed/Disarm** | Wechsel des Arm-Zustands | `armed` / `disarm` | – | nein (nur aktiver Screen) |
| 5 | **Telemetrie verloren / wiederhergestellt** | **nur armiert**: Verlust aus dem Zustand `armed`; „zurück" nur wenn der Verlust armiert war | tiefer Ton + Vibration (verloren) / kurzer hoher Ton (zurück) | `LinkWarn` | **ja** |
| 6 | **Link-Qualität niedrig** | **nur armiert**; RQly ≤ `RQlyWarn`/`RQlyCrit` | Ton (Schweregrad) + RQly-% (+ Vibration bei kritisch) | `LinkWarn` | **ja** |

Details:
- **Fuel-Callout (2):** Wert auf 10er gerundet (über Reserve), Einzelschritte nahe kritisch; erster Sample nach Armieren wird übersprungen; min. Abstand `CalloutInt`.
- **Spannungs-Alert (3):** Entprellung (0,5 s halten), dann frühestens nach `CalloutInt`. Schwellen aus `CellLow`/`CellCritical`.
- **Telemetrie verloren (5):** **nur wenn der Verlust aus dem armierten Zustand erfolgt** (echter In-Flight-Verlust). Verluste am Boden / disarmed bleiben stumm (nur Log). Der „wiederhergestellt"-Ton kommt nur, wenn zuvor ein armierter Verlust gemeldet wurde. Quelle = RF-Verbindungsstatus (nicht rohes RSSI). ⚠️ EdgeTX hat ggf. einen **eigenen** „Telemetry lost"-Callout → kann doppelt kommen, dann den EdgeTX-Trigger deaktivieren.
- **Link-Qualität (6):** ELRS **RQly** (Link Quality %), **nur armiert**; Entprellung 0,5 s, dann frühestens nach `CalloutInt`. Töne statt Sprach-Files, damit es sich von den Akku-Ansagen unterscheidet.
- **Hintergrund:** 2, 3, 5, 6 laufen auch, wenn UltiDash nicht der aktive Screen ist (sofern armiert).

---

## 6. Benötigte Telemetrie-Sensoren

Fest verdrahtete Rotorflight-Sensornamen (keine konfigurierbaren Quellen):

| Sensor | Verwendung |
|--------|-----------|
| `Vbat` / `Vbat-` / `Vbat+` | Gesamtspannung + Min/Max |
| `Vcel` / `Vcel-` / `Vcel+` / `Cel#` | Zellspannung + Min/Max + Zellzahl |
| `Curr` | Strom |
| `Capa` | verbrauchte Kapazität (mAh) |
| `Bat%` | Füllstand (Basis für Fuel) |
| `Vbec` / `Vbec-` / `Vbec+` | BEC-Spannung |
| `Tesc` / `Tesc-` / `Tesc+` | ESC-Temperatur |
| `Tmcu+` | MCU-Temperatur (Max) |
| `Hspd` | Headspeed |
| `Gov` | Governor-Status |
| `ARMD` | Arming-Disable-Flags |
| `PID#` / `RTE#` / `BAT#` | Profil / Rate / Batterieprofil |
| `Thr` | **Throttle (eStatus)** |
| `Esc#` / `EscF` | **ESC-Signatur + Statusflags (eStatus)** |
| `RQly` / `RQly-` | **Link Quality aktuell (Link-Warnung)** / Min |
| `TPWR+` | TX-Power (Max) |
| `Skp` | Zähler nicht ausgewerteter/verworfener Telemetriepakete (Statusleisten unten) |

EdgeTX-Telemetrie-Setup (Basis, ESC-Sensoren `Esc#`/`EscF` zusätzlich aktivieren):
```
telemetry_sensors = 3,4,5,6,7,8,43,50,52,60,90,91,93,95,96,...
```

---

## 7. ESC-Status-Decoder (eStatus)

`ultidashEsc.lua` übersetzt `EscF`-Statuscodes je nach `Esc#`-Signatur in Klartext.
Unterstützte Hersteller:

| Signatur | Hersteller |
|----------|-----------|
| `0xA5` | OpenYGE / YGE |
| `0x53` | Scorpion / Tribunus |
| `0xFD` | HobbyWing Platinum/HW5 |
| `0x73` | FLYROTOR |
| `0xD0` | OMP / OFW |
| `0xC8` | BLHeli_32 |
| `0xFF` | „RESTART ESC" (Sonderfall) |
| sonst | generischer Statuscode |

Schweregrade (Textfarbe): **Trace** (grau) · **Info** (Theme) · **Warn** (gelb) · **Error** (rot).
Die schlimmste Meldung wird bis zur nächsten (Wieder-)Verbindung gehalten.

### Statuszeile – was wird wann angezeigt?

Reihenfolge = Priorität (oberste passende Regel gewinnt):

| Zustand | Anzeige | Farbe |
|---------|---------|-------|
| disarmed **und** Arming-Disable-Flags aktiv | Gründe, z. B. `* NOGYRO THROTTLE` | Gelb (WARNING) |
| ESC meldet Neustart (Signatur `0xFF`) | `RESTART ESC` | Rot |
| ESC-Fehler erkannt (`Esc#`/`EscF`) | Klartext, z. B. `ESC Over Temp` | Gelb/Rot je Schweregrad |
| ESC verbunden, kein Fehler | z. B. `BLHeli_32 ESC OK` | Theme (Info) |
| verbunden, **keine** ESC-Sensoren, disarmed | `Ready` | Grau (gedämpft) |
| verbunden, **keine** ESC-Sensoren, armiert | `Armed - OK` | Grau (gedämpft) |
| keine Telemetrie | `No telemetry` | Grau (gedämpft) |

Die grauen Platzhalter (`Ready` / `Armed - OK` / `No telemetry`) erscheinen nur, wenn
es nichts Konkretes zu melden gibt – so ist erkennbar, dass das Feld lebt.

### Governor State – was wird wann angezeigt?

Aus dem `Gov`-Sensor (RF-interner Governor). Werte:

| Code | Anzeige |
|------|---------|
| 0 | Throttle off |
| 1 | Throttle Idle |
| 2 | Spooling up |
| 3 | Recovery |
| 4 | Gov. Active |
| 5 | Throttle Hold |
| 6 | Gov. Fallback |
| 7 | Autorotation |
| 8 | Bailing Out |
| unbekannt | Gov. Disabled |
| kein Wert | `-` |

### Throttle – was wird wann angezeigt?

| Zustand | Anzeige |
|---------|---------|
| keine Telemetrie | `**` |
| disarmed | `Safe` |
| armiert (mit `Thr`-Sensor) | z. B. `47%` |
| armiert, kein `Thr`-Sensor | `--` |

---

## 8. Abhängigkeiten

- **Keine externen Bibliotheken** – UltiDash lädt ausschließlich eigene Dateien.
  Insbesondere **kein `eLib`/`lib_common`/`loadGUI`** (anders als die Original-Widgets
  ePowerbar/eStatus/eBitmap, deren eLib-Nutzung beim Portieren ersetzt wurde).
- **RFTool-Widget** muss vorhanden sein (`rf2`-Global) → liefert Verbindungsstatus
  (armed/disarmed/connected/disconnected) und MSP-Daten (Batterieprofil, Flugstatistik).
  Fehlt es, bleibt der Status „disconnected" bzw. die Leiste zeigt „RFTools widget missing".
  **MSP-Reads erfolgen nur beim Verbinden/Disarmen – nie im armierten Flug.**
- **Sounds** in `/SOUNDS/en/`:
  - `batcrt.wav`, `batlow.wav`, `battry.wav` (mitgeliefert)
  - `armed.wav`, `disarm.wav` (für Arm-Ansage – meist im EdgeTX-Standard-Voicepack)
- **Modell-Bilder** in `/images/`:
  - Suchreihenfolge: `<Modellname>-<Zellzahl>S` → `<Modellname>` → EdgeTX-Modell-Bitmap
  - Endungen: `.png`, `.bmp`, `.jpg`, `.jpeg`
  - Fehlt das Bild, bleibt der Bereich leer (kein Fehler)

---

## 9. Bekannte Einschränkungen

- Sensor-Quellen sind fest (keine Auswahloptionen wie in ePowerbar/eStatus).
- Startup-Cell-Check und Armed/Disarm-Ansage laufen nur auf dem **aktiven Screen**.
- Stats-View „mAh Used (%)" zeigt den rohen, nicht reserve-bereinigten Prozentwert.
- Beim Ändern des Optionssatzes (z. B. nach Update) ggf. die Widget-Optionen
  einmal kontrollieren/neu setzen.

---

## 10. Credits & Lizenz

UltiDash ist ein zusammengeführtes/abgeleitetes Werk und nutzt Code, Logik und
Darstellungskonzepte folgender Widgets – alle Credits an die jeweiligen Autoren:

| Widget | Autor | Übernommen |
|--------|-------|-----------|
| Widget | Autor / Quelle | Lizenz | Übernommen |
|--------|----------------|--------|-----------|
| **HeliDash** | gismo2004 – [HeliWidget](https://github.com/gismo2004/HeliWidget) | **keine** (siehe unten) | Basis: Layout, LVGL-UI, Telemetrie, Flugstatistik |
| **ePowerbar** | Rob 'bob00' Gayle – [etx-widgets](https://github.com/bob01/etx-widgets) | GPLv3 | Akku-/Reserve-Modell, diskrete Farben, Cell-Check, Callout-Engine (selbst basierend auf „Lipo battery from single analog source" von Offer Shmuely) |
| **eBitmap** | Rob 'bob00' Gayle – etx-widgets | GPLv3 | Modell-/Heli-Bild aus `/images/` |
| **eStatus** | Rob 'bob00' Gayle – etx-widgets | GPLv3 | Throttle %, Multi-Hersteller-ESC-Decoder, Arming-Disable-Gründe |
| **BattAnalog** | Offer Shmuely – [edgetx-x10-widgets](https://github.com/offer-shmuely/edgetx-x10-widgets) | GPLv2 (laut Datei-Header) | nur der **Stil** des kompakten Top-Bar-Batterie-Icons (kein verbatim-Code) |

**Lizenz-Status (geprüft):**
- **etx-widgets** (ePowerbar/eBitmap/eStatus): Repo-LICENSE = **GPLv3** (die Datei-Header
  nennen noch „GPLv2", aber die Repo-LICENSE ist maßgeblich).
- **HeliWidget/HeliDash** (gismo2004) – die **Basis und damit der Großteil des Codes** –
  hat **keine** Lizenzdatei. Der Autor beschreibt es als „personal hobby project shared
  freely with the community" (as-is). Das ist **kein** formaler Open-Source-Lizenztext.
- **BattAnalog** (Offer Shmuely): kein Repo-LICENSE, nur Datei-Header „GPLv2"; hier wurde
  nur das **optische Konzept** des Icons neu umgesetzt, kein Code kopiert.

**Angestrebte Lizenz: GPLv3 – aber als Gesamtwerk noch nicht sauber lizenzierbar.**

- Für die eigenen UltiDash-Teile und die etx-widgets-abgeleiteten Teile ist **GPLv3**
  vorgesehen (http://www.gnu.org/licenses/gpl-3.0.html).
- **Wichtig:** „Keine Lizenz" (HeliDash-Basis) bedeutet **nicht** „frei verwendbar",
  sondern standardmäßig *alle Rechte vorbehalten*. Nur **gismo2004** kann seinen Code
  lizenzieren – er lässt sich hier **nicht** einseitig unter GPLv3 stellen.
- Daher ist das **Gesamtwerk noch nicht** sauber GPLv3. Eine *formale* Veröffentlichung
  setzt voraus, dass gismo2004 die HeliDash-Basis lizenziert (idealerweise GPLv3 oder
  „GPLv2 or later"). Für die **private Nutzung** spielt das keine Rolle.

*(Allgemeinverständliche Zusammenfassung, keine Rechtsberatung.)* Vollständiger
Lizenz-Header zusätzlich in `main.lua`.
