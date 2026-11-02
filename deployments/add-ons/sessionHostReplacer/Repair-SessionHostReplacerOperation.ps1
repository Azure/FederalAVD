<#
.SYNOPSIS
    Previews or recovers a stopped SHR durable operation.
.DESCRIPTION
    Preview is the default. Apply stops the Function App, rechecks safety, backs up
    both state records in a restricted directory, conditionally updates the operation,
    and starts the app. It never deletes state, drains hosts, or submits VM deployments.
    The reconciliation timer resumes the recovered operation.

    Normal recovery requires the initiating configuration. RepairTemplateReference
    permits ONLY a template-reference correction for a first SideBySide deployment
    rejected before ARM created a deployment or any target VM/AVD registration.
    The saved request is preserved except for its pinned Template Spec version.
.PARAMETER RepairTemplateReference
    Approves rebasing the configuration fingerprint and saved template link onto the
    corrected SessionHostTemplate app setting. All other hashed settings must match.
.PARAMETER ExtendDeadlineHours
    Explicitly approves a new deadline this many hours from the recovery check.
.PARAMETER BackupDirectory
    Parent of a new restricted-access backup folder. Defaults to customer\shr-recovery.
    Backups contain secrets from the deployment request; do not share or commit them.
.PARAMETER Apply
    Performs recovery after confirmation. Without this switch, all Azure access is read-only.
.EXAMPLE
    .\Repair-SessionHostReplacerOperation.ps1 -FunctionAppName func-shr `
        -ResourceGroupName rg-operations -RepairTemplateReference
.EXAMPLE
    .\Repair-SessionHostReplacerOperation.ps1 -FunctionAppName func-shr `
        -ResourceGroupName rg-operations -RepairTemplateReference -Apply
.NOTES
    Requires PowerShell 7.4+, Az.Accounts sign-in, Function App read/config-list/stop/start,
    ARM deployment/VM/AVD/Template Spec read permissions, Storage Table Data Contributor,
    and private-network access to the configured Table endpoint.
    On failure, verify the app is stopped. Recovery does not automatically restart the
    app after an error or roll back a successful state update.
#>
#Requires -Version 7.4
#Requires -Modules Az.Accounts

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $FunctionAppName,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $ResourceGroupName,
    [string] $SubscriptionId,
    [switch] $RepairTemplateReference,
    [ValidateRange(1, 720)][int] $ExtendDeadlineHours,
    [string] $BackupDirectory = (Join-Path $PSScriptRoot '..\..\..\customer\shr-recovery'),
    [switch] $Apply,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$context = Get-AzContext
if (-not $context) { throw 'Sign in using Connect-AzAccount before running recovery.' }
if (-not $SubscriptionId) { $SubscriptionId = $context.Subscription.Id }
if ($SubscriptionId -ne $context.Subscription.Id) {
    throw 'The requested subscription must match the active Az context. Sign in to that subscription first.'
}
$environment = Get-AzEnvironment -Name $context.Environment.Name
$armRoot = $environment.ResourceManagerUrl.TrimEnd('/')
$appId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
$webApi = '2024-11-01'
Import-Module (Join-Path $PSScriptRoot 'functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1') -Scope Local
$coordinator = Get-Module SessionHostReplacer.Continuation -All | Where-Object {
    $_.Path -eq (Join-Path $PSScriptRoot 'functions\Modules\SessionHostReplacer\SessionHostReplacer.Continuation.psm1')
} | Select-Object -First 1
if (-not $coordinator) { throw 'Cannot load the repository SHR continuation module.' }

function Invoke-RecoveryArm {
    param([string] $Path, [string] $Method = 'GET', [switch] $AllowMissing)

    $response = Invoke-AzRestMethod -Path $Path -Method $Method -DefaultProfile $context
    if ($AllowMissing -and [int]$response.StatusCode -eq 404) { return $null }
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw "ARM $Method '$Path' failed with HTTP $($response.StatusCode)."
    }
    if ($response.Content) {
        $content = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($Method -eq 'GET' -and $content -isnot [System.Collections.IDictionary]) {
            throw "ARM GET '$Path' returned an invalid resource response."
        }
        return $content
    }
    if ($Method -eq 'GET') { throw "ARM GET '$Path' returned an empty response; resource absence cannot be established." }
}

function Get-RecoveryCollection {
    param([string] $Path)

    do {
        $page = Invoke-RecoveryArm -Path $Path
        if (-not $page.Contains('value') -or $page.value -isnot [array]) {
            throw "ARM collection '$Path' has an invalid response."
        }
        $page.value
        $Path = $page.nextLink
        if ($Path) {
            if (-not $Path.StartsWith("$armRoot/", [StringComparison]::OrdinalIgnoreCase)) {
                throw 'ARM pagination returned an unexpected endpoint.'
            }
            $Path = $Path.Substring($armRoot.Length)
        }
    } while ($Path)
}

function Get-RecoverySettings {
    $settings = (Invoke-RecoveryArm -Path "$appId/config/appsettings/list?api-version=$webApi" -Method POST).properties
    foreach ($name in @('HostPoolSubscriptionId', 'HostPoolResourceGroupName', 'HostPoolName',
        'VirtualMachinesSubscriptionId', 'VirtualMachinesResourceGroupName', 'SessionHostTemplate',
        'AzureWebJobsStorage__tableServiceUri')) {
        if ([string]::IsNullOrWhiteSpace($settings[$name])) { throw "Required app setting '$name' is missing." }
    }
    return $settings
}

function Get-RecoveryHash {
    param([System.Collections.IDictionary] $Settings)
    & $coordinator { param($Values) Get-ShrConfigurationHash -Settings $Values } $Settings
}

function Invoke-RecoveryTable {
    param([string] $Path, [string] $Method = 'GET', [string] $Body, [string] $ETag, [switch] $AllowMissing)

    $token = (Get-AzAccessToken -ResourceUrl $tableEndpoint -DefaultProfile $context).Token
    if ($token -is [securestring]) { $token = [System.Net.NetworkCredential]::new('', $token).Password }
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'No Storage access token was returned.' }
    $headers = @{
        Authorization = "Bearer $token"
        Accept = 'application/json;odata=nometadata'
        'x-ms-version' = '2019-02-02'
        'x-ms-date' = [DateTime]::UtcNow.ToString('R')
    }
    if ($ETag) { $headers['If-Match'] = $ETag }
    $request = @{
        Uri = "$tableEndpoint/$Path"; Method = $Method; Headers = $headers
        ContentType = 'application/json'; SkipHttpErrorCheck = $true
        TimeoutSec = 60; MaximumRedirection = 0
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $request.Body = $Body }
    $response = Invoke-WebRequest @request
    if ($AllowMissing -and [int]$response.StatusCode -eq 404) { return $null }
    if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
        throw "Table $Method '$Path' failed with HTTP $($response.StatusCode). Check Table RBAC, private DNS/network access, and concurrent updates."
    }
    return $response
}

function Get-RecoveryOperation {
    $response = Invoke-RecoveryTable -Path $operationPath
    $entity = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $etag = [string](@($response.Headers['ETag'])[0])
    if (-not $etag -or $etag -eq '*') { throw 'Operation has no usable ETag; refusing an unconditional update.' }
    return @{ Entity = $entity; ETag = $etag; State = ($entity.State | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
}

function Get-RecoveryPlan {
    param([hashtable] $Operation, [System.Collections.IDictionary] $Settings)

    $state = $Operation.State
    if ($state.Status -ne 'NeedsAttention') { throw "Operation status is '$($state.Status)', not NeedsAttention." }
    if ($state.Id -notmatch '^[a-f0-9]{32}$') { throw 'Operation ID is invalid.' }
    if ([DateTimeOffset]$state.LockExpiresUtc -gt [DateTimeOffset]::UtcNow) {
        throw "Worker lease has not expired. Retry after $($state.LockExpiresUtc)."
    }
    if ($state.CleanupIntent) { throw 'Pending cleanup requires manual recovery; this command will not change cleanup state.' }
    if ($null -eq $state.BatchHostNames) { throw 'No batch was checkpointed. Review the expired initiation authorization manually.' }
    $deadline = [DateTimeOffset]$state.DeadlineUtc
    if ($ExtendDeadlineHours) { $deadline = [DateTimeOffset]::UtcNow.AddHours($ExtendDeadlineHours) }
    if ($deadline -le [DateTimeOffset]::UtcNow) { throw 'The deadline expired. Explicitly approve -ExtendDeadlineHours before recovery.' }

    $vmScope = "/subscriptions/$($Settings.VirtualMachinesSubscriptionId)/resourceGroups/$($Settings.VirtualMachinesResourceGroupName)"
    $deployments = @(Get-RecoveryCollection -Path "$vmScope/providers/Microsoft.Resources/deployments?api-version=2021-04-01")
    $active = @($deployments | Where-Object {
        $_.name -like "shr_$($state.Id)*" -and $_.properties.provisioningState -notin @('Succeeded', 'Failed', 'Canceled')
    })
    if ($active.Count) { throw 'Related ARM deployments are still active. Wait for them to settle before recovery.' }

    $hash = Get-RecoveryHash -Settings $Settings
    $newTemplate = $null
    $oldTemplate = $null
    if ($RepairTemplateReference) {
        $intent = $state.DeploymentIntent
        if ($Settings.ReplacementMode -ne 'SideBySide' -or [int]$state.BatchNumber -ne 1 -or -not $intent) {
            throw 'Template repair requires a checkpointed first SideBySide deployment.'
        }
        if ($state.LastError -notmatch '\b400\b|InvalidTemplate') {
            throw 'Template repair requires a saved template-validation or HTTP 400 failure.'
        }
        if ($intent.Name -ne "shr_$($state.Id)") { throw 'Template repair cannot alter a retried or later deployment.' }
        $expectedUri = "$armRoot$vmScope/providers/Microsoft.Resources/deployments/$($intent.Name)?api-version=2021-04-01"
        if ($intent.Uri -ne $expectedUri) { throw 'Saved deployment URI does not match the configured VM scope.' }
        if (Invoke-RecoveryArm -Path $expectedUri.Substring($armRoot.Length) -AllowMissing) {
            throw 'ARM has a deployment record. Template repair is only allowed before deployment acceptance.'
        }
        $body = $intent.Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $oldTemplate = [string]$body.properties.templateLink.id
        if ($oldTemplate -notmatch '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Resources/templateSpecs/[^/]+/versions/[^/]+$') {
            throw 'Saved deployment does not reference a pinned Template Spec version.'
        }
        $matched = & $coordinator {
            param($Values, $VersionId, $OriginalHash)
            Test-ShrTemplateReferenceCorrection -Settings $Values -TemplateVersionId $VersionId -ConfigurationHash $OriginalHash
        } $Settings $oldTemplate $state.ConfigurationHash
        if (-not $matched) { throw 'Settings other than SessionHostTemplate changed. Restore those settings before template repair.' }
        if ($hash -eq $state.ConfigurationHash) { throw 'SessionHostTemplate has not changed; use normal recovery instead.' }
        $targets = @($intent.HostNames)
        if (-not $targets.Count -or ($targets | Where-Object { $_ -notmatch '^[a-zA-Z0-9-]{1,15}$' })) {
            throw 'Saved deployment target names are invalid.'
        }
        if (($targets -join ',') -cne (@($body.properties.parameters.sessionHostNames.value) -join ',')) {
            throw 'Saved deployment targets do not match its request parameters.'
        }
        $vms = @(Get-RecoveryCollection -Path "$vmScope/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01")
        $poolScope = "/subscriptions/$($Settings.HostPoolSubscriptionId)/resourceGroups/$($Settings.HostPoolResourceGroupName)/providers/Microsoft.DesktopVirtualization/hostPools/$($Settings.HostPoolName)"
        $hosts = @(Get-RecoveryCollection -Path "$poolScope/sessionHosts?api-version=2024-04-03")
        if (@($vms | Where-Object { $_.name -in $targets }).Count -or
            @($hosts | Where-Object { (($_.name -split '/')[-1] -split '\.')[0] -in $targets }).Count) {
            throw 'A target VM or AVD registration already exists. Template repair requires manual review.'
        }
        $token = (Get-AzAccessToken -ResourceUrl "$armRoot/" -DefaultProfile $context).Token
        if ($token -is [securestring]) { $token = [System.Net.NetworkCredential]::new('', $token).Password }
        $newTemplate = Get-TemplateSpecVersionResourceId -ARMToken $token -ResourceManagerUri $armRoot -ResourceId $Settings.SessionHostTemplate
        $template = (Invoke-RecoveryArm -Path "${newTemplate}?api-version=2022-02-01").properties.mainTemplate
        if (-not $template.parameters.Contains('sessionHostNames') -or -not $template.parameters.Contains('subnetResourceId')) {
            throw 'The corrected Template Spec does not define the session-host VM parameters.'
        }
        foreach ($name in $body.properties.parameters.Keys) {
            if (-not $template.parameters.Contains($name)) { throw "The corrected template does not accept parameter '$name'." }
        }
        foreach ($name in $template.parameters.Keys) {
            if (-not $template.parameters[$name].Contains('defaultValue') -and -not $body.properties.parameters.Contains($name)) {
                throw "The saved request is missing required template parameter '$name'."
            }
        }
    } elseif ($hash -ne $state.ConfigurationHash) {
        throw 'Configuration changed. Restore the initiating settings, or use -RepairTemplateReference for a rejected wrong-template deployment.'
    }
    return [PSCustomObject]@{
        OperationId = $state.Id
        FunctionApp = $appId
        Status = $state.Status
        TargetSessionHostCount = $Settings.TargetSessionHostCount
        PinnedImageVersion = $state.Image.Version
        BatchHostNames = @($state.BatchHostNames)
        PreviousTemplateVersion = $oldTemplate
        CorrectedTemplateVersion = $newTemplate
        DeadlineUtc = $deadline.ToUniversalTime().ToString('o')
        ConfigurationHash = $hash
    }
}

function Write-RecoveryBackup {
    param([hashtable] $Operation, [object] $DeploymentRecord)

    $path = Join-Path ([IO.Path]::GetFullPath($BackupDirectory)) "$($Operation.State.Id)-$([guid]::NewGuid().ToString('N'))"
    $directory = New-Item -ItemType Directory -Path $path
    if ($IsWindows) {
        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.SetOwner($sid)
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        Set-Acl -LiteralPath $path -AclObject $acl
    } else {
        [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    }
    $backup = @{ Operation = $Operation; DeploymentRecoveryRecord = $DeploymentRecord }
    $json = $backup | ConvertTo-Json -Depth 60
    [IO.File]::WriteAllText((Join-Path $directory.FullName 'state.json'), $json, [Text.UTF8Encoding]::new($false))
    return $directory.FullName
}

$settings = Get-RecoverySettings
$endpoint = [uri]$settings.AzureWebJobsStorage__tableServiceUri
if ($endpoint.Scheme -ne 'https' -or $endpoint.Host -notmatch "^[a-z0-9]{3,24}\.table\.$([regex]::Escape($environment.StorageEndpointSuffix))$" -or
    $endpoint.AbsolutePath -ne '/' -or $endpoint.Query -or $endpoint.UserInfo -or -not $endpoint.IsDefaultPort) {
    throw 'The Table endpoint does not match the active Azure cloud.'
}
$tableEndpoint = $endpoint.GetLeftPart([UriPartial]::Authority)
$key = & $coordinator { param($Values) Get-ShrOperationKey -Settings $Values } $settings
$operationPath = "shrContinuation(PartitionKey='SHR',RowKey='$key')"
$operation = Get-RecoveryOperation
$plan = Get-RecoveryPlan -Operation $operation -Settings $settings
$plan | Select-Object * -ExcludeProperty ConfigurationHash | Format-List | Out-Host
Write-Host 'Recovery preserves the operation, image, batch names and progress. It does not bypass worker readiness or capacity gates.'
if (-not $Apply) {
    Write-Host 'Preview only. Add -Apply to stop the app, back up state, recover and restart it after confirmation.'
    if ($PassThru) { $plan }
    return
}
if (-not $PSCmdlet.ShouldProcess($appId, "Back up and recover operation $($plan.OperationId), then start the app; timer reconciliation may resume immediately")) {
    return
}

try {
    Invoke-RecoveryArm -Path "$appId/stop?api-version=$webApi" -Method POST | Out-Null
    $stopDeadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
    do {
        $app = Invoke-RecoveryArm -Path "${appId}?api-version=$webApi"
        if ($app.properties.state -eq 'Stopped') { break }
        if ([DateTimeOffset]::UtcNow -ge $stopDeadline) { throw 'Timed out waiting for the Function App to stop.' }
        Start-Sleep -Seconds 5
    } while ($true)
    $freshSettings = Get-RecoverySettings
    if ((Get-RecoveryHash -Settings $freshSettings) -ne $plan.ConfigurationHash -or
        $freshSettings.AzureWebJobsStorage__tableServiceUri -ne $settings.AzureWebJobsStorage__tableServiceUri) {
        throw 'App settings changed after preview; run a new preview.'
    }
    $fresh = Get-RecoveryOperation
    if ($fresh.ETag -ne $operation.ETag) { throw 'Operation changed after preview; run a new preview.' }
    $checkedPlan = Get-RecoveryPlan -Operation $fresh -Settings $freshSettings
    if ($checkedPlan.CorrectedTemplateVersion -ne $plan.CorrectedTemplateVersion) {
        throw 'The selected Template Spec version changed after preview; run a new preview.'
    }
    $partition = $settings.HostPoolName.Replace("'", "''")
    $deploymentRecord = Invoke-RecoveryTable -Path "sessionHostDeploymentState(PartitionKey='$partition',RowKey='DeploymentState')" -AllowMissing
    $backupPath = Write-RecoveryBackup -Operation $fresh -DeploymentRecord $(if ($deploymentRecord) {
        $deploymentRecord.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    })
    Write-Host "Restricted state backup: $backupPath"
    if ($RepairTemplateReference) {
        $body = $fresh.State.DeploymentIntent.Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $body.properties.templateLink.id = $checkedPlan.CorrectedTemplateVersion
        $fresh.State.DeploymentIntent.Body = $body | ConvertTo-Json -Depth 40 -Compress
        $fresh.State.ConfigurationHash = $checkedPlan.ConfigurationHash
    }
    $fresh.State.Status = 'Running'
    $fresh.State.LastError = ''
    $fresh.State.LockOwner = ''
    $fresh.State.LockExpiresUtc = [DateTimeOffset]::UtcNow.ToString('o')
    if ($ExtendDeadlineHours) { $fresh.State.DeadlineUtc = $checkedPlan.DeadlineUtc }
    $entity = @{
        PartitionKey = 'SHR'; RowKey = $key
        State = ($fresh.State | ConvertTo-Json -Depth 40 -Compress)
    }
    if ([Text.Encoding]::Unicode.GetByteCount($entity.State) -gt 60000) {
        throw 'Recovered operation exceeds the SHR Table entity string budget.'
    }
    if ((Invoke-RecoveryArm -Path "${appId}?api-version=$webApi").properties.state -ne 'Stopped') {
        throw 'The Function App was restarted during recovery; refusing to write state.'
    }
    Invoke-RecoveryTable -Path $operationPath -Method MERGE -ETag $fresh.ETag -Body ($entity | ConvertTo-Json -Depth 45 -Compress) | Out-Null
    $verified = Get-RecoveryOperation
    if ($verified.Entity.State -cne $entity.State) {
        throw 'Recovered operation could not be verified; inspect the backup before restarting.'
    }
    Invoke-RecoveryArm -Path "$appId/start?api-version=$webApi" -Method POST | Out-Null
    Write-Host 'Operation recovered; Function App start requested. Verify host startup and the resumed worker in Application Insights.'
    if ($PassThru) {
        $checkedPlan.Status = 'Running'
        $checkedPlan | Add-Member -NotePropertyName BackupPath -NotePropertyValue $backupPath -PassThru
    }
} catch {
    Write-Warning 'Recovery did not finish. Do not retry blindly: verify the app is stopped and inspect the operation and backup. A successful state update is not rolled back.'
    throw
}
