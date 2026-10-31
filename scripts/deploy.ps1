# Copies the mod into the game's reframework/autorun for direct testing.
param(
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Dragons Dogma 2",
    [string]$Lua = "lua",
    [string]$Luac = "luac"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$requiredSources = @(
    @{
        RelativePath = "reframework/autorun/Clairvoyance.lua"
        AbsolutePath = Join-Path $root "reframework/autorun/Clairvoyance.lua"
        PathType = "Leaf"
    },
    @{
        RelativePath = "reframework/autorun/Clairvoyance"
        AbsolutePath = Join-Path $root "reframework/autorun/Clairvoyance"
        PathType = "Container"
    },
    @{
        RelativePath = "reframework/images/Clairvoyance"
        AbsolutePath = Join-Path $root "reframework/images/Clairvoyance"
        PathType = "Container"
    }
)
foreach ($source in $requiredSources) {
    if (-not (Test-Path -LiteralPath $source.AbsolutePath -PathType $source.PathType)) {
        throw "deployment source missing: $($source.RelativePath)"
    }
}
$checkArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
    (Join-Path $PSScriptRoot "check.ps1"), "-Lua", $Lua, "-Luac", $Luac)
& powershell @checkArgs
if ($LASTEXITCODE -ne 0) { throw "checks failed; deployment refused" }
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
# Drop pictures a patch stopped producing: only the icons folder this mod owns.
Remove-Item -LiteralPath (Join-Path $iconsDst "icons") -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $iconsDst | Out-Null
Copy-Item (Join-Path $root "reframework\images\Clairvoyance\*") $iconsDst -Recurse -Force
$places = Join-Path $root "data\Clairvoyance_places.json"
if (Test-Path $places) {
    $data = Join-Path $GameDir "reframework\data"
    New-Item -ItemType Directory -Force $data | Out-Null
    Copy-Item $places $data -Force
    Write-Host "deployed places file to $data"
}
$hints = Join-Path $root "data\Clairvoyance_hints.json"
if (Test-Path $hints) {
    $data = Join-Path $GameDir "reframework\data"
    New-Item -ItemType Directory -Force $data | Out-Null
    Copy-Item $hints $data -Force
    Write-Host "deployed hints file to $data"
}
$quests = Join-Path $root "data\Clairvoyance_quests.json"
if (Test-Path $quests) {
    $data = Join-Path $GameDir "reframework\data"
    New-Item -ItemType Directory -Force $data | Out-Null
    Copy-Item $quests $data -Force
    Write-Host "deployed quests file to $data"
}
Write-Host "deployed to $dest"
