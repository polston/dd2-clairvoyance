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
    $images = Join-Path $root "reframework/images/Clairvoyance"
    $icons = Join-Path $images "icons"
    $game = Join-Path $root "game"
    $dest = Join-Path $game "reframework/autorun"
    $installedModule = Join-Path $dest "Clairvoyance"
    $installedIcons = Join-Path $game "reframework/images/Clairvoyance/icons"
    New-Item -ItemType Directory -Force $scripts, $module, $icons, $dest, `
        $installedModule, $installedIcons | Out-Null
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
    Set-Content -Path (Join-Path $dest "Clairvoyance.lua") -Value "old main" -Encoding ASCII
    Set-Content -Path (Join-Path $installedModule "core.lua") -Value "old module" -Encoding ASCII
    Set-Content -Path (Join-Path $installedIcons "1.png") -Value "old icon" -Encoding ASCII
    Set-Content -Path (Join-Path $dest "QuestNPCMapLabels.lua") -Value "old legacy" -Encoding ASCII
    return @{
        Root = $root
        Game = $game
        Installed = @(
            (Join-Path $dest "Clairvoyance.lua"),
            (Join-Path $installedModule "core.lua"),
            (Join-Path $installedIcons "1.png"),
            (Join-Path $dest "QuestNPCMapLabels.lua")
        )
    }
}

function Invoke-Deploy($case) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $text = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $case.Root "scripts/deploy.ps1") `
        -GameDir $case.Game 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return @{ Code = $code; Text = $text }
}

try {
    New-Item -ItemType Directory -Force $base | Out-Null

    $blocked = New-Case "blocked" 1
    $result = Invoke-Deploy $blocked
    $installed = Get-Content -Raw $blocked.Installed[0]
    Assert-True "failed_check_blocks_deploy" `
        (($result.Code -ne 0) -and ($installed.Trim() -eq "old main") -and
         (Test-Path (Join-Path $blocked.Root "check-ran.txt"))) `
        "code $($result.Code), installed '$($installed.Trim())', output $($result.Text)"

    $allowed = New-Case "allowed" 0
    $result = Invoke-Deploy $allowed
    $installed = Get-Content -Raw $allowed.Installed[0]
    Assert-True "successful_check_allows_deploy" `
        (($result.Code -eq 0) -and ($installed.Trim() -eq "new") -and
         (Test-Path (Join-Path $allowed.Root "check-ran.txt"))) `
        "code $($result.Code), installed '$($installed.Trim())', output $($result.Text)"

    $devSource = Get-Content -Raw (Join-Path $repo "scripts/dev.ps1")
    $deployStart = $devSource.IndexOf('        "deploy" {')
    $probeStart = $devSource.IndexOf('        "probe" {', $deployStart + 1)
    $deployBlock = if ($deployStart -ge 0 -and $probeStart -gt $deployStart) {
        $devSource.Substring($deployStart, $probeStart - $deployStart)
    } else { "" }
    $invokeAt = $deployBlock.IndexOf("Invoke-ProjectPowerShell")
    $verifyAt = $deployBlock.IndexOf("Test-InstalledFiles")
    Assert-True "deploy_wrapper_verifies_installed_hashes_before_success" `
        (($invokeAt -ge 0) -and ($verifyAt -gt $invokeAt)) `
        "deploy action does not verify installed hashes after deployment"
    $invokeStart = $devSource.IndexOf("function Invoke-ProjectPowerShell")
    $pairStart = $devSource.IndexOf("function Add-FilePair", $invokeStart + 1)
    $invokeBlock = if ($invokeStart -ge 0 -and $pairStart -gt $invokeStart) {
        $devSource.Substring($invokeStart, $pairStart - $invokeStart)
    } else { "" }
    Assert-True "deploy_wrapper_waits_for_nested_powershell_process_tree" `
        ($invokeBlock.Contains("Start-Process") -and $invokeBlock.Contains("-Wait") -and
         $invokeBlock.Contains("-PassThru")) `
        "Invoke-ProjectPowerShell does not explicitly wait for the nested process tree"

    $requiredSources = @(
        @{
            Name = "main_file"
            RelativePath = "reframework/autorun/Clairvoyance.lua"
            Type = "Leaf"
        },
        @{
            Name = "module_directory"
            RelativePath = "reframework/autorun/Clairvoyance"
            Type = "Container"
        },
        @{
            Name = "image_directory"
            RelativePath = "reframework/images/Clairvoyance"
            Type = "Container"
        }
    )
    foreach ($source in $requiredSources) {
        foreach ($mode in @("missing", "wrong_type")) {
            $caseName = "source_$($source.Name)_$mode"
            $case = New-Case $caseName 0
            $sourcePath = Join-Path $case.Root $source.RelativePath
            if (Test-Path -LiteralPath $sourcePath) {
                Remove-Item -LiteralPath $sourcePath -Recurse -Force
            }
            if ($mode -eq "wrong_type") {
                if ($source.Type -eq "Leaf") {
                    New-Item -ItemType Directory -Force $sourcePath | Out-Null
                } else {
                    Set-Content -Path $sourcePath -Value "wrong type" -Encoding ASCII
                }
            }
            $result = Invoke-Deploy $case
            $sentinels = @($case.Installed | ForEach-Object {
                if (Test-Path -LiteralPath $_) { Get-Content -Raw -LiteralPath $_ }
                else { "<missing>" }
            })
            $sentinelText = ($sentinels | ForEach-Object { $_.Trim() }) -join "|"
            $sentinelsUnchanged = $sentinelText -eq "old main|old module|old icon|old legacy"
            $gateSkipped = -not (Test-Path -LiteralPath (Join-Path $case.Root "check-ran.txt"))
            Assert-True "${caseName}_fails_before_gate_without_install_changes" `
                (($result.Code -ne 0) -and
                 ($result.Text.Contains("deployment source missing: $($source.RelativePath)")) -and
                 $gateSkipped -and $sentinelsUnchanged) `
                "code $($result.Code), gateSkipped $gateSkipped, sentinels '$($sentinels -join '|')', output $($result.Text)"
        }
    }
} finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failed -gt 0) { Write-Host "test_deploy: $($script:failed) FAILED"; exit 1 }
Write-Host "test_deploy: all OK"
