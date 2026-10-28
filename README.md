# WBCE Portable

Komplett portables [WBCE CMS](https://github.com/WBCE/WBCE_CMS) für Windows – **Apache + PHP + MariaDB** in einem Ordner. Auf einen USB-Stick entpacken, `WBCE-Portable.exe` starten, fertig. Keine Installation, keine Administratorrechte, nichts in der Registry.

*English: a fully portable WBCE CMS bundle for Windows (Apache + PHP + MariaDB). Unzip to a USB stick, run `WBCE-Portable.exe`, click "Server starten". Installer values are listed below.*

## Schnellstart

1. **[ZIP herunterladen](https://github.com/Beachbone/wbce-portable/releases)**, dann **vor dem Entpacken**: Rechtsklick auf die ZIP → *Eigenschaften* → unten **„Zulassen“** ankreuzen → *OK* (siehe Kasten unten). Danach auf den Stick oder in einen Ordner entpacken (Pfad ohne Umlaute/Sonderzeichen).
2. **`WBCE-Portable.exe`** starten → **Server starten** klicken. Der Browser öffnet `http://localhost:4443/wbce`.

> **Windows blockiert die EXE?** Dateien aus dem Internet tragen die Markierung „Mark of the Web“; Windows zeigt dann eine SmartScreen-Warnung oder lässt die EXE gar nicht starten. Am einfachsten setzt man **vor dem Entpacken** bei der ZIP den Haken *„Zulassen“* (Eigenschaften der Datei) – dann sind alle entpackten Dateien freigegeben. Nachträglich geht es in PowerShell mit `Get-ChildItem -Recurse "C:\Pfad\zu\WBCE-Portable" | Unblock-File`. Bei der SmartScreen-Meldung hilft *„Weitere Informationen“ → „Trotzdem ausführen“*. Die EXE ist (noch) nicht signiert.
>
> **Visual C++ Runtime:** Die nötigen Microsoft-Bibliotheken (`vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll`, Version 14.51) liegen direkt bei Apache und PHP im Ordner (*App-local Deployment*). Es muss also **nichts installiert** werden und es sind **keine Administratorrechte** nötig – auch nicht auf gesperrten Rechnern.

Beim ersten Start folgt der WBCE-Installer (Werte siehe unten). Zum Beenden **Server stoppen** klicken und erst danach den Stick abziehen.

Voraussetzung: Windows 10/11 (64 Bit). Die ZIP ist ca. 110 MB groß (mit `SHA256SUMS.txt`).

Enthalten (Release 0.3.0): WBCE CMS 1.6.9 · Apache 2.4.69 · PHP 8.3.36 · MariaDB 11.4.13 · Adminer 4.8.1 · Microsoft VC++ Runtime-DLLs 14.51

## Benutzung im Detail

1. ZIP auf den Stick oder in einen Ordner entpacken (Pfad ohne Umlaute/Sonderzeichen).
2. `WBCE-Portable.exe` starten und **Server starten** klicken. Der Browser öffnet `http://localhost:4443/wbce`.
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

## PHP-Version wechseln

Im Launcher steht unten rechts die aktive PHP-Version (z. B. „PHP 8.3.36“). Ein Klick darauf öffnet eine kleine Liste mit den installierten und den bei [php.net](https://windows.php.net/download/) verfügbaren Versionen (8.2 bis 8.5, thread safe, x64; ältere sind nicht mehr unterstützt). **Herunterladen und aktivieren** lädt die gewählte Version von `downloads.php.net`, prüft die SHA-256-Prüfsumme aus dem offiziellen Manifest `releases.json`, entpackt sie in einen eigenen Ordner (`php-8.5.12-1\`) und merkt sie sich in `php-active.txt`. Gewechselt wird nur bei **gestopptem Server**; Seiten und Datenbank bleiben unverändert, und die bisherige Version bleibt zum Zurückwechseln erhalten. Nur beim Öffnen dieser Liste baut das Programm eine Internetverbindung auf. `start.bat` beachtet die Auswahl ebenfalls. Zum Aufräumen einen nicht mehr benötigten Ordner `php-…` einfach löschen (nicht die aktive Version).

## Selbst bauen

Voraussetzungen: Windows, PowerShell 5.1, Internet (Downloads), [Lazarus](https://www.lazarus-ide.org/) (FPC 3.2.x) für den Launcher.

```powershell
# 1. Launcher kompilieren
lazbuild launcher\wbce_portable.lpi        # erzeugt launcher\WBCE-Portable.exe

# 2. Bundle bauen (lädt Apache, PHP, MariaDB, Adminer, WBCE; ~400 MB)
powershell -ExecutionPolicy Bypass -File .\build-wbce-portable.ps1 [-WbceVersion 1.6.9 | -WbceZip C:\pfad\wbce.zip] [-PhpBranch 8.3]

# 3. Release-ZIP packen (nur im sauberen Zustand: data\, logs\, tmp\ leer, keine config.php)
powershell -ExecutionPolicy Bypass -File .\make-zip.ps1 -Version 0.2.0_WBCE-1.6.9
```

**Update auf neue Komponenten:** Versionen/URLs von Apache, MariaDB und Adminer im Block `$Downloads` am Anfang von `build-wbce-portable.ps1` anpassen (WBCE per `-WbceVersion`, PHP per `-PhpBranch`: Version, Datei und SHA-256 kommen automatisch aus `releases.json` von php.net), dann `build-wbce-portable.ps1 -Clean` ausführen (leert Download-Cache sowie `Apache24`, `php`, `mariadb`; `data`, `htdocs\wbce`, `logs` und `tmp` bleiben unberührt), das Bundle sauber machen (`data\`, `logs\`, `tmp\` leer, keine `config.php`) und mit `make-zip.ps1 -Version <neue Version>` packen. Die Microsoft-Runtime-DLLs werden dabei automatisch in der aktuellen Version von Microsoft geholt.

Beim Bauen werden Debug-Symbole (`*.pdb`), Entwicklerdateien (`include`, `*.lib`) und Backup-Werkzeuge entfernt; das spart rund 140 MB im Bundle.

Der Launcher (`launcher/`) startet und stoppt MariaDB und Apache unsichtbar im Hintergrund, schreibt die Konfiguration bei jedem Start mit dem aktuellen Pfad neu (Laufwerksbuchstabe egal), initialisiert die Datenbank beim ersten Start und fährt MariaDB beim Stoppen sauber herunter. `WBCE-Portable.exe /start` startet den Server direkt; `/phpswitch:8.5` lädt und aktiviert die neueste PHP-Version eines Zweigs, `/phpuse:php-8.3.36-1` aktiviert eine vorhandene Version (beides ohne Oberfläche, zum Testen); `/selftest` führt Start → Stopp → Beenden aus (Log in `logs\launcher-selftest.txt`).

## Lizenz

Build-Skripte und Launcher-Quellcode: [MIT](LICENSE). Die gebündelten Programme (Apache, PHP, MariaDB, WBCE CMS, Adminer) sind eigenständige Werke unter ihren eigenen Lizenzen – Details und Quellen in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
