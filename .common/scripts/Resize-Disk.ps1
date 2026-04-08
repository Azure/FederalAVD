$ErrorActionPreference = 'Stop'

try {
    $driveLetter = $env:SystemDrive.Substring(0, 1)

    $currentPartition = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
    $currentSizeGB    = [math]::Round($currentPartition.Size / 1GB, 2)
    Write-Output "Current partition size: $currentSizeGB GB (drive: $driveLetter)"

    $size    = Get-PartitionSupportedSize -DriveLetter $driveLetter -ErrorAction Stop
    $maxSizeGB = [math]::Round($size.SizeMax / 1GB, 2)
    $minSizeGB = [math]::Round($size.SizeMin / 1GB, 2)
    Write-Output "Partition supported size range: Min=$minSizeGB GB, Max=$maxSizeGB GB"

    if ($null -eq $size -or $size.SizeMax -eq 0) {
        Write-Warning "Get-PartitionSupportedSize returned null or zero SizeMax. Skipping resize."
        exit 0
    }

    if ($currentPartition.Size -ge $size.SizeMax) {
        Write-Output "Partition ($currentSizeGB GB) is already at or above maximum supported size ($maxSizeGB GB). No resize needed."
        exit 0
    }

    Resize-Partition -DriveLetter $driveLetter -Size $size.SizeMax -ErrorAction Stop
    Write-Output "OS partition resized successfully from $currentSizeGB GB to $maxSizeGB GB."
}
catch {
    if ($_.Exception.Message -like '*already the requested size*') {
        Write-Output "Partition is already at maximum size. No resize needed."
    }
    else {
        Write-Error "Failed to resize OS partition: $($_.Exception.Message)"
        exit 1
    }
}
