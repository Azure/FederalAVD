param(
  [string]$APIVersion,
  [string]$Arguments='',
  [string]$BlobStorageSuffix,
  [string]$Name,
  [string]$Uri,
  [string]$UserAssignedIdentityClientId
)

function Write-OutputWithTimeStamp {
  param(
      [string]$Message
  )    
  $Timestamp = Get-Date -Format 'MM/dd/yyyy HH:mm:ss'
  $Entry = '[' + $Timestamp + '] ' + $Message
  Write-Output $Entry
}

Start-Transcript -Path "$env:SystemRoot\Logs\$Name.log" -Force
Write-OutputWithTimeStamp "Starting '$Name' script with the following parameters."
Write-Output ( $PSBoundParameters | Format-Table -AutoSize )
If ($Arguments -eq '') { $Arguments = $null }
$TempDir = Join-Path $Env:TEMP -ChildPath $Name
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
$WebClient = New-Object System.Net.WebClient
If ($Uri -match $BlobStorageSuffix -and $UserAssignedIdentityClientId -ne '') {
  Write-OutputWithTimeStamp "Getting access token for '$Uri' using User Assigned Identity."
  $StorageEndpoint = ($Uri -split "://")[0] + "://" + ($Uri -split "/")[2] + "/"
  $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$APIVersion&resource=$StorageEndpoint&client_id=$UserAssignedIdentityClientId"
  $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true } -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
  $WebClient.Headers.Add('x-ms-version', '2017-11-09')
  $webClient.Headers.Add("Authorization", "Bearer $AccessToken")
}
$SourceFileName = ($Uri -Split "/")[-1]
Write-OutputWithTimeStamp "Downloading '$Uri' to '$TempDir'."
$DestFile = Join-Path -Path $TempDir -ChildPath $SourceFileName
$webClient.DownloadFile("$Uri", "$DestFile")
Start-Sleep -Seconds 10
If (!(Test-Path -Path $DestFile)) { Write-Error "Failed to download $SourceFileName"; Exit 1 }
Write-OutputWithTimeStamp 'Finished downloading'
Set-Location -Path $TempDir
$Ext = [System.IO.Path]::GetExtension($DestFile).ToLower().Replace('.','')
switch ($Ext) {
  'exe' {
      If ($Arguments) {
        Write-OutputWithTimeStamp "Executing '`"$DestFile`" $Arguments'"
        $Install = Start-Process -FilePath "$DestFile" -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
        Write-OutputWithTimeStamp "Installation ended with exit code $($Install.ExitCode)."
      }
      Else {
        Write-OutputWithTimeStamp "Executing `"$DestFile`""
        $Install = Start-Process -FilePath "$DestFile" -NoNewWindow -Wait -PassThru
        Write-OutputWithTimeStamp "Installation ended with exit code $($Install.ExitCode)."
      }      
    }
  'msi' {
    If ($Arguments) {
      If ($Arguments -notcontains $SourceFileName) {
        $Arguments = "/i $DestFile $Arguments"
      }
      Write-OutputWithTimeStamp "Executing 'msiexec.exe $Arguments'"
      $MsiExec = Start-Process -FilePath msiexec.exe -ArgumentList $Arguments -Wait -PassThru
      Write-OutputWithTimeStamp "Installation ended with exit code $($MsiExec.ExitCode)."

    }
    Else {
      Write-OutputWithTimeStamp "Executing 'msiexec.exe /i $DestFile /qn'"
      $MsiExec = Start-Process -FilePath msiexec.exe -ArgumentList "/i $DestFile /qn" -Wait -PassThru
      Write-OutputWithTimeStamp "Installation ended with exit code $($MsiExec.ExitCode)."
    }    
  }
  'bat' {
    If ($Arguments) {
      Write-OutputWithTimeStamp "Executing 'cmd.exe `"$DestFile`" $Arguments'"
      Start-Process -FilePath cmd.exe -ArgumentList "`"$DestFile`" $Arguments" -Wait
    }
    Else {
      Write-OutputWithTimeStamp "Executing 'cmd.exe `"$DestFile`"'"
      Start-Process -FilePath cmd.exe -ArgumentList "`"$DestFile`"" -Wait
    }
  }
  'ps1' {
    If ($Arguments) {
      Write-OutputWithTimeStamp "Calling PowerShell Script '$DestFile' with arguments '$Arguments'"
      & $DestFile $Arguments
    }
    Else {
      Write-OutputWithTimeStamp "Calling PowerShell Script '$DestFile'"
      & $DestFile
    }
  }
  'zip' {
    $DestinationPath = Join-Path -Path "$TempDir" -ChildPath $([System.IO.Path]::GetFileNameWithoutExtension($SourceFileName))
    Write-OutputWithTimeStamp "Extracting '$DestFile' to '$DestinationPath'."
    Expand-Archive -Path $DestFile -DestinationPath $DestinationPath -Force
    Write-OutputWithTimeStamp "Finding PowerShell script in root of '$DestinationPath'."
    $PSScript = (Get-ChildItem -Path $DestinationPath -filter '*.ps1').FullName
    If ($PSScript.count -gt 1) { $PSScript = $PSScript[0] }
    If ($Arguments) {
      Write-OutputWithTimeStamp "Calling PowerShell Script '$PSScript' with arguments '$Arguments'"
      & $PSScript $Arguments
    }
    Else {
      Write-OutputWithTimeStamp "Calling PowerShell Script '$PSScript'"         
      & $PSScript
    }
  }
}
Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Stop-Transcript