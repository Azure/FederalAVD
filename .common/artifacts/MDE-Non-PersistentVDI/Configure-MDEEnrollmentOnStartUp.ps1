# ============================================================================
# Configure-MDEEnrollmentOnStartUp.ps1
#
# Purpose:
# - Prepare local Group Policy startup scripts so Microsoft Defender for Endpoint
#   (MDE) onboarding runs on the *next* VM startup.
#
# Intended usage:
# - Run this script as an AVD image build customization step (VDI customization)
#   in the current image build pipeline.
# - This script does not perform onboarding immediately; it stages the startup
#   script configuration so onboarding occurs after the image boots next time.
# - Reference:
#   https://learn.microsoft.com/en-us/defender-endpoint/configure-endpoints-vdi
#
# What this script configures:
# 1) Finds the onboarding zip in this artifact root.
# 2) Extracts it to a temporary directory.
# 3) Copies extracted startup script files to:
#    %windir%\System32\GroupPolicy\Machine\Scripts\Startup
# 4) Writes scripts.ini in:
#    %windir%\System32\GroupPolicy\Machine\Scripts
# 5) Updates gpt.ini in:
#    %windir%\System32\GroupPolicy
#    - Ensures machine startup script extension entry exists.
#    - Increments Version by 1 (or creates Version=1 if missing).
# ============================================================================

#region Initialization
$Script:Name          = 'Configure-MDEEnrollmentOnStartUp'
$StartupScriptsPath   = "$env:windir\System32\GroupPolicy\Machine\Scripts\Startup"
$MachineScriptsPath   = "$env:windir\System32\GroupPolicy\Machine\Scripts"
$GroupPolicyPath      = "$env:windir\System32\GroupPolicy"
$ScriptsExtensionGuid = '{40B6664F-4972-11D1-A7CA-0000F87571E3}'
$ScriptsBracketGroup  = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'
#endregion

#region Supporting Functions
Function Write-Log {
    Param (
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet('Info', 'Warning', 'Error')]
        $Category = 'Info',
        [Parameter(Mandatory = $true, Position = 1)]
        $Message
    )
    $Date = Get-Date
    $Content = "[$Date]`t$Category`t`t$Message`n"
    Add-Content $Script:Log $Content -ErrorAction Stop
    Switch ($Category) {
        'Info'    { Write-Host $Content }
        'Error'   { Write-Error $Content }
        'Warning' { Write-Warning $Content }
    }
}

Function New-Log {
    Param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path
    )
    $Date = Get-Date -UFormat '%Y-%m-%d %H-%M-%S'
    Set-Variable logFile -Scope Script
    $Script:logFile = "$Script:Name-$Date.log"
    If (-not (Test-Path $Path)) {
        $null = New-Item -Path $Path -ItemType Directory
    }
    $Script:Log = Join-Path $Path $Script:logFile
    Add-Content $Script:Log "Date`t`t`tCategory`t`tDetails"
}
#endregion

New-Log (Join-Path -Path $env:SystemRoot -ChildPath 'Logs')
$ErrorActionPreference = 'Stop'
Write-Log -Message "Starting '$PSCommandPath'."
Write-Log -Message "This script is intended for image build customization and stages MDE onboarding for the next startup."

# 1. Find the zip file in the script root
$PathZip = (Get-ChildItem -Path $PSScriptRoot -Filter '*.zip').FullName
$TempDir = Join-Path -Path $env:Temp -ChildPath 'MDE-NonPersistentVDI'
$null = New-Item -Path $TempDir -ItemType Directory -Force
If (-not $PathZip) {
    Write-Log -Category Error -Message "No zip file found in '$PSScriptRoot'. Exiting."
    Exit 1
}
Write-Log -Message "Found zip file '$PathZip'."

# 2. Extract zip to temp directory
Write-Log -Message "Extracting contents of zip file to '$TempDir'."
Expand-Archive -Path $PathZip -DestinationPath $TempDir -Force

# 3. Copy extracted files to the Startup scripts folder
Write-Log -Message "Ensuring Startup scripts directory exists: '$StartupScriptsPath'."
$null = New-Item -Path $StartupScriptsPath -ItemType Directory -Force
Write-Log -Message "Copying extracted files to '$StartupScriptsPath'."
Get-ChildItem -Path $TempDir -File | ForEach-Object {
    Write-Log -Message "Copying '$($_.Name)'."
    Copy-Item -Path $_.FullName -Destination $StartupScriptsPath -Force
}

# 4. Create scripts.ini with UTF-16 LE encoding
$ScriptsIniPath = Join-Path -Path $MachineScriptsPath -ChildPath 'scripts.ini'
Write-Log -Message "Writing '$ScriptsIniPath' (UTF-16 LE)."
$ScriptsIniContent = "[Startup]`r`n0CmdLine=Onboard-NonPersistentMachine.ps1`r`n0Parameters= "
[System.IO.File]::WriteAllText($ScriptsIniPath, $ScriptsIniContent, [System.Text.Encoding]::Unicode)

# 5. Update gpt.ini
$GptIniPath = Join-Path -Path $GroupPolicyPath -ChildPath 'gpt.ini'
If (-not (Test-Path $GptIniPath)) {
    Write-Log -Message "'$GptIniPath' not found. Creating with default content."
    $DefaultContent = "[General]`r`ngPCFunctionalityVersion=2`r`ngPCMachineExtensionNames=`r`nVersion=0`r`n"
    [System.IO.File]::WriteAllText($GptIniPath, $DefaultContent, [System.Text.Encoding]::Unicode)
}

Write-Log -Message "Reading '$GptIniPath'."
$GptLines = [System.IO.File]::ReadAllLines($GptIniPath, [System.Text.Encoding]::Unicode)
$NewLines           = [System.Collections.Generic.List[string]]::new()
$ExtensionLineFound = $false
$VersionLineFound   = $false
$GeneralLineFound   = $false

foreach ($Line in $GptLines) {
    If ($Line -eq '[General]') {
        $GeneralLineFound = $true
        $NewLines.Add($Line)
    }
    ElseIf ($Line -match '^gPCMachineExtensionNames=(.*)$') {
        $ExtensionLineFound = $true
        $CurrentValue = $Matches[1]
        If ($CurrentValue -notmatch [regex]::Escape($ScriptsExtensionGuid)) {
            Write-Log -Message "Adding scripts extension GUID to gPCMachineExtensionNames."
            $NewLines.Add("gPCMachineExtensionNames=$CurrentValue$ScriptsBracketGroup")
        }
        Else {
            Write-Log -Message "Scripts extension GUID already present in gPCMachineExtensionNames."
            $NewLines.Add($Line)
        }
    }
    ElseIf ($Line -match '^Version=(\d+)') {
        $VersionLineFound = $true
        $CurrentVersion = [int]$Matches[1]
        $NewVersion     = $CurrentVersion + 1
        Write-Log -Message "Incrementing gpt.ini Version from $CurrentVersion to $NewVersion."
        $NewLines.Add("Version=$NewVersion")
    }
    Else {
        $NewLines.Add($Line)
    }
}

If (-not $GeneralLineFound) {
    Write-Log -Message "[General] section not found. Adding it to the top of gpt.ini."
    $NewLines.Insert(0, '[General]')
}

If (-not $ExtensionLineFound) {
    Write-Log -Message "gPCMachineExtensionNames not found. Inserting after [General]."
    $InsertIndex = $NewLines.IndexOf('[General]')
    If ($InsertIndex -ge 0) {
        $NewLines.Insert($InsertIndex + 1, "gPCMachineExtensionNames=$ScriptsBracketGroup")
    }
    Else {
        $NewLines.Insert(0, "gPCMachineExtensionNames=$ScriptsBracketGroup")
    }
}

If (-not $VersionLineFound) {
    Write-Log -Message "Version line not found. Adding Version=1."
    $NewLines.Add('Version=1')
}

[System.IO.File]::WriteAllText($GptIniPath, ($NewLines -join "`r`n") + "`r`n", [System.Text.Encoding]::Unicode)
Write-Log -Message "gpt.ini updated successfully."

# Cleanup temp directory
Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Log -Message "Script complete."
