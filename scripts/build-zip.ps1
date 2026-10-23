# Builds the release zip into dist/ (gitignored). Unless -NoPlaces it
# first generates the places file from the game's pak with tools/extract_world.py
# and stages it under reframework/data. With -PlacesFile the extractor and its
# Python/key/game checks are skipped and that file is staged instead (CI uses
# this with the committed data/Clairvoyance_places.json). With -Version x.y.z the staged
# modinfo.ini gets version=x.y.z (the repo file is not modified). The zip never contains tools/.
param(
    [string]$GameDir = "",
    [string]$Python = "python",
    [string]$KeyFile = "",
    [string]$Root = "",
    [string]$OutDir = "",
    [string]$PlacesFile = "",
    [string]$Version = "",
    [switch]$NoPlaces
)
$ErrorActionPreference = "Stop"
if ($Root -eq "") { $Root = Split-Path $PSScriptRoot -Parent }
if ($OutDir -eq "") { $OutDir = Join-Path $Root "dist" }
function Stop-Build([string]$msg) { Write-Host "build-zip: $msg"; exit 1 }

if ($Version -ne "" -and $Version -notmatch '^\d+\.\d+\.\d+$') {
    Stop-Build "version must look like 1.2.3, got '$Version'"
}
if ($PlacesFile -ne "" -and -not $NoPlaces -and -not (Test-Path $PlacesFile)) {
    Stop-Build "places file not found '$PlacesFile'"
}
if (-not $NoPlaces -and $PlacesFile -eq "") {
    if ($GameDir -eq "" -or -not (Test-Path (Join-Path $GameDir "re_chunk_000.pak"))) {
        Stop-Build "re_chunk_000.pak not found in game folder '$GameDir'"
    }
    $ok = $false
    try { & $Python --version | Out-Null; $ok = ($LASTEXITCODE -eq 0) } catch { $ok = $false }
    if (-not $ok) { Stop-Build "Python not found ('$Python')" }
    $v = ""
    try { $v = (& $Python -c "import sys; print(sys.version_info >= (3,10))" | Out-String).Trim() } catch { $v = "" }
    if ($v -ne "True") { Stop-Build "Python 3.10 or newer is required" }
    $ok = $false
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & $Python -c "import zstandard" 2>$null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $old
    if (-not $ok) { Stop-Build "Python module zstandard is not installed" }
    if ($KeyFile -eq "") {
        # The key lives in the main checkout; key_check.py finds it from any worktree.
        $KeyFile = (& $Python (Join-Path $Root "tools/key_check.py") --path | Out-String).Trim()
    }
    if (-not (Test-Path $KeyFile)) { Stop-Build "key: missing (key file not found)" }
    Write-Host "key: present"
}

$stage = Join-Path $OutDir "stage"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $Root "modinfo.ini") $stage
if ($Version -ne "") {
    $ini = Join-Path $stage "modinfo.ini"
    $text = [System.IO.File]::ReadAllText($ini)
    $text = [regex]::Replace($text, '(?m)^version=[^\r\n]*(\r?)$', "version=$Version`$1")
    [System.IO.File]::WriteAllText($ini, $text)
}
New-Item -ItemType Directory -Force (Join-Path $stage "reframework") | Out-Null
Copy-Item (Join-Path $Root "reframework/autorun") (Join-Path $stage "reframework") -Recurse
$iconsSrc = Join-Path $Root "reframework/images/Clairvoyance"
if (-not (Test-Path -LiteralPath $iconsSrc -PathType Container)) { Stop-Build "icons folder missing: reframework/images/Clairvoyance" }
$iconsDst = Join-Path $stage "reframework/images/Clairvoyance"
New-Item -ItemType Directory -Force (Join-Path $iconsDst "icons") | Out-Null
# Only the tracked shapes ship: icons/*.png and icons/index.json.
Copy-Item (Join-Path $iconsSrc "icons/*.png") (Join-Path $iconsDst "icons") -Force
Copy-Item (Join-Path $iconsSrc "icons/index.json") (Join-Path $iconsDst "icons") -Force

# The hints file ships in both variants; a repo without it stops the build.
$hintsSrc = Join-Path $Root "data/Clairvoyance_hints.json"
if (-not (Test-Path -LiteralPath $hintsSrc -PathType Leaf)) { Stop-Build "hints file missing: data/Clairvoyance_hints.json" }
$hintsDst = Join-Path $stage "reframework/data/Clairvoyance_hints.json"
New-Item -ItemType Directory -Force (Split-Path $hintsDst -Parent) | Out-Null
Copy-Item $hintsSrc $hintsDst

if ($NoPlaces) { $zip = Join-Path $OutDir "Clairvoyance-noplaces.zip" }
else {
    $zip = Join-Path $OutDir "Clairvoyance.zip"
    $placesOut = Join-Path $stage "reframework/data/Clairvoyance_places.json"
    if ($PlacesFile -ne "") {
        New-Item -ItemType Directory -Force (Split-Path $placesOut -Parent) | Out-Null
        Copy-Item $PlacesFile $placesOut
    } else {
    & $Python (Join-Path $Root "tools/extract_world.py") --game $GameDir --out $placesOut --key $KeyFile
    if ($LASTEXITCODE -ne 0) { Stop-Build "extractor failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path $placesOut)) { Stop-Build "extractor wrote no places file" }
    }
}
if (Test-Path $zip) { Remove-Item $zip }
# System32 tar writes forward-slash entry names; PS 5.1 Compress-Archive
# writes backslashes, which mod managers may not handle.
Push-Location $stage
& "$env:SystemRoot\System32\tar.exe" -a -c -f $zip modinfo.ini reframework
$tarCode = $LASTEXITCODE
Pop-Location
if ($tarCode -ne 0) { Stop-Build "tar failed" }
Write-Host "built $zip"
