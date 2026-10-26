function ConvertTo-LuaPathLiteral([string]$Path) {
    $escaped = $Path.Replace('\', '\\').Replace("'", "\'")
    $escaped = $escaped.Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return "'$escaped'"
}
