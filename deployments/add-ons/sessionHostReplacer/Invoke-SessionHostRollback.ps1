<#
.SYNOPSIS
    Restores SideBySide shutdown-retention session hosts for an operator-controlled rollback.

.DESCRIPTION
    Discovers retained session hosts from the Session Host Replacer Function App settings, requires
    the Function App to be stopped, starts the selected VMs, waits for AVD readiness, enables new
    sessions, removes replacer-owned retention controls, and opts the restored hosts out of
    automation.

    The script does not drain or remove the bad-image generation, change the Compute Gallery image,
    re-enable automation, or restart the Function App. Complete those actions only after validating
    the restored capacity and establishing the intended known-good image.

.PARAMETER FunctionAppName
    Name of the Session Host Replacer Function App.

.PARAMETER FunctionAppResourceGroupName
    Resource group containing the Session Host Replacer Function App.

.PARAMETER FunctionAppSubscriptionId
    Subscription containing the Function App. Defaults to the active Az context subscription.

.PARAMETER SessionHostName
    Optional retained VM names to restore. When omitted, restores every VM carrying the configured
    shutdown-retention tag.

.PARAMETER StopFunctionApp
    Stops a running Function App before restoration. Without this switch, a running Function App
    causes the script to fail closed.

.PARAMETER HealthTimeoutMinutes
    Maximum time to wait for each restored host to become Available and healthy in AVD.

.PARAMETER PollIntervalSeconds
    Interval between Function App and AVD status checks.

.PARAMETER PassThru
    Returns one result object per selected retained host.

.EXAMPLE
    .\Invoke-SessionHostRollback.ps1 `
        -FunctionAppName func-shr-prod-use2 `
        -FunctionAppResourceGroupName rg-avd-operations-use2 `
        -StopFunctionApp `
        -WhatIf

.EXAMPLE
    .\Invoke-SessionHostRollback.ps1 `
        -FunctionAppName func-shr-prod-use2 `
        -FunctionAppResourceGroupName rg-avd-operations-use2 `
        -SessionHostName avd-001, avd-002 `
        -StopFunctionApp `
        -Confirm:$false `
        -PassThru

.NOTES
    Requires Az.Accounts and an authenticated Az context. The operator needs read and action
    permissions on the Function App, VM start and tag permissions, and permission to update AVD
    session hosts.
#>

#Requires -Modules Az.Accounts

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FunctionAppName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$FunctionAppResourceGroupName,

    [string]$FunctionAppSubscriptionId,

    [string[]]$SessionHostName,

    [switch]$StopFunctionApp,

    [ValidateRange(1, 120)]
    [int]$HealthTimeoutMinutes = 20,

    [ValidateRange(5, 300)]
    [int]$PollIntervalSeconds = 15,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$webApiVersion = '2024-11-01'
$computeApiVersion = '2024-07-01'
$desktopVirtualizationApiVersion = '2024-04-03'
$tagsApiVersion = '2021-04-01'

function Invoke-ArmRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [object]$Body
    )

    $request = @{
        Method = $Method
        Path = $Path
    }
    if ($null -ne $Body) {
        $request.Payload = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    $response = Invoke-AzRestMethod @request
    if ($response.StatusCode -ge 400) {
        throw "$Method $Path failed with HTTP $($response.StatusCode): $($response.Content)"
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json
}

function Get-SettingValue {
    param(
        [Parameter(Mandatory)]
        [object]$Settings,

        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Default
    )

    $property = $Settings.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        if ($PSBoundParameters.ContainsKey('Default')) {
            return $Default
        }
        throw "Required Function App setting '$Name' is missing or empty."
    }

    return [string]$property.Value
}

function Get-TagValue {
    param(
        [object]$Tags,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Tags) {
        return $null
    }

    if ($Tags -is [System.Collections.IDictionary]) {
        return $Tags[$Name]
    }

    $property = $Tags.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return [string]$property.Value
}

function Get-FunctionApp {
    Invoke-ArmRequest `
        -Method GET `
        -Path "${functionAppResourceId}?api-version=$webApiVersion"
}

function Wait-FunctionAppStopped {
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    do {
        $functionApp = Get-FunctionApp
        if ($functionApp.properties.state -eq 'Stopped') {
            return
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            break
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($true)

    throw "Function App '$FunctionAppName' did not reach the Stopped state within 5 minutes."
}

function Wait-SessionHostReady {
    param(
        [Parameter(Mandatory)]
        [string]$SessionHostPath,

        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    $deadline = [DateTime]::UtcNow.AddMinutes($HealthTimeoutMinutes)
    do {
        $sessionHost = Invoke-ArmRequest `
            -Method GET `
            -Path "${SessionHostPath}?api-version=$desktopVirtualizationApiVersion"
        $failedHealthChecks = @($sessionHost.properties.healthCheckResults | Where-Object {
            $_.healthCheckResult -eq 'HealthCheckFailed'
        })

        if ($sessionHost.properties.status -eq 'Available' -and $failedHealthChecks.Count -eq 0) {
            return $sessionHost
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            break
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    } while ($true)

    throw "Session host '$ComputerName' did not become Available and healthy within $HealthTimeoutMinutes minute(s). Retention tags and drain mode were preserved."
}

$context = Get-AzContext
if (-not $context) {
    throw 'No Azure context found. Connect with Connect-AzAccount before running this script.'
}

if ([string]::IsNullOrWhiteSpace($FunctionAppSubscriptionId)) {
    $FunctionAppSubscriptionId = $context.Subscription.Id
}

$functionAppResourceId = "/subscriptions/$FunctionAppSubscriptionId/resourceGroups/$FunctionAppResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
$functionApp = Get-FunctionApp
if ($functionApp.properties.state -ne 'Stopped') {
    if (-not $StopFunctionApp) {
        throw "Function App '$FunctionAppName' is $($functionApp.properties.state). Stop it first or rerun with -StopFunctionApp."
    }

    if ($PSCmdlet.ShouldProcess($FunctionAppName, 'Stop Session Host Replacer Function App')) {
        Invoke-ArmRequest `
            -Method POST `
            -Path "$functionAppResourceId/stop?api-version=$webApiVersion" | Out-Null
        Wait-FunctionAppStopped
    }
    elseif (-not $WhatIfPreference) {
        throw "Function App '$FunctionAppName' must be stopped before rollback restoration."
    }
}

$settingsResponse = Invoke-ArmRequest `
    -Method POST `
    -Path "$functionAppResourceId/config/appsettings/list?api-version=$webApiVersion"
$settings = $settingsResponse.properties

$replacementMode = Get-SettingValue -Settings $settings -Name 'ReplacementMode'
$retentionEnabled = [bool]::Parse(
    (Get-SettingValue -Settings $settings -Name 'EnableShutdownRetention' -Default 'false')
)
if ($replacementMode -ne 'SideBySide' -or -not $retentionEnabled) {
    throw 'Rollback restoration requires SideBySide mode with shutdown retention enabled.'
}

$vmSubscriptionId = Get-SettingValue -Settings $settings -Name 'VirtualMachinesSubscriptionId'
$vmResourceGroupName = Get-SettingValue -Settings $settings -Name 'VirtualMachinesResourceGroupName'
$hostPoolSubscriptionId = Get-SettingValue -Settings $settings -Name 'HostPoolSubscriptionId'
$hostPoolResourceGroupName = Get-SettingValue -Settings $settings -Name 'HostPoolResourceGroupName'
$hostPoolName = Get-SettingValue -Settings $settings -Name 'HostPoolName'
$shutdownTagName = Get-SettingValue -Settings $settings -Name 'Tag_ShutdownTimestamp'
$scalingExclusionTagName = Get-SettingValue `
    -Settings $settings `
    -Name 'Tag_ScalingPlanExclusionTag' `
    -Default ''
$includeInAutomationTagName = Get-SettingValue -Settings $settings -Name 'Tag_IncludeInAutomation'

$vmCollectionPath = "/subscriptions/$vmSubscriptionId/resourceGroups/$vmResourceGroupName/providers/Microsoft.Compute/virtualMachines"
$virtualMachines = @(
    (Invoke-ArmRequest -Method GET -Path "${vmCollectionPath}?api-version=$computeApiVersion").value
)
$retainedVMs = @($virtualMachines | Where-Object {
    -not [string]::IsNullOrWhiteSpace(
        [string](Get-TagValue -Tags $_.tags -Name $shutdownTagName)
    )
})

if ($SessionHostName) {
    $requestedNames = @($SessionHostName | ForEach-Object { $_.ToLowerInvariant() })
    $retainedVMs = @($retainedVMs | Where-Object {
        $_.name.ToLowerInvariant() -in $requestedNames
    })

    $foundNames = @($retainedVMs.name | ForEach-Object { $_.ToLowerInvariant() })
    $missingNames = @($requestedNames | Where-Object { $_ -notin $foundNames })
    if ($missingNames.Count -gt 0) {
        throw "Requested host(s) are not retained VMs: $($missingNames -join ', ')."
    }
}

if ($retainedVMs.Count -eq 0) {
    throw "No VMs with shutdown-retention tag '$shutdownTagName' were found."
}

$sessionHostCollectionPath = "/subscriptions/$hostPoolSubscriptionId/resourceGroups/$hostPoolResourceGroupName/providers/Microsoft.DesktopVirtualization/hostPools/$hostPoolName/sessionHosts"
$sessionHosts = @(
    (Invoke-ArmRequest `
        -Method GET `
        -Path "${sessionHostCollectionPath}?api-version=$desktopVirtualizationApiVersion").value
)

$sessionHostsByVMId = @{}
foreach ($sessionHost in $sessionHosts) {
    $vmResourceId = [string]$sessionHost.properties.resourceId
    if (-not [string]::IsNullOrWhiteSpace($vmResourceId)) {
        $sessionHostsByVMId[$vmResourceId.ToLowerInvariant()] = $sessionHost
    }
}

$results = @()
foreach ($vm in $retainedVMs) {
    $vmResourceId = [string]$vm.id
    $sessionHost = $sessionHostsByVMId[$vmResourceId.ToLowerInvariant()]
    if ($null -eq $sessionHost) {
        throw "Retained VM '$($vm.name)' is not registered in host pool '$hostPoolName'."
    }

    $sessionHostPath = [string]$sessionHost.id
    $computerName = [string]$vm.name
    if (-not $PSCmdlet.ShouldProcess(
        $computerName,
        'Start retained VM, validate AVD health, enable sessions, remove retention controls, and opt out of automation'
    )) {
        $results += [PSCustomObject]@{
            SessionHostName = $computerName
            Status = 'Planned'
            AutomationEnabled = $false
        }
        continue
    }

    Invoke-ArmRequest `
        -Method POST `
        -Path "$vmResourceId/start?api-version=$computeApiVersion" | Out-Null

    Wait-SessionHostReady -SessionHostPath $sessionHostPath -ComputerName $computerName | Out-Null

    $tagsPath = "$vmResourceId/providers/Microsoft.Resources/tags/default?api-version=$tagsApiVersion"
    Invoke-ArmRequest `
        -Method PATCH `
        -Path $tagsPath `
        -Body @{
            operation = 'Merge'
            properties = @{
                tags = @{
                    $includeInAutomationTagName = 'false'
                }
            }
        } | Out-Null

    Invoke-ArmRequest `
        -Method PATCH `
        -Path "${sessionHostPath}?api-version=$desktopVirtualizationApiVersion" `
        -Body @{
            properties = @{
                allowNewSession = $true
            }
        } | Out-Null

    $tagsToRemove = @{
        $shutdownTagName = ''
    }
    if (-not [string]::IsNullOrWhiteSpace($scalingExclusionTagName)) {
        $scalingExclusionValue = [string](
            Get-TagValue -Tags $vm.tags -Name $scalingExclusionTagName
        )
        if ($scalingExclusionValue -eq 'SessionHostReplacer') {
            $tagsToRemove[$scalingExclusionTagName] = ''
        }
    }

    Invoke-ArmRequest `
        -Method PATCH `
        -Path $tagsPath `
        -Body @{
            operation = 'Delete'
            properties = @{
                tags = $tagsToRemove
            }
        } | Out-Null

    $results += [PSCustomObject]@{
        SessionHostName = $computerName
        Status = 'Restored'
        AutomationEnabled = $false
    }
}

$restoredCount = @($results | Where-Object { $_.Status -eq 'Restored' }).Count
if ($restoredCount -gt 0) {
    Write-Warning "$restoredCount rollback host(s) were opted out of automation. Keep the Function App stopped until the known-good image and bad-image host disposition are established."
}
elseif ($WhatIfPreference) {
    Write-Verbose 'Rollback preview completed; no hosts were changed.'
}

if ($PassThru) {
    $results
}
