$Url = 'https://download.sysinternals.com/files/ProcessMonitor.zip'
$ZipFile = ($Url -split '/')[-1]
$ZipFile
$ZipFilePath = Join-Path -Path $env:TEMP -ChildPath $ZipFile
$ZipFilePath
Invoke-WebRequest -Uri $Url -OutFile $ZipFilePath
Expand-Archive -Path $ZipFilePath -DestinationPath $env:TEMP -Force
$ProcmonPath = (Get-ChildItem -Path $env:TEMP -Filter 'Procmon64.exe' -Recurse)[0].FullName
$ProcmonPath
Start-Process -FilePath $ProcmonPath -ArgumentList '/AcceptEula', '/Quiet', '/Backingfile', 'C:\ProcmonLog.pml', '/RunTime', '180'
Get-Process -Name 'Procmon64'