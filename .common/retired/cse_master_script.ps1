<#      
    .DESCRIPTION
    Main script performing the Windows VM extension deployment. Executed steps:
    - find all ZIP files in the downloaded folder (including subfolder).
    - extract all ZIP files to _deploy folder by also creating the folder.
    - each ZIP is extracted to a subfolder _deploy\<XXX>-<ZIP file name without extension> where XXX is a number starting at 000.
    - find all *.ps1 files in _deploy subfolders.
    - execute all PowerShell scripts found in _deploy subfolders in the order of folder names and passing the DynParameters parameter from this script.

    .PARAMETER DynParameters
    Hashtable parameter enabling to pass Key-Value parameter pairs. Example: @{"Environment"="Prod";"Debug"="True"}  
    
    .PARAMETER startIndex
    The index of the item to start with installing. Useful when running a restart in between the installation of multiple packages. 
    If you specified 4 packages in your list of customizations and have a restart prior to the last one, provide the 'startIndex' 4 when re-invoking the installer script.
    BEWARE: To keep the flexibility of re-using packages, the start index refers not to the folder number in the 'Uploads' folder, but to slot in the list of customization steps you specified.
#>

[CmdletBinding(DefaultParametersetName = 'None')]
param(
    [Parameter(Mandatory = $false)]
    [hashtable] $DynParameters = @{},

    [Parameter(Mandatory = $false)]
    [string] $downloadsPath = ""
)

#region Functions

function Write-Log {

    <#
    .SYNOPSIS
    Creates a log file and stores logs based on categories with tab seperation

    .PARAMETER category
    Category to put into the trace

    .PARAMETER message
    Message to be loged

    .EXAMPLE
    Log 'Info' 'Message'

    #>

    Param (
        [Parameter(Mandatory=$false, Position=0)]
        [ValidateSet("Info","Warning","Error")]
        $category = 'Info',
        [Parameter(Mandatory=$true, Position=1)]
        $message
    )

    $date = get-date
    $content = "[$date]`t$category`t`t$message`n" 
    Add-Content $Script:Log $content -ErrorAction Stop
}

function New-Log {
    <#
    .SYNOPSIS
    Sets default log file and stores in a script accessible variable $script:Log
    Log File name "packageExecution_$date.log"

    .PARAMETER Path
    Path to the log file

    .EXAMPLE
    New-Log c:\Windows\Logs
    Create a new log file in c:\Windows\Logs
    #>

    Param (
        [Parameter(Mandatory = $true, Position=0)]
        [string] $Path
    )

    # Create central log file with given date

    $date = Get-Date -UFormat "%Y-%m-%d %H-%M-%S"
    Set-Variable logFile -Scope Script
    $script:logFile = "$Script:Name-$date.log"

    if ((Test-Path $path ) -eq $false) {
        $null = New-Item -Path $path -type directory
    }

    $script:Log = Join-Path $path $logfile

    Add-Content $script:Log "Date`t`t`tCategory`t`tDetails"
}

#endregion Functions

#region Initialization
$ErrorActionPreference = 'Stop'
$Script:Name = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
New-Log "$env:SystemRoot\Logs"
Write-Log -category Info -message "Starting '$PSCommandPath'."
Write-Log -category Info -message "Current working dir: $((Get-Location).Path)"
$DirTemp = Join-Path -Path $env:Temp -ChildPath 'CSE'
If (Test-Path -Path $DirTemp) {Remove-Item -Path $DirTemp -Recurse -Force -ErrorAction SilentlyContinue}
New-Item -Path $DirTemp -ItemType Directory -Force | Out-Null

$Files = Get-ChildItem -Path $PSScriptRoot -File | Sort-Object 'LastWriteTime'
$PSScriptsToExecute = @()

ForEach($File in $Files) {
    # Don't capture this script again.
    If ($File.Extension -eq '.ps1' -and $File.FullName -ne "$PSCommandPath") {
        Write-Log -category Info -message "Adding $($File.FullName) to list of scripts to execute with PowerShell."
        $PSScriptsToExecute += $File.FullName
    } ElseIf ($File.Extension -eq '.zip') {
        Unblock-File -Path $File.FullName
        $destinationPath = Join-Path $DirTemp -ChildPath $File.BaseName
        Write-Log -category Info -message "Unpacking $($File.FullName)"
        Expand-Archive -Path $File.FullName -DestinationPath $destinationPath -Force | Out-Null
        Write-Log -category Info -message "Searching for PowerShell Scripts in the root of '$destinationPath'."
        $PSScriptsInRootofZip = (Get-ChildItem -path $destinationPath -filter '*.ps1').FullName
        If ($PSScriptsInRootofZip) {
            ForEach ($Script in $PSScriptsInRootofZip) {
                Write-Log -category Info -message "Adding $($Script) to list of scripts to execute with PowerShell."
                $PSScriptsToExecute += $Script
            }
        } Else {
            Write-Log -category Error "No PowerShell scripts found in the root of '$destinationPath'."
            Throw "No PowerShell scripts found in the root of '$destinationPath'."
        }
    }
}

if ($PsScriptsToExecute) {
    Write-Log -category Info -message "Found $($PsScriptsToExecute.count) scripts"
} else {
    Write-Log -category Error -message "No scripts found to execute"
}

foreach ($scr in $PsScriptsToExecute) {
    Write-Log -category Info -message "Executing $($scr)"
    If (Select-String -Path $Scr -Pattern '\$DynParameters') {
        & $scr -DynParameters $DynParameters | Out-Null
    } Else {
        & $scr | Out-Null
    }
}
Remove-Item -Path $DirTemp -Recurse -Force -ErrorAction SilentlyContinue | Out-Null

Write-Log -category Info -message "Ending '$PSCommandPath'."

$Output = [pscustomobject][ordered]@{
    scripts = $PsScriptsToExecute
}
$JsonOutput = $Output | ConvertTo-Json
return $JsonOutput