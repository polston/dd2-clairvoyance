[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("doctor", "check", "deploy", "reset-scripts", "probe", "shot", "verify-install")]
    [string]$Action = "doctor",
    [string]$Chunk,
    [int]$Timeout = 12,
    [string]$Output = ".tmp-tests\shot.png",
    [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Dragons Dogma 2"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

function Resolve-LuaTool([string]$Name) {
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $localRoots = @($env:LOCALAPPDATA)
    if ($env:USERPROFILE) { $localRoots += (Join-Path $env:USERPROFILE "AppData\Local") }
    foreach ($localRoot in $localRoots | Where-Object { $_ }) {
        $candidate = Join-Path $localRoot "Programs\Lua\bin\$Name.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw "$Name not found; install Lua 5.4 or put $Name on PATH"
}

function Resolve-Python {
    $command = Get-Command python -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $uv) { throw "python not found and uv is unavailable" }
    $found = @(& $uv.Source python find 3.12)
    if ($LASTEXITCODE -ne 0 -or $found.Count -eq 0) {
        throw "uv python find 3.12 failed"
    }
    $candidate = "$($found[0])".Trim()
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "uv python find 3.12 returned no executable"
    }
    return $candidate
}

function ConvertTo-WindowsCommandLineArgument([string]$Argument) {
    if ($Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }
    $escaped = $Argument -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-ProjectPowerShell([string]$Script, [string[]]$Arguments) {
    $processArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
        (ConvertTo-WindowsCommandLineArgument $Script))
    foreach ($argument in $Arguments) {
        $processArgs += (ConvertTo-WindowsCommandLineArgument $argument)
    }
    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $processArgs `
        -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "$(Split-Path $Script -Leaf) failed with exit $($process.ExitCode)"
    }
}

function Add-FilePair([System.Collections.Generic.List[object]]$Pairs,
        [string]$Source, [string]$Installed) {
    $Pairs.Add([pscustomobject]@{ Source = $Source; Installed = $Installed })
}

function Add-TreePairs([System.Collections.Generic.List[object]]$Pairs,
        [string]$SourceRoot, [string]$InstalledRoot) {
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { return }
    $sourcePrefix = $SourceRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    Get-ChildItem -LiteralPath $SourceRoot -Recurse -File | ForEach-Object {
        if (-not $_.FullName.StartsWith($sourcePrefix,
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "file escaped source tree: $($_.FullName)"
        }
        $relative = $_.FullName.Substring($sourcePrefix.Length)
        Add-FilePair $Pairs $_.FullName (Join-Path $InstalledRoot $relative)
    }
}

function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($hasher.ComputeHash($stream))).Replace("-", "")
    } finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Test-InstalledFiles {
    $pairs = [System.Collections.Generic.List[object]]::new()
    Add-FilePair $pairs (Join-Path $root "reframework\autorun\Clairvoyance.lua") `
        (Join-Path $GameDir "reframework\autorun\Clairvoyance.lua")
    Add-TreePairs $pairs (Join-Path $root "reframework\autorun\Clairvoyance") `
        (Join-Path $GameDir "reframework\autorun\Clairvoyance")
    Add-TreePairs $pairs (Join-Path $root "reframework\images\Clairvoyance") `
        (Join-Path $GameDir "reframework\images\Clairvoyance")
    foreach ($name in @("Clairvoyance_hints.json", "Clairvoyance_quests.json")) {
        Add-FilePair $pairs (Join-Path $root "data\$name") `
            (Join-Path $GameDir "reframework\data\$name")
    }
    $places = Join-Path $root "data\Clairvoyance_places.json"
    Add-FilePair $pairs $places `
        (Join-Path $GameDir "reframework\data\Clairvoyance_places.json")

    $failures = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in $pairs) {
        if (-not (Test-Path -LiteralPath $pair.Source -PathType Leaf)) {
            $failures.Add("source missing: $($pair.Source)")
        } elseif (-not (Test-Path -LiteralPath $pair.Installed -PathType Leaf)) {
            $failures.Add("installed missing: $($pair.Installed)")
        } else {
            $sourceHash = Get-Sha256 $pair.Source
            $installedHash = Get-Sha256 $pair.Installed
            if ($sourceHash -ne $installedHash) {
                $failures.Add("hash mismatch: $($pair.Installed)")
            }
        }
    }
    if ($failures.Count -gt 0) {
        $failures | ForEach-Object { Write-Host "FAIL $_" }
        throw "$($failures.Count) installed file checks failed"
    }
    Write-Host "verify-install: all $($pairs.Count) files match"
}

function Install-ProbeHarness {
    $source = Join-Path $root "tools\probe\qnml_check.lua"
    $destination = Join-Path $GameDir "reframework\autorun\qnml_check.lua"
    $destinationRoot = Split-Path $destination -Parent
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "probe harness source missing: $source"
    }
    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
    if ((Get-Sha256 $source) -ne (Get-Sha256 $destination)) {
        throw "probe harness hash mismatch after install"
    }
    Write-Host "probe harness installed"
}

$tempRoot = [System.IO.Path]::GetFullPath((Join-Path $root ".tmp-tests\dev"))
$runTemp = [System.IO.Path]::GetFullPath((Join-Path $tempRoot `
    ("{0}-{1}" -f $PID, [guid]::NewGuid().ToString("N"))))
if (-not $runTemp.StartsWith($tempRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "invalid temporary path"
}
New-Item -ItemType Directory -Path $runTemp -Force | Out-Null
$oldTemp, $oldTmp, $oldPath, $oldUvCache = `
    $env:TEMP, $env:TMP, $env:PATH, $env:UV_CACHE_DIR
try {
    $env:TEMP, $env:TMP = $runTemp, $runTemp
    $env:UV_CACHE_DIR = Join-Path $runTemp "uv-cache"
    switch ($Action) {
        "doctor" {
            $just = (Get-Command just -ErrorAction Stop).Source
            $lua = Resolve-LuaTool "lua"
            $luac = Resolve-LuaTool "luac"
            $python = Resolve-Python
            if (-not (Test-Path -LiteralPath $GameDir -PathType Container)) {
                throw "game directory not found: $GameDir"
            }
            Write-Host "just: $(& $just --version)"
            Write-Host "lua: $lua"
            Write-Host "luac: $luac"
            Write-Host "python: $python"
            Write-Host "game: $GameDir"
            Write-Host "doctor: all OK"
        }
        "check" {
            $lua = Resolve-LuaTool "lua"
            $luac = Resolve-LuaTool "luac"
            $python = Resolve-Python
            $env:PATH = (Split-Path $python -Parent) + [System.IO.Path]::PathSeparator + $env:PATH
            Invoke-ProjectPowerShell (Join-Path $PSScriptRoot "check.ps1") `
                @("-Lua", $lua, "-Luac", $luac)
        }
        "deploy" {
            $lua = Resolve-LuaTool "lua"
            $luac = Resolve-LuaTool "luac"
            $python = Resolve-Python
            $env:PATH = (Split-Path $python -Parent) + [System.IO.Path]::PathSeparator + $env:PATH
            Invoke-ProjectPowerShell (Join-Path $PSScriptRoot "deploy.ps1") `
                @("-GameDir", $GameDir, "-Lua", $lua, "-Luac", $luac)
            Test-InstalledFiles
            Install-ProbeHarness
        }
        "reset-scripts" {
            Install-ProbeHarness
            Invoke-ProjectPowerShell (Join-Path $PSScriptRoot "reset-scripts.ps1") `
                @("-GameDir", $GameDir)
        }
        "probe" {
            if (-not $Chunk) { throw "probe requires -Chunk <file>" }
            $python = Resolve-Python
            $chunkPath = if ([System.IO.Path]::IsPathRooted($Chunk)) { $Chunk } else { Join-Path $root $Chunk }
            if (-not (Test-Path -LiteralPath $chunkPath -PathType Leaf)) {
                throw "probe chunk not found: $Chunk"
            }
            & $python (Join-Path $root "tools\probe\run.py") $chunkPath $Timeout --game $GameDir
            if ($LASTEXITCODE -ne 0) { throw "probe failed with exit $LASTEXITCODE" }
        }
        "shot" {
            $outputPath = if ([System.IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path $root $Output }
            $parent = Split-Path $outputPath -Parent
            if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Invoke-ProjectPowerShell (Join-Path $root "tools\probe\shot.ps1") @($outputPath)
        }
        "verify-install" { Test-InstalledFiles }
    }
} finally {
    $env:TEMP, $env:TMP, $env:PATH, $env:UV_CACHE_DIR = `
        $oldTemp, $oldTmp, $oldPath, $oldUvCache
    if (Test-Path -LiteralPath $runTemp) {
        Remove-Item -LiteralPath $runTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
