<#
.SYNOPSIS
    Stages Microsoft Defender for Endpoint non-persistent VDI onboarding for first startup.

.DESCRIPTION
    Finds the tenant-specific VDI onboarding ZIP beside this script, extracts it under ProgramData,
    and registers a one-time startup task for its PowerShell entry point. Use this artifact only as
    an image build vdiCustomizations entry. The image build does not restart after this phase, so
    the onboarding script is not executed while the image is being built.

.PARAMETER StartupDelayMinutes
    Number of minutes after startup before the onboarding task runs.

.PARAMETER RegistrationTimeoutMinutes
    Number of minutes the startup task waits for local Defender registration confirmation.

.PARAMETER RetryIntervalMinutes
    Number of minutes between scheduled task retries until registration is confirmed.

.EXAMPLE
    .\Install-MDEVDIOnboarding.ps1 -StartupDelayMinutes 2
#>
[CmdletBinding()]
param (
    [ValidateRange(0, 30)]
    [int]$StartupDelayMinutes = 2,

    [ValidateRange(1, 30)]
    [int]$RegistrationTimeoutMinutes = 10,

    [ValidateRange(15, 1440)]
    [int]$RetryIntervalMinutes = 60
)

$ErrorActionPreference = 'Stop'
$TaskName = 'MDE-VDI-Onboarding'
$StageRoot = Join-Path $env:ProgramData 'MDEVDIOnboarding'
$RunnerName = 'Invoke-MDEVDIOnboarding.ps1'
$LogPath = Join-Path $env:SystemRoot 'Logs\MDEVDIOnboarding.log'

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $entry
    Add-Content -LiteralPath $LogPath -Value $entry -ErrorAction SilentlyContinue
}

function Get-SingleFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Filter,

        [switch]$Recurse
    )

    $files = @(Get-ChildItem -LiteralPath $Root -Filter $Filter -File -Recurse:$Recurse)
    if ($files.Count -ne 1) {
        throw "Expected exactly one '$Filter' file under '$Root'; found $($files.Count)."
    }

    return $files[0]
}

function Set-ProtectedDirectoryAcl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)

    foreach ($sidValue in 'S-1-5-18', 'S-1-5-32-544') {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            $fullControl,
            $inheritance,
            $propagation,
            $allow
        )
        $security.AddAccessRule($rule)
    }

    Set-Acl -LiteralPath $Path -AclObject $security
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Microsoft Defender for Endpoint VDI onboarding requires a supported 64-bit Windows operating system.'
}

$packageFile = Get-SingleFile -Root $PSScriptRoot -Filter '*.zip'

Write-Log "Staging tenant onboarding package '$($packageFile.FullName)'."

try {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Log "Removing existing scheduled task '$TaskName'."
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    if (Test-Path -LiteralPath $StageRoot) {
        Remove-Item -LiteralPath $StageRoot -Recurse -Force
    }

    $null = New-Item -Path $StageRoot -ItemType Directory -Force
    Expand-Archive -LiteralPath $packageFile.FullName -DestinationPath $StageRoot -Force
    $onboardingScript = Get-SingleFile -Root $StageRoot -Filter '*.ps1' -Recurse

    $runnerContent = @'
[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$TaskName = 'MDE-VDI-Onboarding'
$StageRoot = $PSScriptRoot
$OnboardingScript = '__ONBOARDING_SCRIPT_PATH__'
$LogPath = Join-Path $env:SystemRoot 'Logs\MDEVDIOnboarding.log'
$ExitCode = 0
$RegistrationTimeoutMinutes = __REGISTRATION_TIMEOUT_MINUTES__

function Write-TaskLog {
    param ([string]$Message)

    Add-Content -LiteralPath $LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ErrorAction SilentlyContinue
}

function Get-RegistryValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop
    }
    catch {
        $null
    }
}

function Test-MdeRegistration {
    $state = Get-RegistryValue `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' `
        -Name OnboardingState
    $service = Get-Service -Name Sense -ErrorAction SilentlyContinue

    return $state -eq 1 -and $null -ne $service -and $service.Status -eq 'Running'
}

function Test-MdeRegistrationPending {
    $state = Get-RegistryValue `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' `
        -Name OnboardingState
    $senseGuid = Get-RegistryValue `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection' `
        -Name senseGuid
    $service = Get-Service -Name Sense -ErrorAction SilentlyContinue

    return (
        $state -ne 1 -and
        -not [string]::IsNullOrWhiteSpace([string]$senseGuid) -and
        $null -ne $service -and
        $service.Status -eq 'Running'
    )
}

function Write-MdeRegistrationState {
    $state = Get-RegistryValue `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' `
        -Name OnboardingState
    $senseGuid = Get-RegistryValue `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection' `
        -Name senseGuid
    $service = Get-Service -Name Sense -ErrorAction SilentlyContinue
    $serviceStatus = if ($null -eq $service) { 'NotFound' } else { [string]$service.Status }
    $senseGuidPresent = -not [string]::IsNullOrWhiteSpace([string]$senseGuid)

    Write-TaskLog "Local MDE state: OnboardingState='$state'; Sense='$serviceStatus'; senseGuidPresent='$senseGuidPresent'."
}

try {
    Write-MdeRegistrationState
    if (Test-MdeRegistration) {
        Write-TaskLog 'Local Defender registration was already confirmed. Skipping the onboarding script.'
    }
    else {
        if (Test-MdeRegistrationPending) {
            Write-TaskLog 'Defender registration appears to be pending. Waiting without rerunning the Microsoft onboarding script.'
        }
        else {
            Write-TaskLog 'Starting Microsoft Defender for Endpoint non-persistent VDI onboarding.'
            & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -NoLogo `
                -NoProfile `
                -NonInteractive `
                -ExecutionPolicy Bypass `
                -File $OnboardingScript 2>&1 |
                ForEach-Object {
                    $outputLine = [string]$_
                    if (-not [string]::IsNullOrWhiteSpace($outputLine)) {
                        Write-TaskLog "Microsoft: $outputLine"
                    }
                }
            $ExitCode = $LASTEXITCODE
            Write-TaskLog "Microsoft onboarding script exited with code $ExitCode."
            if ($ExitCode -ne 0) {
                throw "The Microsoft onboarding script exited with code $ExitCode."
            }
        }

        Write-TaskLog "Waiting up to $RegistrationTimeoutMinutes minutes for local Defender registration confirmation."
        $deadline = (Get-Date).AddMinutes($RegistrationTimeoutMinutes)
        while (-not (Test-MdeRegistration) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 15
        }

        if (-not (Test-MdeRegistration)) {
            throw 'Local Defender registration was not confirmed. The task and staged files will be retained for the next startup.'
        }
    }

    Write-MdeRegistrationState
    Write-TaskLog 'Local Defender registration is confirmed: OnboardingState is 1 and the Sense service is running.'

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Write-TaskLog "Deleted scheduled task '$TaskName'."

    Remove-Item -LiteralPath $StageRoot -Recurse -Force -ErrorAction Stop
    Write-TaskLog "Removed staged onboarding files from '$StageRoot'."
}
catch {
    $ExitCode = 1
    Write-MdeRegistrationState
    Write-TaskLog "Microsoft Defender for Endpoint onboarding failed: $($_.Exception.Message)"
}

exit $ExitCode
'@
    $runnerContent = $runnerContent.Replace('__REGISTRATION_TIMEOUT_MINUTES__', [string]$RegistrationTimeoutMinutes)
    $runnerContent = $runnerContent.Replace('__ONBOARDING_SCRIPT_PATH__', $onboardingScript.FullName.Replace("'", "''"))

    $runnerPath = Join-Path $StageRoot $RunnerName
    Set-Content -LiteralPath $runnerPath -Value $runnerContent -Encoding ASCII
    Set-ProtectedDirectoryAcl -Path $StageRoot

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $actionArguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runnerPath`""
    $action = New-ScheduledTaskAction -Execute $powerShellPath -Argument $actionArguments
    $trigger = New-ScheduledTaskTrigger -AtStartup
    if ($StartupDelayMinutes -gt 0) {
        $trigger.Delay = "PT$($StartupDelayMinutes)M"
    }
    $repetition = New-CimInstance `
        -Namespace 'Root/Microsoft/Windows/TaskScheduler' `
        -ClassName MSFT_TaskRepetitionPattern `
        -ClientOnly `
        -Property @{
            Interval = "PT$($RetryIntervalMinutes)M"
            Duration = 'P9999D'
            StopAtDurationEnd = $false
        }
    $trigger.Repetition = $repetition

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $executionLimitMinutes = $RegistrationTimeoutMinutes + 10
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $executionLimitMinutes) `
        -MultipleInstances IgnoreNew `
        -StartWhenAvailable

    $null = Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description 'Microsoft Defender for Endpoint non-persistent VDI onboarding with retries until registered.'

    $registeredTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if ($registeredTask.State -eq 'Disabled') {
        throw "Scheduled task '$TaskName' was registered in a disabled state."
    }

    Write-Log "Staged Defender VDI onboarding files in '$StageRoot'."
    Write-Log "Recorded onboarding script path '$($onboardingScript.FullName)'."
    Write-Log "Registered startup task '$TaskName' with a $StartupDelayMinutes minute delay."
    Write-Log "The task will wait up to $RegistrationTimeoutMinutes minutes for local registration confirmation."
    Write-Log "The task will retry every $RetryIntervalMinutes minutes until registration is confirmed."
    Write-Log 'The image has not been onboarded. The task will first run after a deployed session host starts.'
}
catch {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StageRoot -Recurse -Force -ErrorAction SilentlyContinue
    throw
}
