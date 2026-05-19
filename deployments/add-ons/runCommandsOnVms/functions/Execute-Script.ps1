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

Function Split-ArgumentString {
    param (
        [string]$ArgumentString
    )

    if ([string]::IsNullOrWhiteSpace($ArgumentString)) {
        return @()
    }

    # For PowerShell execution with &, we want individual arguments, not combined ones
    $arguments = @()
    $currentArg = ""
    $inQuotes = $false
    
    for ($i = 0; $i -lt $ArgumentString.Length; $i++) {
        $char = $ArgumentString[$i]
        
        if ($char -eq '"' -and ($i -eq 0 -or $ArgumentString[$i-1] -ne '\')) {
            $inQuotes = !$inQuotes
            $currentArg += $char
        }
        elseif ($char -eq ' ' -and !$inQuotes) {
            if ($currentArg.Length -gt 0) {
                # Handle boolean conversion
                $value = $currentArg.Trim('"')
                if ($value -eq 'true') {
                    $arguments += '$true'
                }
                elseif ($value -eq 'false') {
                    $arguments += '$false'
                }
                else {
                    $arguments += $value
                }
                $currentArg = ""
            }
        }
        else {
            $currentArg += $char
        }
    }
    
    # Add the last argument
    if ($currentArg.Length -gt 0) {
        $value = $currentArg.Trim('"')
        if ($value -eq 'true') {
            $arguments += '$true'
        }
        elseif ($value -eq 'false') {
            $arguments += '$false'
        }
        else {
            $arguments += $value
        }
    }
    
    return $arguments
}

Function ConvertTo-ParametersSplat {
    param (
        [string]$ArgumentString
    )

    if ([string]::IsNullOrWhiteSpace($ArgumentString)) {
        return @{}
    }

    $tokens = Split-ArgumentString -ArgumentString $ArgumentString
    $parameters = @{}
    
    $i = 0
    while ($i -lt $tokens.Count) {
        $token = $tokens[$i]
        
        # If this is a parameter (starts with -)
        if ($token -match '^-(\w+)$') {
            $paramName = $matches[1]  # Remove the dash
            
            # Check if there's a value following this parameter
            if (($i + 1) -lt $tokens.Count -and $tokens[$i + 1] -notmatch '^-\w+$') {
                # Parameter with value
                $i++  # Move to the value
                $value = $tokens[$i]
                
                # Handle PowerShell booleans
                if ($value -eq '$true') {
                    $parameters[$paramName] = $true
                }
                elseif ($value -eq '$false') {
                    $parameters[$paramName] = $false
                }
                else {
                    # Remove quotes if present
                    $cleanValue = $value.Trim('"')
                    $parameters[$paramName] = $cleanValue
                }
            }
            else {
                # This is a switch parameter (no value)
                $parameters[$paramName] = $true
            }
        }
        else {
            # Handle positional arguments (rare in this context)
            # You could add logic here if needed
        }
        
        $i++
    }
    
    return $parameters
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
        $Install = Start-Process -FilePath "$DestFile" -ArgumentList (Split-ArgumentString -ArgumentString $Arguments) -NoNewWindow -Wait -PassThru
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
      $Arguments = Split-ArgumentString -ArgumentString $Arguments
      If ($Arguments -notcontains $DestFile) {
        $InstallArg = "/i $DestFile"
        $Arguments = @($InstallArg) + $Arguments
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
      $Arguments = Split-ArgumentString -ArgumentString $Arguments
      If ($Arguments -notcontains $DestFile) {
        $Arguments = @("$DestFile") + $Arguments
      }
      Start-Process -FilePath cmd.exe -ArgumentList $Arguments -Wait
    }
    Else {
      Write-OutputWithTimeStamp "Executing 'cmd.exe `"$DestFile`"'"
      Start-Process -FilePath cmd.exe -ArgumentList "`"$DestFile`"" -Wait
    }
  }
  'ps1' {
    If ($Arguments) {
      Write-OutputWithTimeStamp "Calling PowerShell Script '$DestFile' with arguments '$Arguments'"
      $parameterSplat = ConvertTo-ParametersSplat -ArgumentString $Arguments
      & $DestFile @parameterSplat
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
      Write-OutputWithTimeStamp "Calling PowerShell Script '$DestFile' with arguments '$Arguments'"
      $parameterSplat = ConvertTo-ParametersSplat -ArgumentString $Arguments
      & $PSScript @parameterSplat
    }
    Else {
      Write-OutputWithTimeStamp "Calling PowerShell Script '$PSScript'"         
      & $PSScript
    }
  }
}
Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Stop-Transcript