$ErrorActionPreference = 'Stop'

try {
    $DriveLetter = $env:SystemDrive.TrimEnd(':')
    Update-HostStorageCache -ErrorAction SilentlyContinue
    $Part = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
    $CurrentSizeGB = [math]::Round($Part.Size / 1GB, 2)
    Write-Output "Current partition size: $CurrentSizeGB GB (drive: $DriveLetter)"

    # Use diskpart to extend - bypasses VDS entirely, no timing race on first boot.
    $diskpartScript = "select disk $($Part.DiskNumber)`r`nselect partition $($Part.PartitionNumber)`r`nextend"
    $scriptPath = Join-Path $env:TEMP 'diskpart_extend.txt'
    [System.IO.File]::WriteAllText($scriptPath, $diskpartScript, [System.Text.Encoding]::ASCII)
    $diskpartOutput = & diskpart /s $scriptPath 2>&1
    Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
    Write-Output "Diskpart result: $($diskpartOutput -join ' | ')"

    $PartAfter = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if ($PartAfter -and $PartAfter.Size -gt $Part.Size) {
        $NewSizeGB = [math]::Round($PartAfter.Size / 1GB, 2)
        Write-Output "OS partition resized successfully: $CurrentSizeGB GB -> $NewSizeGB GB"
    } else {
        Write-Output "OS partition is already at maximum size. No resize needed."
    }
}
catch {
    Write-Error "Failed to resize OS partition: $($_.Exception.Message)"
    exit 1
}
