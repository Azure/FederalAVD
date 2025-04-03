param(
    [string]$BuildDir='',
    [string]$CleanDesktop
)
Write-Output ">>> Cleaning up disk space"
try {
    [boolean]$CleanDesktop = [System.Convert]::ToBoolean($CleanDesktop) 
} catch [FormatException] {
    [boolean]$CleanDesktop = $false
}

If ($BuildDir -ne '' -and (Test-Path -Path $BuildDir)) {
    Write-Output ">>> Removing build directory [$BuildDir]"
    Remove-Item -Path $BuildDir -Recurse -Force | Out-Null
}
If ($CleanDesktop) {
   $CommonDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
   Write-Output ">>> Cleaning up common desktop [$CommonDesktop]"
   Get-ChildItem -Path $CommonDesktop -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
Write-Output ">>> Cleaning up tmp, dmp, etl, evtx, thumbcache, and log files"
Get-ChildItem -Path $env:SystemDrive -Exclude $env:SystemRoot\Logs\* -Include *.tmp, *.dmp, *.etl, *.evtx, thumbcache*.db, *.log -File -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
Write-Output ">>> Cleaning up RetailDemo content"
Get-ChildItem -Path $env:ProgramData\Microsoft\Windows\RetailDemo\* -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -ErrorAction SilentlyContinue
Write-Output ">>> Cleaning up Temp Directories"
Remove-Item -Path $env:SystemRoot\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ">>> Cleaning up WER content"
Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\ReportArchive\* -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\ReportQueue\* -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ">>> Emptying Recycle Bin"
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
Write-Output ">>> Cleaning up Branch Cache"
Clear-BCCache -Force -ErrorAction SilentlyContinue
Try {
    Write-Output ">>> Cleaning up Delivery Optimization Cache"
    Delete-DeliveryOptimizationCache -Force
} catch {
}