param([string]$Lua = "lua")
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot "check_util.ps1")
$base = Join-Path $repo "dist/test-tmp/qnml_check_test_$PID"
$path = Join-Path $base "with space]]and'quote"
$script:failed = 0

function Assert-True([string]$name, [bool]$ok, [string]$why) {
    if ($ok) { Write-Host "PASS $name" }
    else { Write-Host "FAIL $name : $why"; $script:failed++ }
}

try {
    New-Item -ItemType Directory -Force $path | Out-Null
    $valid = Join-Path $path "valid.lua"
    $invalid = Join-Path $path "invalid.lua"
    [System.IO.File]::WriteAllText($valid, "return true", [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($invalid, "local =", [System.Text.Encoding]::ASCII)

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $validLiteral = ConvertTo-LuaPathLiteral $valid
    try {
        $validOutput = & $Lua -e "assert(loadfile($validLiteral))" 2>&1 | Out-String
        $validCode = $LASTEXITCODE
        Assert-True "valid_path_loads" ($validCode -eq 0) "exit $validCode; $validOutput"

        $invalidLiteral = ConvertTo-LuaPathLiteral $invalid
        $invalidOutput = & $Lua -e "assert(loadfile($invalidLiteral))" 2>&1 | Out-String
        $invalidCode = $LASTEXITCODE
        Assert-True "invalid_lua_fails" ($invalidCode -ne 0) "exit $invalidCode; $invalidOutput"
    } finally {
        $ErrorActionPreference = $oldPreference
    }
} finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}

if ($script:failed -gt 0) { Write-Host "test_check: $($script:failed) FAILED"; exit 1 }
Write-Host "test_check: all OK"
