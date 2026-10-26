# Verifies that deployment is gated by the repository checks and that a failed
# gate leaves the installed mod untouched.
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
$base = Join-Path ([System.IO.Path]::GetTempPath()) "qnml_deploy_test_$PID"
$script:failed = 0

function Assert-True([string]$name, [bool]$ok, [string]$why) {
    if ($ok) { Write-Host "PASS $name" }
    else { Write-Host "FAIL $name : $why"; $script:failed++ }
}

function New-Case([string]$name, [int]$checkExit) {
    $root = Join-Path $base $name
    $scripts = Join-Path $root "scripts"
    $autorun = Join-Path $root "reframework/autorun"
    $module = Join-Path $autorun "Clairvoyance"
    $images = Join-Path $root "reframework/images/Clairvoyance/icons"
    $game = Join-Path $root "game"
    $dest = Join-Path $game "reframework/autorun"
    New-Item -ItemType Directory -Force $scripts, $module, $images, $dest | Out-Null
    Copy-Item (Join-Path $repo "scripts/deploy.ps1") $scripts
    Set-Content -Path (Join-Path $scripts "check.ps1") -Encoding ASCII -Value @(
        'param([string]$Lua, [string]$Luac)',
        '$root = Split-Path $PSScriptRoot -Parent',
        'Set-Content -Path (Join-Path $root "check-ran.txt") -Value "yes" -Encoding ASCII',
        "exit $checkExit"
    )
    Set-Content -Path (Join-Path $autorun "Clairvoyance.lua") -Value "new" -Encoding ASCII
    Set-Content -Path (Join-Path $module "core.lua") -Value "new module" -Encoding ASCII
    Set-Content -Path (Join-Path $images "1.png") -Value "new icon" -Encoding ASCII
    Set-Content -Path (Join-Path $dest "Clairvoyance.lua") -Value "old" -Encoding ASCII
    return @{ Root = $root; Game = $game; Installed = (Join-Path $dest "Clairvoyance.lua") }
}

function Invoke-Deploy($case) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $text = & powershell -NoProfile -File (Join-Path $case.Root "scripts/deploy.ps1") `
        -GameDir $case.Game 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return @{ Code = $code; Text = $text }
}

try {
    New-Item -ItemType Directory -Force $base | Out-Null

    $blocked = New-Case "blocked" 1
    $result = Invoke-Deploy $blocked
    $installed = Get-Content -Raw $blocked.Installed
    Assert-True "failed_check_blocks_deploy" `
        (($result.Code -ne 0) -and ($installed.Trim() -eq "old") -and
         (Test-Path (Join-Path $blocked.Root "check-ran.txt"))) `
        "code $($result.Code), installed '$($installed.Trim())', output $($result.Text)"

    $allowed = New-Case "allowed" 0
    $result = Invoke-Deploy $allowed
    $installed = Get-Content -Raw $allowed.Installed
    Assert-True "successful_check_allows_deploy" `
        (($result.Code -eq 0) -and ($installed.Trim() -eq "new") -and
         (Test-Path (Join-Path $allowed.Root "check-ran.txt"))) `
        "code $($result.Code), installed '$($installed.Trim())', output $($result.Text)"
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed -gt 0) { Write-Host "test_deploy: $($script:failed) FAILED"; exit 1 }
Write-Host "test_deploy: all OK"
