# Copies the mod into the game's reframework/autorun for direct testing.
param([string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Dragons Dogma 2")
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$dest = Join-Path $GameDir "reframework\autorun"
if (-not (Test-Path $dest)) { throw "autorun not found: $dest" }
# Remove the pre-rename copy (these two exact names only) so two copies never load.
foreach ($old in @("QuestNPCMapLabels.lua", "QuestNPCMapLabels")) {
    $oldPath = Join-Path $dest $old
    if (Test-Path $oldPath) { Remove-Item $oldPath -Recurse -Force; Write-Host "removed old copy $oldPath" }
}
Copy-Item (Join-Path $root "reframework\autorun\Clairvoyance.lua") $dest -Force
Copy-Item (Join-Path $root "reframework\autorun\Clairvoyance") $dest -Recurse -Force
$iconsDst = Join-Path $GameDir "reframework\images\Clairvoyance"
New-Item -ItemType Directory -Force $iconsDst | Out-Null
Copy-Item (Join-Path $root "reframework\images\Clairvoyance\*") $iconsDst -Recurse -Force
$places = Join-Path $root "dist\stage\reframework\data\Clairvoyance_places.json"
if (-not (Test-Path $places)) { $places = Join-Path $root "data\Clairvoyance_places.json" }
if (Test-Path $places) {
    $data = Join-Path $GameDir "reframework\data"
    New-Item -ItemType Directory -Force $data | Out-Null
    Copy-Item $places $data -Force
    Write-Host "deployed places file to $data"
}
Write-Host "deployed to $dest"
