param(
  [string]$APIVersion,
  [string]$Arguments = '',
  [string]$BlobStorageSuffix,
  [string]$BuildDir = '',
  [string]$Name,
  [string]$Uri,
  [string]$UserAssignedIdentityClientId
)

$ErrorActionPreference = 'Stop'
$LogFile = "$env:SystemRoot\Logs\$Name.log"

function Write-Log {
  param([string]$Message)
  $Entry = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')] $Message"
  Add-Content -Path $LogFile -Value $Entry -ErrorAction SilentlyContinue
  Write-Output $Entry
}

function Split-ArgumentString {
  param([string]$ArgumentString)

  if ([string]::IsNullOrWhiteSpace($ArgumentString)) { return @() }

  $arguments = @()
  $currentArg = ''
  $inQuotes = $false
  $quoteChar = $null

  for ($i = 0; $i -lt $ArgumentString.Length; $i++) {
    $char = $ArgumentString[$i]
    if (!$inQuotes -and (($char -eq '"' -and ($i -eq 0 -or $ArgumentString[$i - 1] -ne '\')) -or $char -eq "'")) {
      $inQuotes = $true
      $quoteChar = $char
      $currentArg += $char
    }
    elseif ($inQuotes -and $char -eq $quoteChar) {
      $inQuotes = $false
      $quoteChar = $null
      $currentArg += $char
    }
    elseif ($char -eq ' ' -and !$inQuotes) {
      if ($currentArg.Length -gt 0) {
        $value = $currentArg.Trim('"').Trim("'")
        if ($value -eq 'true') { $arguments += '$true' }
        elseif ($value -eq 'false') { $arguments += '$false' }
        else { $arguments += $value }
        $currentArg = ''
      }
    }
    else {
      $currentArg += $char
    }
  }
  if ($currentArg.Length -gt 0) {
    $value = $currentArg.Trim('"').Trim("'")
    if ($value -eq 'true') { $arguments += '$true' }
    elseif ($value -eq 'false') { $arguments += '$false' }
    else { $arguments += $value }
  }
  return $arguments
}

function ConvertTo-ParametersSplat {
  param([string]$ArgumentString)

  if ([string]::IsNullOrWhiteSpace($ArgumentString)) { return @{} }

  $tokens = Split-ArgumentString -ArgumentString $ArgumentString
  $parameters = @{}
  $i = 0
  while ($i -lt $tokens.Count) {
    $token = $tokens[$i]
    if ($token -match '^-(\w+)$') {
      $paramName = $matches[1]
      if (($i + 1) -lt $tokens.Count -and $tokens[$i + 1] -notmatch '^-\w+$') {
        $i++
        $value = $tokens[$i]
        if ($value -eq '$true') { $parameters[$paramName] = $true }
        elseif ($value -eq '$false') { $parameters[$paramName] = $false }
        else { $parameters[$paramName] = $value.Trim('"') }
      }
      else {
        $parameters[$paramName] = $true
      }
    }
    $i++
  }
  return $parameters
}

try {
  Write-Log "Starting '$Name' customization."
  Write-Log ($PSBoundParameters | Format-Table -AutoSize | Out-String)

  If ($Arguments -eq '') { $Arguments = $null }

  If ($BuildDir -ne '') {
    $TempDir = Join-Path $BuildDir -ChildPath $Name
  }
  Else {
    $TempDir = Join-Path $Env:TEMP -ChildPath $Name
  }
  New-Item -Path $TempDir -ItemType Directory -Force | Out-Null

  $WebClient = New-Object System.Net.WebClient
  If ($Uri -match $BlobStorageSuffix -and $UserAssignedIdentityClientId -ne '') {
    Write-Log "Getting access token for '$Uri' using User Assigned Identity."
    $StorageEndpoint = ($Uri -split '://')[0] + '://' + ($Uri -split '/')[2] + '/'
    $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$APIVersion&resource=$StorageEndpoint&client_id=$UserAssignedIdentityClientId"
    $AccessToken = ((Invoke-WebRequest -Headers @{Metadata = $true} -Uri $TokenUri -UseBasicParsing).Content | ConvertFrom-Json).access_token
    $WebClient.Headers.Add('x-ms-version', '2017-11-09')
    $WebClient.Headers.Add('Authorization', "Bearer $AccessToken")
  }

  $SourceFileName = ($Uri -split '/')[-1]
  Write-Log "Downloading '$Uri' to '$TempDir'."
  $DestFile = Join-Path -Path $TempDir -ChildPath $SourceFileName
  $WebClient.DownloadFile("$Uri", "$DestFile")
  Start-Sleep -Seconds 10

  If (!(Test-Path -Path $DestFile)) {
    Write-Log "Download completed but '$DestFile' not found on disk."
    Exit 1
  }
  Write-Log 'Download complete.'

  Set-Location -Path $TempDir
  $Ext = [System.IO.Path]::GetExtension($DestFile).ToLower().Replace('.', '')
  $env:SUPPRESS_FILELOG = '1'
  try {
    switch ($Ext) {
      'exe' {
        If ($Arguments) {
          Write-Log "Executing '`"$DestFile`" $Arguments'"
          $Install = Start-Process -FilePath "$DestFile" -ArgumentList (Split-ArgumentString -ArgumentString $Arguments) -NoNewWindow -Wait -PassThru
          Write-Log "Installation ended with exit code $($Install.ExitCode)."
        }
        Else {
          Write-Log "Executing '$DestFile'"
          $Install = Start-Process -FilePath "$DestFile" -NoNewWindow -Wait -PassThru
          Write-Log "Installation ended with exit code $($Install.ExitCode)."
        }
      }
      'msi' {
        If ($Arguments) {
          $Arguments = Split-ArgumentString -ArgumentString $Arguments
          If ($Arguments -notcontains $DestFile) {
            $Arguments = @("/i $DestFile") + $Arguments
          }
          Write-Log "Executing 'msiexec.exe $Arguments'"
          $MsiExec = Start-Process -FilePath msiexec.exe -ArgumentList $Arguments -Wait -PassThru
          Write-Log "Installation ended with exit code $($MsiExec.ExitCode)."
        }
        Else {
          Write-Log "Executing 'msiexec.exe /i $DestFile /qn'"
          $MsiExec = Start-Process -FilePath msiexec.exe -ArgumentList "/i $DestFile /qn" -Wait -PassThru
          Write-Log "Installation ended with exit code $($MsiExec.ExitCode)."
        }
      }
      'bat' {
        If ($Arguments) {
          Write-Log "Executing 'cmd.exe `"$DestFile`" $Arguments'"
          $BatArgs = Split-ArgumentString -ArgumentString $Arguments
          If ($BatArgs -notcontains $DestFile) { $BatArgs = @("$DestFile") + $BatArgs }
          Start-Process -FilePath cmd.exe -ArgumentList $BatArgs -Wait
        }
        Else {
          Write-Log "Executing 'cmd.exe `"$DestFile`"'"
          Start-Process -FilePath cmd.exe -ArgumentList "`"$DestFile`"" -Wait
        }
      }
      'ps1' {
        If ($Arguments) {
          Write-Log "Calling '$DestFile' with arguments '$Arguments'"
          $parameterSplat = ConvertTo-ParametersSplat -ArgumentString $Arguments
          & $DestFile @parameterSplat
        }
        Else {
          Write-Log "Calling '$DestFile'"
          & $DestFile
        }
      }
      'zip' {
        $DestinationPath = Join-Path -Path $TempDir -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($SourceFileName))
        Write-Log "Extracting '$DestFile' to '$DestinationPath'."
        Expand-Archive -Path $DestFile -DestinationPath $DestinationPath -Force
        Write-Log "Finding PowerShell script in '$DestinationPath'."
        $PSScript = (Get-ChildItem -Path $DestinationPath -Filter '*.ps1').FullName
        If ($PSScript.Count -gt 1) { $PSScript = $PSScript[0] }
        If ($Arguments) {
          Write-Log "Calling '$PSScript' with arguments '$Arguments'"
          $parameterSplat = ConvertTo-ParametersSplat -ArgumentString $Arguments
          & $PSScript @parameterSplat
        }
        Else {
          Write-Log "Calling '$PSScript'"
          & $PSScript
        }
      }
    }
  }
  finally {
    $env:SUPPRESS_FILELOG = $null
  }

  If ((Split-Path $TempDir -Parent) -eq $Env:TEMP) {
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-Log "'$Name' customization complete."
}
catch {
  Write-Log "FATAL: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
  If ($_.Exception.InnerException) {
    Write-Log "Inner exception: $($_.Exception.InnerException.Message)"
  }
  Write-Log $_.ScriptStackTrace
  Exit 1
}