# =============================================================================
# WBCE Portable - Release-ZIP packen
# Packt das gebaute Bundle (Ergebnis von build-wbce-portable.ps1) in
#   dist\WBCE-Portable-<Version>.zip   und schreibt dist\SHA256SUMS.txt
# Die ZIP bekommt Forward-Slash-Pfade und den Top-Level-Ordner "WBCE-Portable".
#
# Aufruf:  powershell -ExecutionPolicy Bypass -File .\make-zip.ps1 -Version 0.1.0-wbce1.6.9
# =============================================================================

param(
    [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = "Stop"
$Base = $PSScriptRoot
if (-not $Base) { $Base = (Get-Location).Path }

# --- Sicherheitschecks: nur sauberer Auslieferungszustand wird gepackt -----------
if (Get-Process mysqld, mariadbd, httpd, WBCE-Portable -ErrorAction SilentlyContinue) {
    throw "Server oder Launcher laeuft noch - zuerst stoppen/beenden."
}
foreach ($d in "data", "logs", "tmp") {
    if (@(Get-ChildItem -LiteralPath "$Base\$d" -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        throw "Ordner '$d' ist nicht leer - das Bundle enthaelt Laufzeitdaten. Neu bauen oder Ordner leeren."
    }
}
if (Test-Path "$Base\htdocs\wbce\config.php") {
    throw "htdocs\wbce\config.php existiert - das Bundle ist bereits installiert. Neu bauen."
}
foreach ($f in "WBCE-Portable.exe", "vcredist\vc_redist.x64.exe", "Apache24\bin\httpd.exe", "php\php.exe", "mariadb\bin\mysqld.exe", "htdocs\wbce\index.php") {
    if (-not (Test-Path "$Base\$f")) { throw "Fehlt: $f (build-wbce-portable.ps1 ausfuehren, Launcher bauen)" }
}

# --- Whitelist der Top-Level-Eintraege -------------------------------------------
$include = @(
    "Apache24", "php", "mariadb", "htdocs", "data", "logs", "tmp", "vcredist",
    "conf-httpd.template", "conf-php.template", "conf-my.template",
    "start.bat", "stop.bat", "WBCE-Portable.exe",
    "README-WBCE-Portable.txt", "THIRD-PARTY-NOTICES.md"
)
$includeWild = @("LICENSE-*.txt", "NOTICE-*.txt")

function Test-Included($name) {
    if ($include -contains $name) { return $true }
    foreach ($w in $includeWild) { if ($name -like $w) { return $true } }
    return $false
}

New-Item -ItemType Directory -Force -Path "$Base\dist" | Out-Null
$out = "$Base\dist\WBCE-Portable-$Version.zip"
if (Test-Path $out) { Remove-Item $out -Force }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$top = "WBCE-Portable"
$zip = [System.IO.Compression.ZipFile]::Open($out, [System.IO.Compression.ZipArchiveMode]::Create)
$files = 0; $dirs = 0
try {
    foreach ($item in Get-ChildItem -LiteralPath $Base -Force | Where-Object { Test-Included $_.Name }) {
        if ($item.PSIsContainer) {
            $all = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force)
            if ($all.Count -eq 0) { [void]$zip.CreateEntry("$top/$($item.Name)/"); $dirs++ }
            foreach ($e in $all) {
                $rel = $e.FullName.Substring($Base.Length + 1).Replace('\', '/')
                if ($e.PSIsContainer) {
                    if (@(Get-ChildItem -LiteralPath $e.FullName -Force).Count -eq 0) {
                        [void]$zip.CreateEntry("$top/$rel/"); $dirs++
                    }
                } else {
                    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $zip, $e.FullName, "$top/$rel", [System.IO.Compression.CompressionLevel]::Optimal)
                    $files++
                }
            }
        } else {
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $item.FullName, "$top/$($item.Name)", [System.IO.Compression.CompressionLevel]::Optimal)
            $files++
        }
    }
} finally {
    $zip.Dispose()
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $out).Hash.ToLower()
"$hash  $(Split-Path $out -Leaf)" | Out-File -FilePath "$Base\dist\SHA256SUMS.txt" -Encoding ascii
"{0}`n  Dateien: {1}, leere Ordner: {2}, {3:N1} MB`n  SHA256: {4}" -f $out, $files, $dirs, ((Get-Item $out).Length / 1MB), $hash
