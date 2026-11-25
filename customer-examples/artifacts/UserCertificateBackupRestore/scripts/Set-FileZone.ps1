function Read-ZoneId($file) {
    $readArgs = @{ LiteralPath = $file; Stream = 'Zone.Identifier'; TotalCount = 65537; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $readArgs.AsByteStream = $true } else { $readArgs.Encoding = 'Byte' }
    try { [byte[]]$bytes = @(Get-Content @readArgs) }
    catch { if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { return $null }; throw }
    if ($bytes.Length -gt 65536) { throw 'Zone.Identifier is too large; preserving it' }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        $text = [Text.UnicodeEncoding]::new($false, $true, $true).GetString($bytes, 2, $bytes.Length - 2)
    } else { $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, 0, $bytes.Length) }
    $inSection = $false
    foreach ($line in ($text.Split([char]0)[0] -split "`n")) {
        $line = $line.Trim(" `t`r".ToCharArray())
        if ($line.StartsWith(';')) { continue }
        if ($line.StartsWith('[')) {
            if ($inSection) { return $null }
            $inSection = $line -match '^\[[ \t]*ZoneTransfer[ \t]*\]'
        } elseif ($inSection -and $line -match '^ZoneId[ \t]*=(.*)$') {
            $value = $Matches[1].Trim(" `t".ToCharArray())
            if ($value -match '^(?:"(.*)"|''(.*)'')$') {
                $value = if ($Matches.ContainsKey(1)) { $Matches[1] } else { $Matches[2] }
            }
            $value = $value.TrimStart([char[]](0..32))
            $negative = $value.StartsWith('-')
            if ($negative -or $value.StartsWith('+')) { $value = $value.Substring(1) }
            $radix = 10
            if ($value -cmatch '^0([xob])') {
                $radix = @{ x = 16; o = 8; b = 2 }[$Matches[1]]
                $value = $value.Substring(2)
            }
            [long]$zone = 0
            $digits = 0
            foreach ($character in $value.ToCharArray()) {
                $digit = '0123456789abcdef'.IndexOf([char]::ToLowerInvariant($character))
                if ($digit -lt 0 -or $digit -ge $radix) { break }
                $zone = ($zone * $radix + $digit) -band 4294967295L
                $digits++
            }
            if ($negative) { $zone = (4294967296L - $zone) -band 4294967295L }
            if ($digits -gt 0 -and $zone -le 4) { return $zone }
            return $null
        }
    }
    return $null
}

function Copy-FileKeepingZone([string]$Source, [string]$Destination) {
    $sourceZone = Read-ZoneId $Source
    $destinationZone = if (Test-Path -LiteralPath $Destination) { Read-ZoneId $Destination } else { $null }
    [IO.File]::WriteAllBytes($Destination, [IO.File]::ReadAllBytes($Source))
    $minimum = if ($sourceZone -eq 4 -or $destinationZone -eq 4) { 4 } else { 3 }
    Set-FileZone $Destination $minimum
}

function Set-FileZone([string]$Path, [int]$MinimumZone = 3) {
    $existing = Read-ZoneId $Path
    if ($existing -notin 3, 4 -or ($MinimumZone -eq 4 -and $existing -ne 4)) {
        Set-Content -LiteralPath $Path -Stream Zone.Identifier -Encoding ASCII -Value '[ZoneTransfer]', "ZoneId=$MinimumZone", 'HostUrl=about:internet' -ErrorAction Stop
    }
    $verified = Read-ZoneId $Path
    if ($verified -notin 3, 4 -or ($MinimumZone -eq 4 -and $verified -ne 4)) { throw "File zone verification failed: $Path" }
}
