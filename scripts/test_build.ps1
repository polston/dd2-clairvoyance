# Tests for build-zip.ps1 and provenance.ps1 (python scan). Uses an ignored,
# project-local scratch root and a stub extractor; never touches the tools/ key.
param([string]$Python = "python")
$ErrorActionPreference = "Stop"
$repo = Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:failed = 0
$base = Join-Path $repo "dist/test-tmp/qnml_build_test_$PID"
New-Item -ItemType Directory -Force $base | Out-Null

$havePython = $false
try { & $Python --version | Out-Null; $havePython = ($LASTEXITCODE -eq 0) } catch { $havePython = $false }
if (-not $havePython) { Write-Host "build tests: skipped (no Python)" }

function New-Case([string]$name, [string]$stub, [switch]$NoIcons, [switch]$NoHints, [switch]$NoQuests) {
    $d = Join-Path $base $name
    $root = Join-Path $d "root"
    New-Item -ItemType Directory -Force (Join-Path $root "tools") | Out-Null
    Copy-Item (Join-Path $repo "modinfo.ini") $root
    New-Item -ItemType Directory -Force (Join-Path $root "reframework") | Out-Null
    Copy-Item (Join-Path $repo "reframework/autorun") (Join-Path $root "reframework") -Recurse
    if (-not $NoIcons) {
        $imgs = Join-Path $root "reframework/images/Clairvoyance"
        New-Item -ItemType Directory -Force $imgs | Out-Null
        Copy-Item (Join-Path $repo "reframework/images/Clairvoyance/*") $imgs -Recurse -Force
    }
    if (-not $NoHints) {
        New-Item -ItemType Directory -Force (Join-Path $root "data") | Out-Null
        Copy-Item (Join-Path $repo "data/Clairvoyance_hints.json") (Join-Path $root "data")
    }
    if (-not $NoQuests) {
        New-Item -ItemType Directory -Force (Join-Path $root "data") | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $root "data/Clairvoyance_quests.json"), [System.Text.Encoding]::ASCII.GetBytes('{"version":1,"pak":"0:0","quests":{}}'))
    }
    Set-Content -Path (Join-Path $root "tools/extract_world.py") -Value $stub -Encoding ASCII
    $game = Join-Path $d "game"
    New-Item -ItemType Directory -Force $game | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $game "re_chunk_000.pak"), [byte[]]@())
    $key = Join-Path $d "key.txt"
    Set-Content -Path $key -Value "00" -Encoding ASCII
    return @{ Root = $root; Game = $game; Key = $key; Out = (Join-Path $d "out") }
}
function Invoke-Build($c, [string[]]$extra) {
    $args2 = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $repo "scripts/build-zip.ps1"),
        "-Root", $c.Root, "-OutDir", $c.Out, "-Python", $Python) + $extra
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $text = & powershell @args2 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    return @{ Code = $code; Text = $text }
}
$toolsRe = '^(\./)?tools(/|$)'
function Assert-True([string]$name, [bool]$ok, [string]$why) {
    if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name : $why"; $script:failed++ }
}
function Get-Entries([string]$zip) {
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try { return @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
}

try {
if ($havePython) {
    # 1
    $stub = "import sys, os`na = sys.argv`no = a[a.index('--out') + 1]`nos.makedirs(os.path.dirname(o), exist_ok=True)`nopen(o, 'w').write('{}')"
    # The stub writes the out file and still exits 1, so only the exit-code check can fail the build.
    $c = New-Case "t1" ($stub + "`nsys.exit(1)")
    $r = Invoke-Build $c @("-GameDir", $c.Game, "-KeyFile", $c.Key)
    Assert-True "extractor_failure_fails_build" (($r.Code -ne 0) -and ($r.Text -match "extractor failed")) "exit was $($r.Code)"
    # 2
    $c = New-Case "t2" $stub
    $r = Invoke-Build $c @("-GameDir", $c.Game, "-KeyFile", $c.Key)
    $zip = Join-Path $c.Out "Clairvoyance.zip"
    $ok = ($r.Code -eq 0) -and (Test-Path $zip)
    $e = @(); if ($ok) { $e = Get-Entries $zip }
    Assert-True "zip_contents" ($ok -and ($e -contains "reframework/data/Clairvoyance_places.json") -and ($e -contains "reframework/data/Clairvoyance_hints.json") -and ($e -contains "reframework/data/Clairvoyance_quests.json") -and ($e -contains "reframework/images/Clairvoyance/icons/index.json") -and ($e -contains "reframework/images/Clairvoyance/icons/52.png") -and -not ($e | Where-Object { $_ -match $toolsRe }) -and -not ($e | Where-Object { $_ -match "^reframework/images/.*[^/]$" -and $_ -notmatch "^reframework/images/Clairvoyance/icons/(index\.json|[0-9]+\.png)$" })) "code $($r.Code) entries $($e -join ',')"
    # the icons folder is required: a scratch repo without it fails the build
    $c = New-Case "t2b" $stub -NoIcons
    $r = Invoke-Build $c @("-GameDir", $c.Game, "-KeyFile", $c.Key)
    Assert-True "missing_icons_fails" (($r.Code -ne 0) -and ($r.Text -match "icons folder missing: reframework/images/Clairvoyance")) "code $($r.Code) text $($r.Text)"
    # prerequisites: pak, Python version, zstandard
    $c = New-Case "t6" $stub
    Remove-Item (Join-Path $c.Game "re_chunk_000.pak")
    $r = Invoke-Build $c @("-GameDir", $c.Game, "-KeyFile", $c.Key)
    Assert-True "missing_pak_fails" (($r.Code -ne 0) -and ($r.Text -match "re_chunk_000.pak")) "code $($r.Code)"
    foreach ($v in @(@{ n = "old_python_fails"; ver = "False"; zs = 0; want = "3.10" }, @{ n = "no_zstandard_fails"; ver = "True"; zs = 1; want = "zstandard" })) {
        $c = New-Case ("t7" + $v.n) $stub
        $cmd = Join-Path $c.Root "fakepy.cmd"
        $lines = @("@echo off", "if `"%~1`"==`"--version`" (echo Python 3.12 & exit /b 0)",
            "echo %* | findstr /c:`"version_info`" >nul && (echo $($v.ver) & exit /b 0)",
            "echo %* | findstr /c:`"zstandard`" >nul && exit /b $($v.zs)", "exit /b 0")
        Set-Content -Path $cmd -Value $lines -Encoding ASCII
        $saved = $Python; $Python = $cmd
        $r = Invoke-Build $c @("-GameDir", $c.Game, "-KeyFile", $c.Key)
        $Python = $saved
        Assert-True $v.n (($r.Code -ne 0) -and ($r.Text -match $v.want)) "code $($r.Code) text $($r.Text)"
    }
    # 4
    $c = New-Case "t4" "import sys`nsys.exit(0)"
    $r = Invoke-Build $c @("-GameDir", $c.Game, "-KeyFile", (Join-Path $c.Out "nokey.txt"))
    Assert-True "missing_key_fails" (($r.Code -ne 0) -and ($r.Text -match "key file")) "code $($r.Code)"
}
# the hints file is required: a scratch repo without it fails the build
$c = New-Case "t3b" "import sys`nsys.exit(1)" -NoHints
$r = Invoke-Build $c @("-NoPlaces")
Assert-True "missing_hints_fails" (($r.Code -ne 0) -and ($r.Text -match "hints file missing")) "code $($r.Code) text $($r.Text)"
# the quests file is required too
$c = New-Case "t3c" "import sys`nsys.exit(1)" -NoQuests
$r = Invoke-Build $c @("-NoPlaces")
Assert-True "missing_quests_fails" (($r.Code -ne 0) -and ($r.Text -match "quests file missing")) "code $($r.Code) text $($r.Text)"
# 3
$c = New-Case "t3" "import sys`nsys.exit(1)"
$r = Invoke-Build $c @("-NoPlaces")
$zip = Join-Path $c.Out "Clairvoyance-noplaces.zip"
$e = @(); if (Test-Path $zip) { $e = Get-Entries $zip }
Assert-True "noplaces_name" (($r.Code -eq 0) -and ($e.Count -gt 0) -and ($e -contains "reframework/data/Clairvoyance_hints.json") -and ($e -contains "reframework/data/Clairvoyance_quests.json") -and -not ($e | Where-Object { $_ -match $toolsRe })) "code $($r.Code)"
# tar returning nonzero must preserve its existing error and restore the caller's location.
$c = New-Case "tar-nonzero" "import sys`nsys.exit(1)"
$tarRoot = Join-Path $base "nonzero-system"
$tarSystem32 = Join-Path $tarRoot "System32"
New-Item -ItemType Directory -Force $tarSystem32 | Out-Null
Copy-Item (Join-Path $env:WINDIR "System32/findstr.exe") (Join-Path $tarSystem32 "tar.exe")
$wrapper = Join-Path $base "invoke-nonzero.ps1"
$buildScript = Join-Path $repo "scripts/build-zip.ps1"
$wrapperText = @"
`$ErrorActionPreference = 'Continue'
`$start = (Get-Location).Path
`$oldSystemRoot = `$env:SystemRoot
try {
    `$env:SystemRoot = '$tarRoot'
    & '$buildScript' -Root '$($c.Root)' -OutDir '$($c.Out)' -NoPlaces
} finally {
    `$env:SystemRoot = `$oldSystemRoot
    Write-Output "FINAL_LOCATION=`$((Get-Location).Path)"
    Write-Output "START_LOCATION=`$start"
    Write-Output "BUILD_STATUS=`$global:LASTEXITCODE"
    exit `$global:LASTEXITCODE
}
"@
[System.IO.File]::WriteAllText($wrapper, $wrapperText)
$old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$nonzeroText = & powershell -NoProfile -ExecutionPolicy Bypass -File $wrapper 2>&1 | Out-String
$nonzeroCode = $LASTEXITCODE
$ErrorActionPreference = $old
$expectedLocation = [regex]::Escape((Get-Location).Path)
Assert-True "tar_nonzero_fails_and_restores_location" (($nonzeroCode -ne 0) -and ($nonzeroText -match "tar failed") -and ($nonzeroText -match "FINAL_LOCATION=$expectedLocation") -and ($nonzeroText -match "START_LOCATION=$expectedLocation")) "code $nonzeroCode text $nonzeroText"
# A thrown tar command in this process must restore the location too.
$c = New-Case "tar-thrown" "import sys`nsys.exit(1)"
$start = (Get-Location).Path
$oldSystemRoot = $env:SystemRoot
$env:SystemRoot = Join-Path $base "missing-system"
$errorText = ""
try {
    try {
        & (Join-Path $repo "scripts/build-zip.ps1") -Root $c.Root -OutDir $c.Out -NoPlaces
        $thrown = $false
    } catch {
        $errorText = $_.Exception.Message
        $thrown = ($errorText -match "tar\.exe")
    }
    Assert-True "tar_thrown_restores_location" ($thrown -and ((Get-Location).Path -eq $start)) "thrown $thrown error $errorText location $((Get-Location).Path) expected $start"
} finally {
    $env:SystemRoot = $oldSystemRoot
    Set-Location $start
}
# 8 -PlacesFile: no Python, game or key needed; the file is staged verbatim
$c = New-Case "t8" "import sys`nsys.exit(1)"
$pf = Join-Path $base "t8_places.json"
[System.IO.File]::WriteAllBytes($pf, [System.Text.Encoding]::ASCII.GetBytes('{"places":[1,2,3]}'))
$r = Invoke-Build $c @("-PlacesFile", $pf)
$zip = Join-Path $c.Out "Clairvoyance.zip"
$e = @(); $same = $false
if (Test-Path $zip) {
    $e = Get-Entries $zip
    $x = Join-Path $base "t8_x"
    New-Item -ItemType Directory -Force $x | Out-Null
    Push-Location $x
    & "$env:SystemRoot\System32\tar.exe" -x -f $zip "reframework/data/Clairvoyance_places.json"
    Pop-Location
    $got = Join-Path $x "reframework/data/Clairvoyance_places.json"
    if (Test-Path $got) { $same = ([System.IO.File]::ReadAllText($got) -eq [System.IO.File]::ReadAllText($pf)) }
}
Assert-True "places_file_staged" (($r.Code -eq 0) -and ($e -contains "reframework/data/Clairvoyance_places.json") -and $same -and -not ($e | Where-Object { $_ -match $toolsRe })) "code $($r.Code) same $same entries $($e -join ',') text $($r.Text)"
# 9 -Version: staged modinfo.ini carries the version; the repo file is untouched
$c = New-Case "t9" "import sys`nsys.exit(1)"
$pf = Join-Path $base "t9_places.json"
[System.IO.File]::WriteAllBytes($pf, [System.Text.Encoding]::ASCII.GetBytes('{}'))
$before = [System.IO.File]::ReadAllText((Join-Path $repo "modinfo.ini"))
$r = Invoke-Build $c @("-PlacesFile", $pf, "-Version", "7.8.9")
$zip = Join-Path $c.Out "Clairvoyance.zip"
$ver = ""
if (Test-Path $zip) {
    $x = Join-Path $base "t9_x"
    New-Item -ItemType Directory -Force $x | Out-Null
    Push-Location $x
    & "$env:SystemRoot\System32\tar.exe" -x -f $zip "modinfo.ini"
    Pop-Location
    $lines = @(Get-Content (Join-Path $x "modinfo.ini") | Where-Object { $_ -match '^version=' })
    if ($lines.Count -eq 1) { $ver = $lines[0] }
}
$after = [System.IO.File]::ReadAllText((Join-Path $repo "modinfo.ini"))
Assert-True "version_stamped" (($r.Code -eq 0) -and ($ver -eq "version=7.8.9") -and ($before -eq $after)) "code $($r.Code) ver '$ver' text $($r.Text)"
# bad version is rejected
$r = Invoke-Build $c @("-PlacesFile", $pf, "-Version", "banana")
Assert-True "bad_version_fails" (($r.Code -ne 0) -and ($r.Text -match "version")) "code $($r.Code)"
# 5
$p = Join-Path $base "t5"
New-Item -ItemType Directory -Force (Join-Path $p "scripts") | Out-Null
Copy-Item (Join-Path $repo "scripts/provenance.ps1") (Join-Path $p "scripts")
Set-Content -Path (Join-Path $p "scripts/provenance.local.txt") -Value "" -Encoding ASCII
$word = "po" + "rt"
Set-Content -Path (Join-Path $p "x.py") -Value @("# $word of the thing", "x = 1") -Encoding ASCII
Push-Location $p
& git init -q . | Out-Null
& git add x.py scripts/provenance.ps1 | Out-Null
& git -c user.name=t -c user.email=t@t.invalid commit -q -m t | Out-Null
$old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $p "scripts/provenance.ps1") 2>&1 | Out-String
$code1 = $LASTEXITCODE
Set-Content -Path (Join-Path $p "x.py") -Value @("x = 1") -Encoding ASCII
$null = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $p "scripts/provenance.ps1") 2>&1 | Out-String
$code2 = $LASTEXITCODE
$ErrorActionPreference = $old
Pop-Location
Assert-True "provenance_py_comment" (($code1 -eq 1) -and ($out -match "x\.py:1") -and ($code2 -eq 0)) "codes $code1/$code2 out $out"

} finally {
    Pop-Location -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
}
if ($script:failed -gt 0) { Write-Host "test_build: $($script:failed) FAILED"; exit 1 }
Write-Host "test_build: all OK"
