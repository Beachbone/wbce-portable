# =============================================================================
# WBCE Portable Builder
# Baut ein komplett portables WBCE-CMS-Bundle (Apache + PHP + MariaDB) in den
# Ordner, in dem dieses Skript liegt. Danach: start.bat doppelklicken,
# Browser oeffnet http://localhost:4443
#
# Voraussetzung: Windows 10/11 x64, Visual C++ Redistributable (x64, aktuell),
# PowerShell 5 (immer vorhanden).
#
# Aufruf:  powershell -ExecutionPolicy Bypass -File .\build-wbce-portable.ps1
#   -WbceVersion "1.6.9"   WBCE-Release von GitHub laden (Standard: 1.6.9)
#   -WbceZip "C:\x.zip"    stattdessen ein vorhandenes WBCE-Archiv verwenden
#   -WbceVersion ""        ohne -WbceZip: WBCE nicht einpacken
# =============================================================================

param(
    [string]$WbceZip = "",
    [string]$WbceVersion = "1.6.9"
)

$ErrorActionPreference = "Stop"
$Base = $PSScriptRoot
if (-not $Base) { $Base = (Get-Location).Path }

# --- Download-Quellen (bei Bedarf Versionsnummern anpassen) -----------------
$Downloads = @{
    # Apache Lounge liefert nur mit Referer + User-Agent die ZIP (sonst HTML-Fehlerseite)
    Apache = "https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.69-261002-Win64-VS18.zip"
    # Aktuelle Version liegt unter /releases/, aeltere wandern nach /releases/archives/
    Php    = "https://downloads.php.net/~windows/releases/php-8.3.36-Win32-vs16-x64.zip"  # Thread-Safe!
    Maria  = "https://archive.mariadb.org/mariadb-11.4.13/winx64-packages/mariadb-11.4.13-winx64.zip"
    Adminer = "https://github.com/vrana/adminer/releases/download/v4.8.1/adminer-4.8.1.php"
}

Write-Host "== WBCE Portable Builder =="

# --- Ordnerstruktur -----------------------------------------------------------
foreach ($d in @("downloads","Apache24","php","mariadb","htdocs","data","logs","tmp")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Base $d) | Out-Null
}

# --- Downloads ----------------------------------------------------------------
function Get-File($url, $target) {
    if (Test-Path $target) { Write-Host "   schon da: $(Split-Path $target -Leaf)"; return }
    Write-Host "   Lade $(Split-Path $target -Leaf) ..."
    $ProgressPreference = "SilentlyContinue"   # PS 5.1: Fortschrittsbalken bremst Downloads massiv
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{}
    if ($url -match "apachelounge\.com") { $headers.Referer = "https://www.apachelounge.com/download/" }
    # Mirrors liefern gelegentlich 502/504 -> bis zu 4 Versuche
    for ($try = 1; $try -le 4; $try++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing `
                -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" `
                -Headers $headers `
                -MaximumRedirection 10
            break
        } catch {
            if (Test-Path $target) { Remove-Item $target -Force }
            if ($try -eq 4) { throw }
            Write-Host "   Fehler (Versuch $try/4), neuer Versuch in 5 s ..."
            Start-Sleep -Seconds 5
        }
    }
    # Plausibilitaet: ZIPs muessen mit "PK" beginnen (sonst HTML-Fehlerseite)
    if ($target -like "*.zip") {
        $fs = [System.IO.File]::OpenRead($target)
        $head = New-Object byte[] 2
        [void]$fs.Read($head, 0, 2)
        $fs.Close()
        if ($head[0] -ne 0x50 -or $head[1] -ne 0x4B) {
            Remove-Item $target -Force
            throw "Download von $url lieferte keine ZIP-Datei (URL veraltet?)"
        }
    }
}

Write-Host "1/6 Lade Komponenten ..."
Get-File $Downloads.Apache  "$Base\downloads\httpd.zip"
Get-File $Downloads.Php     "$Base\downloads\php.zip"
Get-File $Downloads.Maria   "$Base\downloads\mariadb.zip"
Get-File $Downloads.Adminer  "$Base\htdocs\adminer.php"

# --- Entpacken ----------------------------------------------------------------
Write-Host "2/6 Entpacke ..."
Expand-Archive -Path "$Base\downloads\httpd.zip"   -DestinationPath "$Base\_tmp_apache" -Force
Expand-Archive -Path "$Base\downloads\php.zip"     -DestinationPath "$Base\_tmp_php"    -Force
Expand-Archive -Path "$Base\downloads\mariadb.zip"  -DestinationPath "$Base\_tmp_maria"  -Force

# Apache: Zip enthaelt Ordner Apache24
Copy-Item "$Base\_tmp_apache\Apache24\*" "$Base\Apache24\" -Recurse -Force
# PHP: Zip enthaelt die Dateien direkt
Copy-Item "$Base\_tmp_php\*" "$Base\php\" -Recurse -Force
# MariaDB: Zip enthaelt Ordner mariadb-11.x-winx64
$mariaSrc = (Get-ChildItem "$Base\_tmp_maria" -Directory | Select-Object -First 1).FullName
Copy-Item "$mariaSrc\*" "$Base\mariadb\" -Recurse -Force
Remove-Item "$Base\_tmp_apache","$Base\_tmp_php","$Base\_tmp_maria" -Recurse -Force

# --- WBCE optional einpacken --------------------------------------------------
if (-not $WbceZip -and $WbceVersion) {
    $WbceZip = "$Base\downloads\wbce-$WbceVersion.zip"
    Get-File "https://github.com/WBCE/WBCE_CMS/archive/refs/tags/$WbceVersion.zip" $WbceZip
}
if ($WbceZip -and (Test-Path $WbceZip)) {
    Write-Host "3/6 Packe WBCE ein ..."
    Expand-Archive -Path $WbceZip -DestinationPath "$Base\_tmp_wbce" -Force
    New-Item -ItemType Directory -Force -Path "$Base\htdocs\wbce" | Out-Null
    # Zip kann die Dateien direkt oder in einem Unterordner enthalten
    $wbceSrc = "$Base\_tmp_wbce"
    if ((Get-ChildItem $wbceSrc -Directory).Count -eq 1 -and -not (Test-Path "$wbceSrc\index.php")) {
        $wbceSrc = (Get-ChildItem $wbceSrc -Directory | Select-Object -First 1).FullName
    }
    # GitHub-Archiv hat Repo-Struktur: das CMS liegt im Unterordner wbce\
    if (-not (Test-Path "$wbceSrc\index.php") -and (Test-Path "$wbceSrc\wbce\index.php")) {
        $wbceSrc = "$wbceSrc\wbce"
    }
    Copy-Item "$wbceSrc\*" "$Base\htdocs\wbce\" -Recurse -Force
    # Lizenztext liegt im GitHub-Archiv eine Ebene ueber dem CMS-Ordner
    $wbceLic = Join-Path (Split-Path $wbceSrc -Parent) "LICENSE.md"
    if (Test-Path $wbceLic) { Copy-Item $wbceLic "$Base\LICENSE-WBCE.txt" -Force }
    Remove-Item "$Base\_tmp_wbce" -Recurse -Force
} else {
    Write-Host "3/6 WBCE nicht angegeben - spaeter manuell nach htdocs\wbce kopieren."
}

# --- Konfig-Templates schreiben ----------------------------------------------
Write-Host "4/6 Schreibe Konfiguration ..."

# httpd.conf: __BASE__ wird von start.bat bei jedem Start durch den echten Pfad ersetzt.
$httpd = @"
ServerRoot "__BASE__Apache24"
Listen 127.0.0.1:4443
ServerName localhost:4443

LoadModule authz_core_module      modules/mod_authz_core.so
LoadModule authz_host_module      modules/mod_authz_host.so
LoadModule access_compat_module   modules/mod_access_compat.so
LoadModule dir_module             modules/mod_dir.so
LoadModule mime_module            modules/mod_mime.so
LoadModule log_config_module      modules/mod_log_config.so
LoadModule env_module             modules/mod_env.so
LoadModule setenvif_module        modules/mod_setenvif.so
LoadModule rewrite_module         modules/mod_rewrite.so
LoadModule alias_module           modules/mod_alias.so
LoadModule autoindex_module       modules/mod_autoindex.so

LoadFile "__BASE__php/php8ts.dll"
LoadModule php_module "__BASE__php/php8apache2_4.dll"
PHPIniDir "__BASE__php"

TypesConfig conf/mime.types
DirectoryIndex index.php index.html
AddHandler application/x-httpd-php .php

DocumentRoot "__BASE__htdocs"
<Directory "__BASE__htdocs">
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>

ErrorLog "__BASE__logs\apache-error.log"
CustomLog "__BASE__logs\apache-access.log" common
LogLevel warn
"@ | Out-File -FilePath "$Base\conf-httpd.template" -Encoding ascii

# php.ini: ebenfalls __BASE__-Ersetzung
$phpini = @"
[PHP]
extension_dir="__BASE__php\ext"
extension=curl
extension=gd
extension=intl
extension=mbstring
extension=mysqli
extension=pdo_mysql
extension=zip
extension=exif

[Session]
session.save_path="__BASE__tmp"
session.cookie_httponly=On

[Misc]
upload_max_filesize=64M
post_max_size=64M
max_execution_time=120
memory_limit=256M
date.timezone=Europe/Berlin
error_reporting=E_ALL
log_errors=On
error_log="__BASE__logs\php-error.log"
"@ | Out-File -FilePath "$Base\conf-php.template" -Encoding ascii

# my.ini: ebenfalls __BASE__-Ersetzung
$myini = @"
[mysqld]
port=3311
bind-address=127.0.0.1
basedir="__BASE__mariadb"
datadir="__BASE__data"
tmpdir="__BASE__tmp"
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
skip-name-resolve
"@ | Out-File -FilePath "$Base\conf-my.template" -Encoding ascii

# --- start.bat / stop.bat -----------------------------------------------------
Write-Host "5/6 Schreibe start.bat / stop.bat ..."

$startBat = @"
@echo off
setlocal
set BASE=%~dp0
cd /d "%BASE%"
if not exist tmp mkdir tmp

rem PHP-Verzeichnis in den DLL-Suchpfad (curl/intl brauchen libssh2, ICU usw. neben php.exe)
set "PATH=%BASE%php;%PATH%"

rem Konfigs mit echtem Pfad erzeugen (Laufwerksbuchstabe ist egal)
powershell -NoProfile -Command "(Get-Content '%BASE%conf-httpd.template') -replace '__BASE__','%BASE:\=/%' | Set-Content '%BASE%Apache24\conf\httpd.conf'"
powershell -NoProfile -Command "(Get-Content '%BASE%conf-php.template') -replace '__BASE__','%BASE:\=/%' | Set-Content '%BASE%php\php.ini'"
powershell -NoProfile -Command "(Get-Content '%BASE%conf-my.template') -replace '__BASE__','%BASE:\=/%' | Set-Content '%BASE%my.ini'"

rem Datenbank beim ersten Start initialisieren
if not exist "%BASE%data\mysql" (
    echo Initialisiere Datenbank - nur beim ersten Start ...
    "%BASE%mariadb\bin\mariadb-install-db.exe" --datadir="%BASE%data" >nul
)

rem MariaDB starten
start "MariaDB" /min "%BASE%mariadb\bin\mysqld.exe" --defaults-file="%BASE%my.ini"

rem Kurz warten, DB anlegen falls fehlt, dann Apache
timeout /t 3 /nobreak >nul
"%BASE%mariadb\bin\mariadb.exe" --port=3311 -u root -e "CREATE DATABASE IF NOT EXISTS wbce CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
start "Apache" /min "%BASE%Apache24\bin\httpd.exe"

echo WBCE Portable laeuft: http://localhost:4443/wbce
start http://localhost:4443/wbce
"@
$startBat | Out-File -FilePath "$Base\start.bat" -Encoding ascii

$stopBat = @"
@echo off
set BASE=%~dp0
"%BASE%mariadb\bin\mariadb-admin.exe" --port=3311 -u root shutdown
taskkill /F /IM httpd.exe >nul 2>&1
echo Gestoppt. Stick erst jetzt entfernen!
timeout /t 3
"@
$stopBat | Out-File -FilePath "$Base\stop.bat" -Encoding ascii

# --- Lizenzen ins Paket legen -------------------------------------------------
Write-Host "6/6 Lizenzen ..."
Copy-Item "$Base\Apache24\LICENSE.txt" "$Base\LICENSE-Apache.txt" -ErrorAction SilentlyContinue
Copy-Item "$Base\php\license.txt"     "$Base\LICENSE-PHP.txt" -ErrorAction SilentlyContinue
Copy-Item "$Base\mariadb\COPYING"     "$Base\LICENSE-MariaDB.txt" -ErrorAction SilentlyContinue
Copy-Item "$Base\mariadb\THIRD-PARTY" "$Base\NOTICE-MariaDB.txt" -ErrorAction SilentlyContinue
Copy-Item "$Base\LICENSE"             "$Base\LICENSE-WBCE-Portable.txt" -ErrorAction SilentlyContinue

# --- Launcher (Lazarus) und Anleitung ------------------------------------------
$launcherExe = Join-Path $Base "launcher\WBCE-Portable.exe"
if (Test-Path $launcherExe) {
    Copy-Item $launcherExe "$Base\WBCE-Portable.exe" -Force
} else {
    Write-Host "   Hinweis: launcher\WBCE-Portable.exe fehlt (zuerst 'lazbuild launcher\wbce_portable.lpi') - start.bat funktioniert trotzdem."
}

@'
WBCE Portable
=============
Komplett portables WBCE CMS (Apache + PHP + MariaDB) fuer USB-Stick oder
beliebigen Ordner. Keine Installation, keine Adminrechte, nichts in der
Registry. Windows 10/11 (64 Bit).

Voraussetzung
-------------
Microsoft Visual C++ Redistributable (x64, aktuelle Version 2015-2026). Auf den
meisten PCs vorhanden; sonst: https://aka.ms/vc14/vc_redist.x64.exe

Benutzung
---------
1. ZIP auf den Stick (oder in einen Ordner) entpacken.
2. WBCE-Portable.exe doppelklicken (kein Autostart: Windows erlaubt das bei
   USB-Sticks nicht mehr).
3. "Server starten" klicken. Der Browser oeffnet http://localhost:4443/wbce
4. Beim ERSTEN Start erscheint der WBCE-Installer:
     System:          Windows
     Datenbank-Host:  127.0.0.1:3311      (Port 3311 mit angeben!)
     Datenbankname:   wbce
     Benutzer:        root
     Passwort:        (leer lassen)
   Admin-Benutzer und Passwort frei waehlen (Passwort gut waehlen!).
5. Zum Beenden: "Server stoppen" klicken. Erst wenn "Gestoppt" angezeigt wird,
   darf der Stick abgezogen werden - sonst koennen Datenbankdaten beschaedigt
   werden. Beim Schliessen des Fensters wird bei laufendem Server automatisch
   gefragt, ob gestoppt werden soll.

Ohne die EXE (Notbehelf): start.bat / stop.bat.

Adressen
--------
  Website:        http://localhost:4443/wbce
  Administration: http://localhost:4443/wbce/admin
  Adminer (DB):   http://localhost:4443/adminer.php   (Server 127.0.0.1:3311, root)

Der Server hoert nur auf 127.0.0.1 (nicht aus dem Netzwerk erreichbar).

Ordner
------
  htdocs\wbce   WBCE-Dateien (hier liegen Seiten, Medien, config.php)
  data          Datenbank
  logs          Apache- und PHP-Logs
  Apache24, php, mariadb   Programme

Sicherung: den ganzen Ordner (bei gestopptem Server) kopieren.

Fehlersuche
-----------
  "Port 4443/3311 belegt"   anderes Programm nutzt den Port (z. B. XAMPP) - beenden.
  Apache startet nicht      logs\apache-error.log
  MariaDB startet nicht     data\*.err
  Pfad mit Sonderzeichen    Bundle in einen Pfad ohne Umlaute legen.

Lizenzen und Quellen: siehe LICENSE-*.txt und THIRD-PARTY-NOTICES.md.
Projekt: https://github.com/Beachbone/wbce-portable
'@ | Out-File -FilePath "$Base\README-WBCE-Portable.txt" -Encoding ascii

Write-Host ""
Write-Host "Fertig. Naechste Schritte:"
Write-Host "  1. WBCE-Portable.exe (oder start.bat) starten"
Write-Host "  2. WBCE-Installer: http://localhost:4443/wbce"
Write-Host "     System: Windows"
Write-Host "     DB: Host '127.0.0.1:3311' (Port 3311!), DB 'wbce', User 'root', Passwort leer"
Write-Host "  3. Stoppen IMMER ueber die EXE bzw. stop.bat (Datenbank sauber runterfahren)"
Write-Host "  4. Zum Verteilen: .\make-zip.ps1 (auf sauberem Stand: data\, logs\, tmp\ leer, keine config.php)"
