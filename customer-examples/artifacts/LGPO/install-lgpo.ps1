#region Functions

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
#endregion Functions

#region Initialization
$Script:Name = 'Install-LGPO'
$Script:TempDir = Join-Path -Path $env:Temp -ChildPath $Script:Name
$null = New-Item -Path $TempDir -ItemType Directory -Force
New-Log -Path (Join-Path -Path "$env:SystemRoot\Logs" -ChildPath 'Software') -Name 'install-lgpo'
$ErrorActionPreference = 'Stop'
Write-Log -category Info -message "Starting '$PSCommandPath'."
#endregion Initialization

#region main
$LGPOZip = Join-Path -Path $PSScriptRoot -ChildPath 'LGPO.zip'
If (-not(Test-Path -Path $LGPOZip)) {
    $LGPOZip = Get-InternetFile -Url 'https://download.microsoft.com/download/8/5/C/85C25433-A1B0-4FFA-9429-7E023E7DA8D8/LGPO.zip' -OutputDirectory $Script:TempDir -Verbose
}
Write-Log -Category Info -Message "Expanding '$LGPOZip' to '$Script:TempDir'."
Expand-Archive -Path $LGPOZip -DestinationPath $Script:TempDir -Force
$fileLGPO = (Get-ChildItem -Path $Script:TempDir -Filter 'lgpo.exe' -Recurse | Select-Object -First 1).FullName
Write-Log -Message "Copying '$fileLGPO' to '$env:SystemRoot\system32'."
Copy-Item -Path $fileLGPO -Destination "$env:SystemRoot\System32" -Force
Remove-Item -Path $Script:TempDir -Recurse -Force
#endregion Main
Write-Log -category Info -message "Ending '$PSCommandPath'."
