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

function Get-WebException {
  param([System.Management.Automation.ErrorRecord]$ErrorRecord)

  $exception = $ErrorRecord.Exception
  while ($exception.InnerException -and -not ($exception -is [System.Net.WebException])) {
    $exception = $exception.InnerException
  }
  return $exception
}

function Get-WebFailureDetail {
  param(
    [System.Management.Automation.ErrorRecord]$ErrorRecord,
    [ValidateSet('ManagedIdentity', 'Download')]
    [string]$Operation
  )

  $exception = Get-WebException -ErrorRecord $ErrorRecord
  $response = $exception.Response
  $statusCode = if ($response -and $null -ne $response.StatusCode) { [int]$response.StatusCode } else { $null }
  $webStatus = if ($exception -is [System.Net.WebException]) { $exception.Status } else { $null }
  $category = if ($Operation -eq 'ManagedIdentity' -and $statusCode -eq 400) {
    'IdentityUnavailable'
  }
  elseif ($webStatus -in @('ConnectFailure', 'ConnectionClosed', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ReceiveFailure', 'SendFailure', 'Timeout')) {
    if ($Operation -eq 'ManagedIdentity') { 'ImdsConnectivity' } else { 'StorageConnectivity' }
  }
  elseif ($null -ne $statusCode) {
    "Http$statusCode"
  }
  else {
    'UnexpectedError'
  }

  $parts = @("Category=$category")
  if ($null -ne $statusCode) { $parts += "HTTP=$statusCode" }
  if ($null -ne $webStatus) { $parts += "WebStatus=$webStatus" }
  $parts += "Message=$($exception.Message)"
  if ($response) {
    try {
      $responseStream = $response.GetResponseStream()
      if ($responseStream) {
        $reader = New-Object System.IO.StreamReader($responseStream)
        $responseBody = ($reader.ReadToEnd() -replace '\s+', ' ').Trim()
        $reader.Dispose()
        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
          if ($responseBody.Length -gt 1000) { $responseBody = $responseBody.Substring(0, 1000) }
          $parts += "Response=$responseBody"
        }
      }
    }
    catch {
      # Preserve the original failure when the response stream cannot be read.
    }
  }
  return $parts -join '; '
}

function Test-TransientManagedIdentityFailure {
  param([System.Management.Automation.ErrorRecord]$ErrorRecord)

  $exception = Get-WebException -ErrorRecord $ErrorRecord
  $response = $exception.Response
  $statusCode = if ($response -and $null -ne $response.StatusCode) { [int]$response.StatusCode } else { $null }
  if ($statusCode -in @(400, 408, 429, 500, 502, 503, 504)) { return $true }
  if ($exception -is [System.Net.WebException]) {
    return $exception.Status -in @(
      'ConnectFailure',
      'ConnectionClosed',
      'KeepAliveFailure',
      'NameResolutionFailure',
      'PipelineFailure',
      'ProxyNameResolutionFailure',
      'ReceiveFailure',
      'RequestCanceled',
      'SendFailure',
      'Timeout'
    )
  }
  return $false
}

function Test-TransientDownloadFailure {
  param([System.Management.Automation.ErrorRecord]$ErrorRecord)

  $exception = Get-WebException -ErrorRecord $ErrorRecord
  $response = $exception.Response
  $statusCode = if ($response -and $null -ne $response.StatusCode) { [int]$response.StatusCode } else { $null }
  if ($statusCode -in @(400, 403, 408, 429, 500, 502, 503, 504)) { return $true }
  if ($exception -is [System.Net.WebException]) {
    return $exception.Status -in @(
      'ConnectFailure',
      'ConnectionClosed',
      'KeepAliveFailure',
      'NameResolutionFailure',
      'PipelineFailure',
      'ProxyNameResolutionFailure',
      'ReceiveFailure',
      'RequestCanceled',
      'SendFailure',
      'Timeout'
    )
  }
  return $false
}

function Get-ManagedIdentityAccessToken {
  param(
    [string]$TokenUri,
    [int]$MaxAttempts = 12,
    [int]$RetryDelaySeconds = 10
  )

  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $responseReceived = $false
    try {
      $response = Invoke-WebRequest -Headers @{Metadata = $true} -Uri $TokenUri -UseBasicParsing
      $responseReceived = $true
      $accessToken = ($response.Content | ConvertFrom-Json).access_token
      if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw 'Managed identity endpoint returned an empty access token.'
      }
      return $accessToken
    }
    catch {
      $failureDetail = Get-WebFailureDetail -ErrorRecord $_ -Operation ManagedIdentity
      $isTransient = $responseReceived -or (Test-TransientManagedIdentityFailure -ErrorRecord $_)
      if (-not $isTransient) {
        throw "Managed identity token request failed without retry. $failureDetail"
      }
      if ($attempt -eq $MaxAttempts) {
        throw "Managed identity token request failed after $MaxAttempts attempts. $failureDetail"
      }
      Write-Log "Managed identity token request attempt $attempt of $MaxAttempts failed. $failureDetail Retrying in $RetryDelaySeconds seconds."
      Start-Sleep -Seconds $RetryDelaySeconds
    }
  }
}

function Invoke-ArtifactDownload {
  param(
    $WebClient,
    [string]$Uri,
    [string]$DestinationPath,
    [int]$MaxAttempts = 6,
    [int]$RetryDelaySeconds = 10
  )

  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      $WebClient.DownloadFile($Uri, $DestinationPath)
      return
    }
    catch {
      $failureDetail = Get-WebFailureDetail -ErrorRecord $_ -Operation Download
      $isTransient = Test-TransientDownloadFailure -ErrorRecord $_
      Remove-Item -Path $DestinationPath -Force -ErrorAction SilentlyContinue
      if (-not $isTransient) {
        throw "Artifact download failed without retry. $failureDetail"
      }
      if ($attempt -eq $MaxAttempts) {
        throw "Artifact download failed after $MaxAttempts attempts. $failureDetail"
      }
      Write-Log "Artifact download attempt $attempt of $MaxAttempts failed. $failureDetail Retrying in $RetryDelaySeconds seconds."
      Start-Sleep -Seconds $RetryDelaySeconds
    }
  }
}

function Split-ArgumentString {
  param([string]$ArgumentString)

  if ([string]::IsNullOrWhiteSpace($ArgumentString)) { return @() }

  $arguments = @()
  $currentArg = ''
  $inQuotes = $false
  $quoteChar = $null
  $parenDepth = 0  # tracks @(...) nesting; spaces inside are not token separators

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
    elseif (!$inQuotes -and $char -eq '(' -and $currentArg -match '@$') {
      $parenDepth++
      $currentArg += $char
    }
    elseif (!$inQuotes -and $char -eq ')' -and $parenDepth -gt 0) {
      $parenDepth--
      $currentArg += $char
    }
    elseif ($char -eq ' ' -and !$inQuotes -and $parenDepth -eq 0) {
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

function Split-MsiArgumentString {
  param([string]$ArgumentString)

  if ([string]::IsNullOrWhiteSpace($ArgumentString)) { return @() }

  $arguments = @()
  $currentArgument = [System.Text.StringBuilder]::new()
  $inQuotes = $false

  for ($index = 0; $index -lt $ArgumentString.Length; $index++) {
    $character = $ArgumentString[$index]
    if ($character -eq '"') {
      $inQuotes = -not $inQuotes
    }
    elseif ([char]::IsWhiteSpace($character) -and -not $inQuotes) {
      if ($currentArgument.Length -gt 0) {
        $arguments += $currentArgument.ToString()
        $null = $currentArgument.Clear()
      }
    }
    else {
      $null = $currentArgument.Append($character)
    }
  }

  if ($inQuotes) { throw 'MSI arguments contain an unterminated double quote.' }
  if ($currentArgument.Length -gt 0) { $arguments += $currentArgument.ToString() }
  return $arguments
}

function ConvertTo-WindowsCommandLineArgument {
  param([AllowEmptyString()][string]$Argument)

  if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }

  $quotedArgument = [System.Text.StringBuilder]::new()
  $null = $quotedArgument.Append('"')
  $backslashCount = 0
  foreach ($character in $Argument.ToCharArray()) {
    if ($character -eq '\') {
      $backslashCount++
    }
    elseif ($character -eq '"') {
      $null = $quotedArgument.Append(('\' * (($backslashCount * 2) + 1)))
      $null = $quotedArgument.Append('"')
      $backslashCount = 0
    }
    else {
      $null = $quotedArgument.Append(('\' * $backslashCount))
      $null = $quotedArgument.Append($character)
      $backslashCount = 0
    }
  }
  $null = $quotedArgument.Append(('\' * ($backslashCount * 2)))
  $null = $quotedArgument.Append('"')
  return $quotedArgument.ToString()
}

function Get-MsiArgumentList {
  param(
    [string]$InstallerPath,
    [string]$ArgumentString
  )

  [string[]]$msiArguments = @(
    Split-MsiArgumentString -ArgumentString $ArgumentString |
      Where-Object { -not [string]::IsNullOrEmpty($_) }
  )
  if ($msiArguments | Where-Object { $_ -match '^/(i|package|x|uninstall)$' }) {
    throw 'Do not specify an MSI package operation or path. The downloaded MSI is installed automatically.'
  }
  if ($msiArguments | Where-Object { $_ -match '^/(forcerestart|promptrestart)$' }) {
    throw 'MSI arguments cannot request or prompt for a restart.'
  }

  $msiArguments = @('/i', $InstallerPath) + $msiArguments
  if (-not ($msiArguments | Where-Object { $_ -match '^/(qn|quiet)$' })) {
    $msiArguments += '/quiet'
  }
  if (-not ($msiArguments | Where-Object { $_ -ieq '/norestart' })) {
    $msiArguments += '/norestart'
  }
  return $msiArguments
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
        elseif ($value -match '^@\((.+)\)$') {
          # @('val1', 'val2') or @("val1", "val2") array literal.
          # Split-ArgumentString keeps the whole @(...) as one token via paren-depth tracking.
          $parameters[$paramName] = [string[]]($matches[1] -split ',' |
            ForEach-Object { $_.Trim().Trim("'").Trim('"') } |
            Where-Object { $_ -ne '' })
        }
        elseif ($value.EndsWith(',')) {
          # "val1", "val2" style: first token ended with a comma; collect the rest.
          $items = [System.Collections.Generic.List[string]]::new()
          $items.Add($value.TrimEnd(',').Trim('"').Trim("'"))
          while (($i + 1) -lt $tokens.Count -and $tokens[$i + 1] -notmatch '^-\w+$') {
            $i++
            $nextVal = $tokens[$i]
            $items.Add($nextVal.TrimEnd(',').Trim('"').Trim("'"))
            if (-not $nextVal.EndsWith(',')) { break }
          }
          $parameters[$paramName] = [string[]]$items
        }
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

  # Force TLS 1.2  -  fresh marketplace images default to TLS 1.0/1.1 which Azure Storage rejects.
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $WebClient = New-Object System.Net.WebClient
  If ($Uri -match $BlobStorageSuffix -and $UserAssignedIdentityClientId -ne '') {
    Write-Log "Getting access token for '$Uri' using User Assigned Identity."
    $StorageEndpoint = ($Uri -split '://')[0] + '://' + ($Uri -split '/')[2] + '/'
    $TokenUri = "http://169.254.169.254/metadata/identity/oauth2/token?api-version=$APIVersion&resource=$StorageEndpoint&client_id=$UserAssignedIdentityClientId"
    $AccessToken = Get-ManagedIdentityAccessToken -TokenUri $TokenUri
    $WebClient.Headers.Add('x-ms-version', '2017-11-09')
    $WebClient.Headers.Add('Authorization', "Bearer $AccessToken")
  }

  $SourceFileName = ($Uri -split '/')[-1]
  Write-Log "Downloading '$Uri' to '$TempDir'."
  $DestFile = Join-Path -Path $TempDir -ChildPath $SourceFileName
  Invoke-ArtifactDownload -WebClient $WebClient -Uri $Uri -DestinationPath $DestFile
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
        $MsiArguments = Get-MsiArgumentList -InstallerPath $DestFile -ArgumentString $Arguments
        $MsiCommandLine = ($MsiArguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Argument $_ }) -join ' '
        Write-Log "Executing 'msiexec.exe $MsiCommandLine'"
        $MsiExec = Start-Process -FilePath msiexec.exe -ArgumentList $MsiCommandLine -Wait -PassThru
        Write-Log "Installation ended with exit code $($MsiExec.ExitCode)."
        if ($MsiExec.ExitCode -notin @(0, 3010)) {
          throw "MSI installation failed with exit code $($MsiExec.ExitCode)."
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
          $LASTEXITCODE = 0
          & $DestFile @parameterSplat *>&1 | ForEach-Object { $line = "$_"; Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue; $line }
        }
        Else {
          Write-Log "Calling '$DestFile'"
          $LASTEXITCODE = 0
          & $DestFile *>&1 | ForEach-Object { $line = "$_"; Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue; $line }
        }
        $ScriptSucceeded = $?
        if (-not $ScriptSucceeded) {
          throw "Script '$DestFile' failed with exit code $LASTEXITCODE."
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
          $LASTEXITCODE = 0
          & $PSScript @parameterSplat *>&1 | ForEach-Object { $line = "$_"; Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue; $line }
        }
        Else {
          Write-Log "Calling '$PSScript'"
          $LASTEXITCODE = 0
          & $PSScript *>&1 | ForEach-Object { $line = "$_"; Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue; $line }
        }
        $ScriptSucceeded = $?
        if (-not $ScriptSucceeded) {
          throw "Script '$PSScript' failed with exit code $LASTEXITCODE."
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