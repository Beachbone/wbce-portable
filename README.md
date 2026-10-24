# WBCE Portable

Komplett portables [WBCE CMS](https://github.com/WBCE/WBCE_CMS) für Windows – **Apache + PHP + MariaDB** in einem Ordner. Auf einen USB-Stick entpacken, `WBCE-Portable.exe` starten, fertig. Keine Installation, keine Administratorrechte, nichts in der Registry.

*English: a fully portable WBCE CMS bundle for Windows (Apache + PHP + MariaDB). Unzip to a USB stick, run `WBCE-Portable.exe`, click "Server starten". Installer values are listed below.*

## Schnellstart

1. **[ZIP herunterladen](https://github.com/Beachbone/wbce-portable/releases)** und auf den Stick oder in einen Ordner entpacken (Pfad ohne Umlaute/Sonderzeichen).
2. **`WBCE-Portable.exe`** starten → **Server starten** klicken.
3. **Fragt das Programm „Jetzt installieren?“ → mit *Ja* bestätigen.** Das ist das einmalig nötige Microsoft-Paket *Visual C++ Runtime (x64)*; Windows fragt dabei nach Administratorrechten, die Installation dauert ca. 1 Minute und danach startet der Server von selbst. Der Browser öffnet `http://localhost:4443/wbce`.

> **Zum Visual C++ Runtime:** Der Webserver (Apache) braucht das kostenlose Microsoft-Paket *Visual C++ Redistributable (x64), Version 14.50 oder neuer*. WBCE Portable **prüft das bei jedem Start selbst** und installiert es nach Rückfrage, wenn es fehlt oder zu alt ist – der Installer liegt in der ZIP (Ordner `vcredist`), es funktioniert also auch ohne Internet. Nötig ist das **einmal pro PC**, an dem der Stick benutzt wird, und dafür ein Benutzer mit Administratorrechten. Ohne dieses Paket würde der Server mit Meldungen wie *„VCRUNTIME140.dll fehlt“* oder *„MSVCP140.dll fehlt“* nicht starten.
> Manuell geht es auch: [`vc_redist.x64.exe` von Microsoft](https://aka.ms/vc14/vc_redist.x64.exe) oder `vcredist\vc_redist.x64.exe` aus der ZIP als Administrator ausführen.

Beim ersten Start folgt der WBCE-Installer (Werte siehe unten). Zum Beenden **Server stoppen** klicken und erst danach den Stick abziehen.

Voraussetzung: Windows 10/11 (64 Bit). Die ZIP ist ca. 170 MB groß (mit `SHA256SUMS.txt`).

Enthalten (Release 0.1.1): WBCE CMS 1.6.9 · Apache 2.4.69 · PHP 8.3.36 · MariaDB 11.4.13 · Adminer 4.8.1 · Microsoft VC++ Runtime Installer

## Benutzung im Detail

1. ZIP auf den Stick oder in einen Ordner entpacken (Pfad ohne Umlaute/Sonderzeichen).
2. `WBCE-Portable.exe` starten und **Server starten** klicken (ggf. Installation des Visual C++ Runtime bestätigen, siehe oben). Der Browser öffnet `http://localhost:4443/wbce`.
3. Beim ersten Start den WBCE-Installer ausfüllen:

   | Feld | Wert |
   |---|---|
   | Betriebssystem | Windows |
   | Datenbank-Host | `127.0.0.1:3311` (Port mitangeben!) |
   | Datenbankname | `wbce` |
   | Benutzer / Passwort | `root` / *leer* |

   Administrator-Zugang frei wählen.
4. Zum Beenden **Server stoppen** klicken. **Erst danach den Stick abziehen** – sonst können Datenbankdaten beschädigt werden. Beim Schließen des Fensters bei laufendem Server wird automatisch nachgefragt.

Der Server lauscht nur auf `127.0.0.1` (Port 4443 Web, 3311 Datenbank) und ist aus dem Netzwerk nicht erreichbar. Ein echter Autostart beim Einstecken ist unter Windows nicht möglich (`autorun.inf` wird für USB-Sticks ignoriert). `start.bat`/`stop.bat` liegen als Notbehelf bei.

## Selbst bauen

Voraussetzungen: Windows, PowerShell 5.1, Internet (Downloads), [Lazarus](https://www.lazarus-ide.org/) (FPC 3.2.x) für den Launcher.

```powershell
# 1. Launcher kompilieren
lazbuild launcher\wbce_portable.lpi        # erzeugt launcher\WBCE-Portable.exe

# 2. Bundle bauen (lädt Apache, PHP, MariaDB, Adminer, WBCE; ~400 MB)
powershell -ExecutionPolicy Bypass -File .\build-wbce-portable.ps1 [-WbceVersion 1.6.9 | -WbceZip C:\pfad\wbce.zip]

# 3. Release-ZIP packen (nur im sauberen Zustand: data\, logs\, tmp\ leer, keine config.php)
powershell -ExecutionPolicy Bypass -File .\make-zip.ps1 -Version 0.1.0
```

Die Download-URLs und Versionen stehen am Anfang von `build-wbce-portable.ps1` und müssen bei neuen Upstream-Releases angepasst werden.

Der Launcher (`launcher/`) startet und stoppt MariaDB und Apache unsichtbar im Hintergrund, schreibt die Konfiguration bei jedem Start mit dem aktuellen Pfad neu (Laufwerksbuchstabe egal), initialisiert die Datenbank beim ersten Start und fährt MariaDB beim Stoppen sauber herunter. `WBCE-Portable.exe /start` startet den Server direkt; `/selftest` führt Start → Stopp → Beenden aus (Log in `logs\launcher-selftest.txt`).

## Lizenz

Build-Skripte und Launcher-Quellcode: [MIT](LICENSE). Die gebündelten Programme (Apache, PHP, MariaDB, WBCE CMS, Adminer) sind eigenständige Werke unter ihren eigenen Lizenzen – Details und Quellen in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
