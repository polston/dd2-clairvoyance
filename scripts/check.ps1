# Syntax-checks all mod Lua files, scans for undeclared globals, runs the chunk-local
# gate and the unit tests (skipped by -NoTests), then the provenance check
# (skipped by -SkipProvenance: its pattern list is local and private, so CI cannot run it).
param([string]$Lua = "lua", [string]$Luac = "luac", [switch]$NoTests, [switch]$SkipProvenance)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot "check_util.ps1")
Push-Location $root
$fail = $false
# Globals REFramework provides, plus Lua 5.4 standard globals. Anything else
# read as a global in mod code is an undeclared global (Lua silently nils it).
$allowed = @("sdk","re","imgui","json","log","Vector3f","ValueType","thread",
  "require","table","string","math","os","pairs","ipairs","type","tostring",
  "tonumber","pcall","xpcall","error","assert","select","print","package",
  "rawget","rawset","setmetatable","getmetatable","next","io","_G","coroutine","draw","d2dx")
# Pure modules take every game access by injection: no host globals at all.
$pure = @("core.lua","settings_util.lua","minimap.lua","jump.lua","icons.lua","npcs.lua","style.lua")
$hostGlobals = @("sdk","re","imgui","json","log","Vector3f","ValueType","thread","draw","_G","d2dx")
Get-ChildItem -Recurse -Filter *.lua -Path (Join-Path $root "reframework") | ForEach-Object {
    $luaPath = ConvertTo-LuaPathLiteral $_.FullName
    & $Lua -e "assert(loadfile($luaPath))"
    if ($LASTEXITCODE -ne 0) { Write-Host "SYNTAX FAIL: $($_.FullName)"; $script:fail = $true }
    if (Get-Command $Luac -ErrorAction SilentlyContinue) {
        $listing = & $Luac -p -l $_.FullName
        $globals = $listing |
            Select-String "GETTABUP.*_ENV `"(\w+)`"" |
            ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
        # Global writes: none anywhere, except the one debug entry point
        # QNML_DEBUG written as _G.QNML_DEBUG by the main file (SPEC 16.10).
        $writes = $listing |
            Select-String "SETTABUP.*_ENV `"(\w+)`"" |
            ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique
        foreach ($w in $writes) {
            Write-Host "GLOBAL WRITE '$w' in $($_.FullName)"; $script:fail = $true
        }
        # Any other _G use (rawset(_G, ...), _G[...], an alias such as
        # local G = _G) can write a global the bytecode scan cannot see, so
        # every _G token is flagged except _G.QNML_DEBUG in the main file.
        $isMain = $_.Name -eq "Clairvoyance.lua"
        $gw = Select-String -Path $_.FullName -Pattern '(?<![\w.])_G(?!\w)(\s*\.\s*QNML_DEBUG(?!\w))?' -AllMatches
        foreach ($m in $gw) {
            foreach ($mm in $m.Matches) {
                if (-not ($isMain -and $mm.Groups[1].Success)) {
                    Write-Host "GLOBAL _G USE in $($_.FullName):$($m.LineNumber)"; $script:fail = $true
                }
            }
        }
        # _ENV itself (local e = _ENV; e.FOO = 1) is a global-table alias the
        # bytecode scan cannot see through, so any _ENV token is flagged.
        $ev = Select-String -Path $_.FullName -Pattern '(?<![\w.])_ENV(?!\w)' -AllMatches
        foreach ($m in $ev) {
            foreach ($mm in $m.Matches) {
                Write-Host "GLOBAL _ENV USE in $($_.FullName):$($m.LineNumber)"; $script:fail = $true
            }
        }
        foreach ($g in $globals) {
            if (($pure -contains $_.Name) -and ($_.FullName -match "Clairvoyance") -and ($hostGlobals -contains $g)) {
                Write-Host "HOST GLOBAL '$g' in pure module $($_.FullName)"; $script:fail = $true
            }
            if ($allowed -notcontains $g) {
                Write-Host "UNDECLARED GLOBAL '$g' in $($_.FullName)"; $script:fail = $true
            }
        }
    }
}
if (-not (Get-Command $Luac -ErrorAction SilentlyContinue)) {
    Write-Host "FAIL: $Luac not found; undeclared-global scan is a required gate"
    $fail = $true
}
# Locals gate (SPEC 18.3.7): how many extra chunk-level locals fit before
# Lua's 200 cap. Baselines: adapter 32, main 81, measured on the Task 6 change (parent 2932997).
$localsBaseline = @{
    "reframework/autorun/Clairvoyance/adapter.lua" = 32
    "reframework/autorun/Clairvoyance.lua" = 81
}
function Test-Fits([string[]]$lines, [int]$n, [string]$tmpRoot) {
    $idx = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^return(\s|$)') { $idx = $i; break } }
    $pad = @(1..$n | ForEach-Object { "local _qnml_pad$_ = nil" })
    if ($n -eq 0) { $pad = @() }
    if ($idx -ge 0) { $out = @($lines[0..($idx - 1)]) + $pad + @($lines[$idx..($lines.Count - 1)]) }
    else { $out = @($lines) + $pad }
    $tmp = New-QnmlTempFilePath $tmpRoot "probe_" ".lua"
    try {
        [System.IO.File]::WriteAllLines($tmp, $out)
        $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        & $Luac -p $tmp 2>&1 | Out-Null
        $ok = $LASTEXITCODE -eq 0
        $ErrorActionPreference = $old
        return $ok
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
if (Get-Command $Luac -ErrorAction SilentlyContinue) {
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "qnml_locals_probe_$PID"
    try {
        New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
        foreach ($rel in $localsBaseline.Keys) {
            $lines = [System.IO.File]::ReadAllLines((Join-Path $root $rel))
            $lo = 0; $hi = 200
            while ($lo -lt $hi) {
                $mid = [int][math]::Ceiling(($lo + $hi) / 2)
                if (Test-Fits $lines $mid $tmpRoot) { $lo = $mid } else { $hi = $mid - 1 }
            }
            $base = $localsBaseline[$rel]
            Write-Host "locals: $(Split-Path $rel -Leaf) fits $lo more (baseline $base)"
            if ($lo -lt $base) { Write-Host "LOCALS FAIL: $rel fits $lo, baseline $base"; $fail = $true }
        }
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if (-not $NoTests) {
Get-ChildItem -Filter *_test.lua -Path (Join-Path $root "tests") -ErrorAction SilentlyContinue | ForEach-Object {
    $name = $_.BaseName
    $out = @(& $Lua $_.FullName)
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) { Write-Host "TEST FAIL: $($_.FullName)"; $script:fail = $true }
    elseif ($out | Where-Object { "$_" -match "^FAIL" }) {
        Write-Host "TEST FAIL: $name printed a FAIL line"; $script:fail = $true
    }
    elseif (-not ($out | Where-Object { "$_" -match "^$name`: (all OK|all passed|OK)\s*$" })) {
        Write-Host "TEST FAIL: $name printed no all OK line"; $script:fail = $true
    }
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "test_check.ps1") -Lua $Lua
if ($LASTEXITCODE -ne 0) { Write-Host "CHECK TESTS FAIL"; $fail = $true }
}
# Every script must parse (a parse error would otherwise go unnoticed until it is run).
Get-ChildItem -Filter *.ps1 -Path (Join-Path $root "scripts") | ForEach-Object {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
    foreach ($e in $errs) { Write-Host "PARSE FAIL: $($_.Name):$($e.Extent.StartLineNumber)"; $script:fail = $true }
}
# Generated or secret files must never be tracked (SPEC 17.10.3).
$bad = @(& git ls-files reframework/data tools/pak_key.local.txt)
if ($bad.Count -gt 0) { Write-Host "TRACKED FORBIDDEN: $($bad -join ', ')"; $fail = $true }
# Build script tests (skip with a printed reason when Python is missing).
& powershell -NoProfile -File (Join-Path $root "scripts/test_build.ps1")
if ($LASTEXITCODE -ne 0) { Write-Host "BUILD TESTS FAIL"; $fail = $true }
# Deployment must run this gate before touching the installed mod.
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts/test_deploy.ps1")
if ($LASTEXITCODE -ne 0) { Write-Host "DEPLOY TESTS FAIL"; $fail = $true }
# Python tests: need Python and tools/test_extract.py.
$pyOk = $false
try { & python --version | Out-Null; $pyOk = ($LASTEXITCODE -eq 0) } catch { $pyOk = $false }
if (-not $pyOk) { Write-Host "python tests: skipped (no Python)" }
elseif (-not (Test-Path (Join-Path $root "tools/test_extract.py"))) { Write-Host "python tests: skipped (no tools/test_extract.py)" }
else {
    # No stderr redirection: unittest writes its OK line to stderr.
    & python -m unittest discover -s tools -p "test_*.py"
    if ($LASTEXITCODE -ne 0) { Write-Host "PYTHON TESTS FAIL"; $fail = $true }
}
# Release-version tests (tests/next_version_test.py); skipped when Python is missing.
if (-not $pyOk) { Write-Host "version tests: skipped (no Python)" }
else {
    & python -m unittest discover -s tests -p "next_version_test.py"
    if ($LASTEXITCODE -ne 0) { Write-Host "VERSION TESTS FAIL"; $fail = $true }
}
# Last check: no tracked line matches the provenance patterns (SPEC 18.8.1).
if ($SkipProvenance) { Write-Host "provenance: skipped (-SkipProvenance)" }
else {
    # Hint text must not copy a fetched reference page (8-word run); skipped when Python is missing.
    if ($pyOk) {
        & python -I (Join-Path $root "tools/hints_check.py")
        if ($LASTEXITCODE -ne 0) { Write-Host "HINTS CHECK FAIL"; $fail = $true }
    }
    & powershell -NoProfile -File (Join-Path $root "scripts/provenance.ps1")
    if ($LASTEXITCODE -ne 0) { Write-Host "PROVENANCE FAIL"; $fail = $true }
}
Pop-Location
if ($fail) { exit 1 }
Write-Host "check.ps1: all OK"
