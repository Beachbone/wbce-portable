# =============================================================================
# WBCE Portable Builder
# Baut ein komplett portables WBCE-CMS-Bundle (Apache + PHP + MariaDB) in den
# Ordner, in dem dieses Skript liegt. Danach: start.bat doppelklicken,
# Browser oeffnet http://localhost:4443
#
# Voraussetzung: Windows 10/11 x64, PowerShell 5 (immer vorhanden), Internet.
# Die Microsoft-VC++-Runtime-DLLs werden aus der aktuellen vc_redist.x64.exe entpackt.
#
# Aufruf:  powershell -ExecutionPolicy Bypass -File .\build-wbce-portable.ps1
#   -WbceVersion "1.6.9"   WBCE-Release von GitHub laden (Standard: 1.6.9)
#   -PhpBranch "8.3"       mitgelieferte PHP-Version (Zweig 8.2 .. 8.5); die aktuelle Version
#                          samt Download-Adresse und SHA-256 liefert php.net (releases.json)
#   -WbceZip "C:\x.zip"    stattdessen ein vorhandenes WBCE-Archiv verwenden
#   -WbceVersion ""        ohne -WbceZip: WBCE nicht einpacken
#   -Clean                 vor dem Bauen Download-Cache (downloads\, adminer.php) sowie
#                          Apache24\, php\, mariadb\ leeren. Fuer Updates noetig: die
#                          Download-Ziele haben feste Namen und werden sonst nicht neu
#                          geladen, alte Dateien blieben im Bundle liegen.
#                          data\, htdocs\wbce, logs\, tmp\ bleiben unberuehrt.
#
# Update-Ablauf: Versionen/URLs in $Downloads (unten) anpassen ->
#   build-wbce-portable.ps1 -Clean -> Bundle sauber machen (data\, logs\, tmp\ leer,
#   keine config.php) -> make-zip.ps1 -Version X.Y.Z
# =============================================================================

param(
    [string]$WbceZip = "",
    [string]$WbceVersion = "1.6.9",
    [string]$PhpBranch = "8.3",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$Base = $PSScriptRoot
if (-not $Base) { $Base = (Get-Location).Path }

# --- Download-Quellen (bei Bedarf Versionsnummern anpassen) -----------------
$Downloads = @{
    # Apache Lounge liefert nur mit Referer + User-Agent die ZIP (sonst HTML-Fehlerseite)
    Apache = "https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.69-261002-Win64-VS18.zip"
    # PHP: nicht fest verdrahtet, siehe Get-PhpRelease (releases.json von php.net)
    Maria  = "https://archive.mariadb.org/mariadb-11.4.13/winx64-packages/mariadb-11.4.13-winx64.zip"
    Adminer = "https://github.com/vrana/adminer/releases/download/v4.8.1/adminer-4.8.1.php"
    # Microsoft VC++ Runtime: wird nur entpackt (DLLs), nicht installiert oder mitgeliefert
    VcRedist = "https://aka.ms/vc14/vc_redist.x64.exe"
}

Write-Host "== WBCE Portable Builder =="

# --- Optional: Komponenten + Cache fuer ein Update leeren ----------------------
if ($Clean) {
    Write-Host "== -Clean: leere Download-Cache und Komponenten =="
    if (Get-Process httpd, mysqld -ErrorAction SilentlyContinue) {
        throw "Apache/MariaDB laufen noch - zuerst stoppen (stop.bat)."
    }
    foreach ($f in @("downloads\httpd.zip", "downloads\mariadb.zip",
                     "downloads\vc_redist.x64.exe", "htdocs\adminer.php")) {
        if (Test-Path -LiteralPath "$Base\$f") { Remove-Item -LiteralPath "$Base\$f" -Force }
    }
    if (Test-Path -LiteralPath "$Base\downloads") {
        foreach ($pat in "wbce-*.zip", "php-*.zip") {
            Get-ChildItem -LiteralPath "$Base\downloads" -Filter $pat -File |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
        }
    }
    foreach ($d in @("Apache24", "php", "mariadb")) {
        if (Test-Path -LiteralPath "$Base\$d") {
            Get-ChildItem -LiteralPath "$Base\$d" -Force |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
        }
    }
}

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

function Get-PhpRelease($branch) {
    $ProgressPreference = "SilentlyContinue"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $json = Invoke-WebRequest -Uri "https://downloads.php.net/~windows/releases/releases.json" -UseBasicParsing `
        -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    $m = $json.Content | ConvertFrom-Json
    $entry = $m.$branch
    if (-not $entry) { throw "PHP-Zweig $branch steht nicht in releases.json" }
    $key = $entry.PSObject.Properties.Name | Where-Object { $_ -like "ts-vs*-x64" } | Select-Object -First 1
    if (-not $key) { throw "Kein Thread-Safe-x64-Build fuer PHP $branch in releases.json" }
    $zip = $entry.$key.zip
    return @{ Version = $entry.version; Zip = $zip.path; Sha256 = $zip.sha256.ToLower() }
}

Write-Host "1/6 Lade Komponenten ..."
Get-File $Downloads.Apache  "$Base\downloads\httpd.zip"
# PHP (Thread-Safe, x64): Version, Datei und SHA-256 aus dem offiziellen Manifest.
# Der Cache-Dateiname enthaelt die Version, ein neues Release wird also automatisch geladen.
$phpRel = Get-PhpRelease $PhpBranch
Write-Host "   PHP $($phpRel.Version) (Zweig $PhpBranch)"
$phpZip = "$Base\downloads\$($phpRel.Zip)"
Get-File ("https://downloads.php.net/~windows/releases/" + $phpRel.Zip) $phpZip
$phpHash = (Get-FileHash -LiteralPath $phpZip -Algorithm SHA256).Hash.ToLower()
if ($phpHash -ne $phpRel.Sha256) {
    Remove-Item -LiteralPath $phpZip -Force
    throw "SHA-256 von $($phpRel.Zip) stimmt nicht mit php.net ueberein (erwartet $($phpRel.Sha256), erhalten $phpHash)"
}
Get-File $Downloads.Maria   "$Base\downloads\mariadb.zip"
Get-File $Downloads.Adminer  "$Base\htdocs\adminer.php"

# --- Entpacken ----------------------------------------------------------------
Write-Host "2/6 Entpacke ..."
Expand-Archive -Path "$Base\downloads\httpd.zip"   -DestinationPath "$Base\_tmp_apache" -Force
Expand-Archive -Path $phpZip                      -DestinationPath "$Base\_tmp_php"    -Force
Expand-Archive -Path "$Base\downloads\mariadb.zip"  -DestinationPath "$Base\_tmp_maria"  -Force

# Apache: Zip enthaelt Ordner Apache24
Copy-Item "$Base\_tmp_apache\Apache24\*" "$Base\Apache24\" -Recurse -Force
# PHP: Zip enthaelt die Dateien direkt
Copy-Item "$Base\_tmp_php\*" "$Base\php\" -Recurse -Force
# MariaDB: Zip enthaelt Ordner mariadb-11.x-winx64
$mariaSrc = (Get-ChildItem "$Base\_tmp_maria" -Directory | Select-Object -First 1).FullName
Copy-Item "$mariaSrc\*" "$Base\mariadb\" -Recurse -Force
Remove-Item "$Base\_tmp_apache","$Base\_tmp_php","$Base\_tmp_maria" -Recurse -Force

# --- Microsoft VC++ Runtime app-local beilegen ---------------------------------
# Apache Lounge VS18 braucht die Runtime 14.50+. Statt sie auf dem Ziel-PC zu installieren
# (Adminrechte), liegen die DLLs neben httpd.exe bzw. php.exe; dort sucht Windows zuerst.
# MariaDB bringt seine eigenen Kopien mit.
# Quelle: die aktuelle vc_redist.x64.exe von Microsoft. Sie wird NICHT ausgefuehrt, sondern
# nur entpackt (die CAB-Container stecken unkomprimiert in der EXE). Die Build-PC-Installation
# ist nicht noetig; nur wenn der Download/Entpacken scheitert, dient System32 als Ersatz.
Write-Host "   Beschaffe VC++-Runtime-DLLs ..."
$vcDlls = "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"
$vcMinVersion = [version]"14.50"
$vcDir = "$Base\_tmp_vc"
if (Test-Path -LiteralPath $vcDir) { Remove-Item -LiteralPath $vcDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $vcDir | Out-Null

function Test-MsSigned($path) {
    $s = Get-AuthenticodeSignature -LiteralPath $path
    return ($s.Status -eq "Valid" -and $s.SignerCertificate.Subject -like "*O=Microsoft Corporation*")
}

function Expand-VcRedist($exe, $outDir) {
    if (-not (Test-MsSigned $exe)) { throw "vc_redist.x64.exe hat keine gueltige Microsoft-Signatur" }
    $bytes = [IO.File]::ReadAllBytes($exe)
    $n = 0
    for ($i = 0; $i -lt $bytes.Length - 16; $i++) {
        # CAB-Kopf "MSCF" + 4 Nullbytes; Bytes 8..11 = Gesamtgroesse des Cabinets
        if ($bytes[$i] -eq 0x4D -and $bytes[$i+1] -eq 0x53 -and $bytes[$i+2] -eq 0x43 -and $bytes[$i+3] -eq 0x46 -and
            $bytes[$i+4] -eq 0 -and $bytes[$i+5] -eq 0 -and $bytes[$i+6] -eq 0 -and $bytes[$i+7] -eq 0) {
            $size = [BitConverter]::ToUInt32($bytes, $i + 8)
            if ($size -lt 100000 -or $i + $size -gt $bytes.Length) { continue }
            $n++
            $cab = "$outDir\outer$n.cab"
            $chunk = New-Object byte[] $size
            [Array]::Copy($bytes, $i, $chunk, 0, $size)
            [IO.File]::WriteAllBytes($cab, $chunk)
            $d1 = "$outDir\outer$n"
            New-Item -ItemType Directory -Force -Path $d1 | Out-Null
            & expand.exe -F:* $cab $d1 | Out-Null
            # darin liegen die MSI/CAB-Pakete; die CAB mit den x64-DLLs enthaelt "*.dll_amd64"
            foreach ($inner in Get-ChildItem -LiteralPath $d1 -File) {
                $d2 = "$d1\x_$($inner.Name)"
                New-Item -ItemType Directory -Force -Path $d2 | Out-Null
                & expand.exe -F:vcruntime140*_amd64 $inner.FullName $d2 | Out-Null
                & expand.exe -F:msvcp140.dll_amd64 $inner.FullName $d2 | Out-Null
            }
        }
    }
    $found = @{}
    foreach ($dll in $vcDlls) {
        $hit = Get-ChildItem -LiteralPath $outDir -Recurse -File -Filter "${dll}_amd64" | Select-Object -First 1
        if (-not $hit) { throw "$dll wurde in vc_redist.x64.exe nicht gefunden" }
        $found[$dll] = $hit.FullName
    }
    return $found
}

$vcSource = @{}
$vcFrom = ""
try {
    Get-File $Downloads.VcRedist "$Base\downloads\vc_redist.x64.exe"
    $vcSource = Expand-VcRedist "$Base\downloads\vc_redist.x64.exe" $vcDir
    $vcFrom = "Microsoft-Download"
} catch {
    Write-Host "   Download/Entpacken fehlgeschlagen ($($_.Exception.Message)) - versuche System32 des Build-PCs"
    foreach ($dll in $vcDlls) {
        $src = Join-Path $env:SystemRoot "System32\$dll"
        if (-not (Test-Path -LiteralPath $src)) { throw "$dll weder per Download noch in System32 verfuegbar" }
        $vcSource[$dll] = $src
    }
    $vcFrom = "System32"
}
foreach ($dll in $vcDlls) {
    # die entpackte Datei heisst z.B. vcruntime140.dll_amd64: erst umbenennen, dann pruefen
    $tmp = "$vcDir\$dll"
    Copy-Item -LiteralPath $vcSource[$dll] -Destination $tmp -Force
    if (-not (Test-MsSigned $tmp)) { throw "$dll hat keine gueltige Microsoft-Signatur" }
    $ver = [version](Get-Item -LiteralPath $tmp).VersionInfo.ProductVersion
    if ($ver -lt $vcMinVersion) { throw "$dll ist Version $ver, benoetigt wird mindestens $vcMinVersion" }
    Copy-Item -LiteralPath $tmp -Destination "$Base\Apache24\bin\$dll" -Force
    Copy-Item -LiteralPath $tmp -Destination "$Base\php\$dll" -Force
    Write-Host ("   {0} {1} ({2})" -f $dll, $ver, $vcFrom)
}
Remove-Item -LiteralPath $vcDir -Recurse -Force

# --- Bundle verkleinern: Debug-Symbole, Entwicklerdateien, ungenutzte Werkzeuge ----
# (alles nur Entwickler-/Backup-Zubehoer; Server, Client- und Pruefwerkzeuge bleiben)
Write-Host "   Entferne Debug- und Entwicklerdateien ..."
$trimFiles = @(
    "mariadb\bin\*.pdb", "mariadb\bin\*.lib", "mariadb\lib\*.lib", "mariadb\lib\*.pdb",
    "mariadb\bin\mariadb-backup.exe", "mariadb\bin\mariabackup.exe",
    "mariadb\bin\mariadb-ldb.exe", "mariadb\bin\mysql_ldb.exe", "mariadb\bin\sst_dump.exe",
    "Apache24\lib\*.lib", "Apache24\lib\*.exp", "Apache24\bin\*.pdb",
    "php\php8embed.lib", "php\*.pdb"
)
foreach ($pat in $trimFiles) {
    Get-ChildItem -Path "$Base\$pat" -File -ErrorAction SilentlyContinue | Remove-Item -Force
}
foreach ($dir in "mariadb\include", "Apache24\include", "php\dev") {
    if (Test-Path -LiteralPath "$Base\$dir") { Remove-Item -LiteralPath "$Base\$dir" -Recurse -Force }
}

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

# httpd.conf: __BASE__ (Programmordner) und __PHP__ (aktives PHP-Verzeichnis) werden von
# Launcher bzw. start.bat bei jedem Start durch die echten Pfade ersetzt.
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

LoadFile "__PHP__/php8ts.dll"
LoadModule php_module "__PHP__/php8apache2_4.dll"
PHPIniDir "__PHP__"

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
extension_dir="__PHP__/ext"
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

rem Aktives PHP-Verzeichnis (Standard: php; der Launcher kann auf php-8.x.y wechseln)
set PHPDIR=php
if exist "%BASE%php-active.txt" set /p PHPDIR=<"%BASE%php-active.txt"

rem PHP-Verzeichnis in den DLL-Suchpfad (curl/intl brauchen libssh2, ICU usw. neben php.exe)
set "PATH=%BASE%%PHPDIR%;%PATH%"

rem Konfigs mit echtem Pfad erzeugen (Laufwerksbuchstabe ist egal)
powershell -NoProfile -Command "(Get-Content '%BASE%conf-httpd.template') -replace '__PHP__','%BASE:\=/%%PHPDIR%' -replace '__BASE__','%BASE:\=/%' | Set-Content '%BASE%Apache24\conf\httpd.conf'"
powershell -NoProfile -Command "(Get-Content '%BASE%conf-php.template') -replace '__PHP__','%BASE:\=/%%PHPDIR%' -replace '__BASE__','%BASE:\=/%' | Set-Content '%BASE%%PHPDIR%\php.ini'"
powershell -NoProfile -Command "(Get-Content '%BASE%conf-my.template') -replace '__BASE__','%BASE:\=/%' | Set-Content '%BASE%my.ini'"

rem Datenbank beim ersten Start initialisieren
if not exist "%BASE%data\mysql" (
    echo Initialisiere Datenbank - nur beim ersten Start ...
    "%BASE%mariadb\bin\mariadb-install-db.exe" --datadir="%BASE%data" >nul
)

rem MariaDB starten
powershell -NoProfile -Command "Start-Process -WindowStyle Hidden -FilePath 'mariadb\bin\mysqld.exe' -ArgumentList '--defaults-file=my.ini'"

rem Kurz warten, DB anlegen falls fehlt, dann Apache
timeout /t 3 /nobreak >nul
"%BASE%mariadb\bin\mariadb.exe" --port=3311 -u root -e "CREATE DATABASE IF NOT EXISTS wbce CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
powershell -NoProfile -Command "Start-Process -WindowStyle Hidden -FilePath 'Apache24\bin\httpd.exe'"

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


Benutzung
---------
1. ZIP auf den Stick (oder in einen Ordner) entpacken.
2. WBCE-Portable.exe doppelklicken (kein Autostart: Windows erlaubt das bei
   USB-Sticks nicht mehr).
3. "Server starten" klicken.
4. Beim ERSTEN Start fragt das Programm nach Benutzername, E-Mail und Passwort
   (mind. 12 Zeichen) fuer den Administrator und richtet WBCE damit automatisch ein
   (die Datenbank erhaelt einen eigenen Zufalls-Benutzer; er steht in
   htdocs\wbce\config.php, fuer Adminer geht auch root ohne Passwort).
   Alternativ "Installer im Browser benutzen" waehlen; dort gilt:
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

PHP-Version wechseln: in der EXE unten rechts auf "PHP x.y.z" klicken (nur bei
gestopptem Server). Weitere Versionen (8.2 bis 8.5) werden von php.net geladen
und per SHA-256 geprueft; die Daten bleiben unveraendert.

Ohne die EXE (Notbehelf): start.bat / stop.bat. Apache und MariaDB laufen dann
unsichtbar im Hintergrund (kein Konsolenfenster); beendet wird mit stop.bat.

Windows blockiert die EXE ("Der Computer wurde durch Windows geschuetzt" oder
sie laesst sich gar nicht starten)?
  Ursache: Dateien aus dem Internet tragen eine Markierung ("Mark of the Web").
  Loesung: BEVOR die ZIP entpackt wird: Rechtsklick auf die ZIP -> Eigenschaften
           -> unten "Zulassen" ankreuzen -> OK. Danach entpacken.
  Nachtraeglich: in PowerShell
           Get-ChildItem -Recurse "C:\Pfad\zu\WBCE-Portable" | Unblock-File
  Bei der Meldung von SmartScreen: "Weitere Informationen" -> "Trotzdem ausfuehren".

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
  "VCRUNTIME140.dll fehlt"  Ordner unvollstaendig entpackt (Apache24\bin\vcruntime140*.dll,
                            msvcp140.dll) - ZIP erneut entpacken.
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
