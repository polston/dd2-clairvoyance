# Provenance check (SPEC 18.8.1): searches tracked files for patterns that
# must not appear. Prints each hit as path:line; exits 1 on any hit or when
# the local pattern file is missing. Lines containing the marker are skipped.
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
$marker = "provenance-pattern"
$fail = $false
$common = (& git rev-parse --git-common-dir).Trim()
$localFile = [System.IO.Path]::GetFullPath(([System.IO.Path]::Combine($root, $common, "..", "scripts", "provenance.local.txt")))
$local = @()
if (Test-Path $localFile) {
    $local = @(Get-Content $localFile | Where-Object { $_.Trim() -ne "" } |
        ForEach-Object { [regex]::new($_, "IgnoreCase") })
} else {
    Write-Host "provenance: local pattern file missing"
    $fail = $true
}
$general = @(
    [regex]::new('\bSQ\b', "IgnoreCase"), # provenance-pattern
    [regex]::new('Nexus', "IgnoreCase"), # provenance-pattern
    [regex]::new('not cleared', "IgnoreCase") # provenance-pattern
)
$copyWord = [regex]::new('\b[Pp]ort(ed|ing)?\b', "IgnoreCase") # provenance-pattern
foreach ($f in (& git ls-files)) {
    # The places file is generated game data (names and coordinates), not authored text.
    if ($f -eq "data/Clairvoyance_places.json") { continue }
    # Generated game art: random compressed bytes match the two-letter pattern.
    if ($f -like "reframework/images/*.png") { continue }
    $path = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $isMd = $f -match '\.md$'
    $isHash = $f -match '\.(py|ps1)$'
    $n = 0
    foreach ($line in [System.IO.File]::ReadLines($path)) {
        $n++
        if ($line.Contains($marker)) { continue }
        $hit = $false
        foreach ($r in ($general + $local)) { if ($r.IsMatch($line)) { $hit = $true; break } }
        if (-not $hit -and ($isMd -or $line -match '^\s*--' -or ($isHash -and $line -match '^\s*#')) -and $copyWord.IsMatch($line)) { $hit = $true }
        if ($hit) { Write-Host "${f}:${n}"; $fail = $true }
    }
}
Pop-Location
if ($fail) { exit 1 }
Write-Host "provenance: OK"
