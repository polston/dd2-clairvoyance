function ConvertTo-LuaPathLiteral([string]$Path) {
    $escaped = $Path.Replace('\', '\\').Replace("'", "\'")
    $escaped = $escaped.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return "'$escaped'"
}

function New-QnmlTempFilePath([string]$Directory, [string]$Prefix, [string]$Extension) {
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $name = $Prefix + [guid]::NewGuid().ToString("N") + $Extension
    return Join-Path $Directory $name
}
