param (
    [int[]]$SuccessExitCodes = @(0, 3010)
)

#region Initialization
$DownloadUrl = "https://aka.ms/fslogix_download"
$SoftwareName = 'Microsoft FSLogix Apps'
$Script:Name = 'Install-FSLogix'
#endregion

#region Supporting Functions
function Invoke-ApplicationProcess {
    param (
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Action,
        [int[]]$SuccessExitCodes = @(0, 3010),
        [int]$TimeoutMs = 600000
    )
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -ErrorAction Stop
    # Windows PowerShell needs a retained handle to read ExitCode after WaitForExit.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill(); throw "$Action timed out." }
    if ($null -eq $process.ExitCode) { throw "$Action did not report an exit code." }
    if ($SuccessExitCodes.Count -gt 0 -and $process.ExitCode -notin $SuccessExitCodes) {
        throw "$Action failed with exit code $($process.ExitCode)."
    }
    return $process
}

function Write-Log {
    param (
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')][string]$Category = 'Info'
    )
    $content = "[$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')]`t$Category`t`t$Message"
    if ($env:SUPPRESS_FILELOG -ne '1') {
        Add-Content -LiteralPath $script:Log -Value $content -ErrorAction Stop
    }
    switch ($Category) {
        'Info' { Write-Host $content }
        'Warning' { Write-Warning $content }
        'Error' { Write-Error $content -ErrorAction Continue }
    }
}

function New-Log {
    param (
        [Parameter(Position = 0)][string]$Path,
        [string]$Name = 'Artifact',
        [string]$FilePath
    )
    if ($env:SUPPRESS_FILELOG -eq '1') { return }
    if ($FilePath) {
        $script:Log = $FilePath
        $Path = Split-Path $FilePath -Parent
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Path)) { throw 'A log directory or FilePath is required.' }
        $script:Log = Join-Path $Path "$Name-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
    }
    New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    Add-Content -LiteralPath $script:Log -Value "Date`t`t`tCategory`t`tDetails" -ErrorAction Stop
}

function Get-InternetFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][uri]$Url,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [string]$OutputFileName
    )
    if (-not $OutputFileName) { $OutputFileName = [IO.Path]::GetFileName($Url.AbsolutePath) }
    if ([string]::IsNullOrWhiteSpace($OutputFileName)) { throw 'An output filename is required for this URL.' }
    New-Item -Path $OutputDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $outputFile = Join-Path $OutputDirectory $OutputFileName
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.WebClient
    try { $client.DownloadFile($Url, $outputFile) }
    finally { $client.Dispose() }
    if (-not (Test-Path -LiteralPath $outputFile -PathType Leaf)) { throw "Download did not create '$outputFile'." }
    return $outputFile
}
#endregion

New-Log (Join-Path -Path $Env:SystemRoot -ChildPath 'Logs') -Name 'Install-FSLogix'
$ErrorActionPreference = 'Stop'
Write-Log -message "Starting '$PSCommandPath'."
$PathZip = (Get-ChildItem -Path $PSScriptRoot -Filter '*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
$TempDir = Join-Path -Path $env:Temp -ChildPath 'FSLogix'
$null = New-Item -Path $TempDir -ItemType Directory -Force
If (!$PathZip) {
    Write-Log -Message "Zip not found, must download from the internet."
    $PathZip = Get-InternetFile -Url $DownloadUrl -OutputDirectory $TempDir -OutputFileName 'FSLogix.zip'
}
Else {
    Write-Log -message "Found file '$PathZip'"
}
Write-Log -Message "Extracting Contents of Zip File"
Expand-Archive -Path $pathZip -DestinationPath $TempDir -Force
$Installer = (Get-ChildItem -Path $TempDir -File -Recurse -Filter 'FSLogixAppsSetup.exe' | Where-Object { $_.FullName -like '*x64*' } | Select-Object -First 1).FullName
Write-Log -Message "Installation file found: [$Installer], executing installation."
$Install = Invoke-ApplicationProcess -FilePath $Installer -ArgumentList '/install /quiet /norestart' `
    -Action "'$SoftwareName' installer" -TimeoutMs -1 -SuccessExitCodes @()
If ($Install.ExitCode -in $SuccessExitCodes) {
    if ($Install.ExitCode -eq 3010) { Write-Log -Message "'Microsoft FSLogix Apps' installed successfully. A reboot is required." }
    else { Write-Log -Message "'Microsoft FSLogix Apps' installed successfully." }
}
Else {
    Write-Log -Category Error -Message "'$SoftwareName' installer failed with exit code $($Install.ExitCode)."
    exit $Install.ExitCode
}
Write-Log -Message "Copying the FSLogix ADMX and ADML files to the PolicyDefinitions folders."
Get-ChildItem -Path $TempDir -File -Recurse -Filter '*.admx' | ForEach-Object { Write-Log -Message "Copying $($_.Name)"; Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\" -Force }
Get-ChildItem -Path $TempDir -File -Recurse -Filter '*.adml' | ForEach-Object { Write-Log -Message "Copying $($_.Name)"; Copy-Item -Path $_.FullName -Destination "$env:WINDIR\PolicyDefinitions\en-us\" -Force }
Write-Log -Message "Installation complete."
Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
