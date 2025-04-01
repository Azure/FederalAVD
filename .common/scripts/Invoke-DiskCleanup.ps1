param(
    [string]$BuildDir='',
    [string]$CleanDesktop
)

try {
    [boolean]$CleanDesktop = [System.Convert]::ToBoolean($CleanDesktop) 
} catch [FormatException] {
    [boolean]$CleanDesktop = $false
}

If ($BuildDir -ne '' -and (Test-Path -Path $BuildDir)) {Remove-Item -Path $BuildDir -Recurse -Force | Out-Null}
If ($CleanDesktop) {
   $CommonDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
   Get-ChildItem -Path $CommonDesktop -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
Get-ChildItem -Path $env:SystemDrive -Exclude $env:SystemRoot\Logs\* -Include *.tmp, *.dmp, *.etl, *.evtx, thumbcache*.db, *.log -File -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
Get-ChildItem -Path $env:ProgramData\Microsoft\Windows\RetailDemo\* -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -ErrorAction SilentlyContinue
Remove-Item -Path $env:SystemRoot\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\ReportArchive\* -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $env:ProgramData\Microsoft\Windows\WER\ReportQueue\* -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
Clear-BCCache -Force -ErrorAction SilentlyContinue