$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer'
foreach ($module in @('Core', 'Deployment', 'Planning', 'DeviceCleanup', 'Lifecycle')) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $moduleRoot "SessionHostReplacer.$module.psm1"), [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "Parse errors in $module" }
    foreach ($definition in $ast.EndBlock.Statements |
        Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] }) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

function New-ReplacerTestHttpException {
    param([int]$StatusCode)
    $exception = [System.Exception]::new("Simulated HTTP $StatusCode")
    $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{ StatusCode = $StatusCode })
    return $exception
}

$invokeAzureRestMethodActual = (Get-Command Invoke-AzureRestMethod).ScriptBlock
$confirmSessionHostDeletionsActual = (Get-Command Confirm-SessionHostDeletions).ScriptBlock
$getDateActual = Get-Command Get-Date -CommandType Cmdlet

function Assert-ReplacerOperationBlocked {
    param([scriptblock]$Operation, [string]$Message)
    $failure = $null
    try { & $Operation | Out-Null } catch { $failure = $_ }
    $failure | Should Not BeNullOrEmpty
    if ($Message) { $failure.Exception.Message | Should Match ([regex]::Escape($Message)) }
}

function New-ReplacerTestHost {
    param([string]$Name = 'avd-01')
    [PSCustomObject]@{
        SessionHostName = $Name
        ResourceId = "/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/vm-$Name"
    }
}

function New-ReplacerTestRegistration {
    param([string]$Name = 'avd-01')
    $hostToDeploy = New-ReplacerTestHost $Name
    [PSCustomObject]@{
        id = "/subscriptions/test/resourceGroups/hosts/providers/Microsoft.DesktopVirtualization/hostPools/pool/sessionHosts/$Name.contoso.test"
        name = "pool/$Name.contoso.test"
        properties = @{ resourceId = $hostToDeploy.ResourceId; status = 'Unavailable' }
    }
}

function New-ReplacerRemovalTestHost {
    param([string]$Name = 'avd-01')
    $vm = New-ReplacerTestHost $Name
    $global:shrPreflight.Resources[$vm.ResourceId] = [PSCustomObject]@{
        id = $vm.ResourceId
        name = "vm-$Name"
        properties = @{ osProfile = @{ computerName = $Name } }
    }
    $global:shrPreflight.Registrations += New-ReplacerTestRegistration $Name
    $global:shrPreflight.Entra[$Name] = @([PSCustomObject]@{ id = "entra-$Name"; displayName = $Name })
    $global:shrPreflight.Intune[$Name] = @([PSCustomObject]@{ id = "intune-$Name"; deviceName = $Name })
    [PSCustomObject]@{
        SessionHostName = $Name
        ResourceId = $vm.ResourceId
        VMName = "vm-$Name"
        FQDN = "$Name.contoso.test"
        Sessions = 0
        PoweredOff = $true
        AllowNewSession = $false
    }
}

Describe 'Session Host Replacer real predeployment safety gate' {
    BeforeEach {
        $global:shrPreflight = @{
            Settings = @{
                VirtualMachinesSubscriptionId = 'test'
                VirtualMachinesResourceGroupName = 'hosts'
                HostPoolSubscriptionId = 'test'
                HostPoolResourceGroupName = 'hosts'
                HostPoolName = 'pool'
                SessionHostNamePrefix = 'avd-'
                SessionHostNameIndexLength = 2
                MinimumHostIndex = 1
                DeploymentPrefix = 'shr-pool'
                SessionHostTemplate = '/subscriptions/test/resourceGroups/templates/providers/Microsoft.Resources/templateSpecs/hosts'
                Tag_IncludeInAutomation = 'AutoReplace'
                Tag_DeployTimestamp = 'AutoReplaceDeployTimestamp'
                RemoveEntraDevice = $false
                RemoveIntuneDevice = $false
                SessionHostParameters = @{
                    IdentitySolution = 'EntraId'
                    IntuneEnrollment = $true
                    virtualMachineNameConv = 'vm-SHNAME'
                    ImageReference = @{ publisher = 'MicrosoftWindowsDesktop' }
                }
            }
            State = [PSCustomObject]@{ LastStatus = 'None'; PendingHostMappings = '{}' }
            Resources = @{}
            VMs = @()
            Registrations = @()
            Deployments = @()
            Entra = @{ 'avd-01' = @([PSCustomObject]@{ id = 'entra-01'; displayName = 'avd-01' }) }
            Intune = @{ 'avd-01' = @([PSCustomObject]@{ id = 'intune-01'; deviceName = 'avd-01' }) }
            Events = @()
            GraphToken = 'graph-token'
            DenyGraph = $false
            MalformedGraph = $false
            FailSave = $false
            DenyVMDeletion = $false
            DenyVMDeletionId = ''
            DeferVMDeletion = $false
            PendingDeletions = @()
            TimeProvider = $null
        }
        Mock Write-LogEntry {}
        Mock Read-FunctionAppSetting {
            param($SettingKey)
            $global:shrPreflight.Settings[$SettingKey]
        }
        Mock Get-ResourceManagerUri { 'https://management.azure.com' }
        Mock Get-GraphEndpoint { 'https://graph.microsoft.com' }
        Mock Get-AccessToken { $global:shrPreflight.GraphToken }
        Mock Get-TemplateSpecVersionResourceId { '/subscriptions/test/resourceGroups/templates/providers/Microsoft.Resources/templateSpecs/hosts/versions/1.0.0' }
        Mock Get-DeploymentState { $global:shrPreflight.State }
        Mock Save-DeploymentState {
            param($DeploymentState, [switch]$RequireSuccess)
            $global:shrPreflight.Events += 'checkpoint'
            if (-not $RequireSuccess -or $global:shrPreflight.FailSave) { throw 'Checkpoint failed' }
            $global:shrPreflight.State = $DeploymentState
        }
        Mock Start-Sleep { throw 'Unexpected polling: test fixtures must not wait on Azure.' }
        Mock Get-Date {
            param($Format)
            if ($global:shrPreflight.TimeProvider) {
                $time = & $global:shrPreflight.TimeProvider
                if ($Format) { $time.ToString($Format) } else { $time }
            }
            else { & $getDateActual @PSBoundParameters }
        }
        Mock Confirm-SessionHostDeletions {
            param($ARMToken, $GraphToken, $DeletedHostNames, $SessionHosts, $RemoveEntraDevice, $RemoveIntuneDevice)
            & $confirmSessionHostDeletionsActual @PSBoundParameters
        }
        Mock Invoke-AzureRestMethod {
            param($Uri, $Method, $Body)
            $path = ([Uri]$Uri).AbsolutePath
            if ($Method -eq 'Post' -and $path.EndsWith('/listRegistrationTokens')) {
                return [PSCustomObject]@{ expirationTime = [datetime]::UtcNow.AddHours(8).ToString('o') }
            }
            if ($path -match '/virtualMachines$') { return $global:shrPreflight.VMs }
            if ($path -match '/virtualMachines/[^/]+$') {
                $global:shrPreflight.Events += "$Method VM $path"
                if ($Method -eq 'Delete') {
                    if ($global:shrPreflight.DenyVMDeletion -or $global:shrPreflight.DenyVMDeletionId -eq $path) {
                        throw (New-ReplacerTestHttpException 403)
                    }
                    if ($global:shrPreflight.DeferVMDeletion) {
                        $global:shrPreflight.PendingDeletions += $path
                    }
                    else { $global:shrPreflight.Resources.Remove($path) }
                    return
                }
                if ($global:shrPreflight.Resources.ContainsKey($path)) {
                    $resource = $global:shrPreflight.Resources[$path]
                    if ($resource -is [int]) { throw (New-ReplacerTestHttpException $resource) }
                    return $resource
                }
                throw (New-ReplacerTestHttpException 404)
            }
            if ($path -match '/sessionHosts(?:/[^/]+)?$') {
                $global:shrPreflight.Events += "$Method AVD $path"
                if ($Method -eq 'Delete') {
                    $global:shrPreflight.Registrations = @($global:shrPreflight.Registrations | Where-Object { $_.id -ine $path })
                    return
                }
                return $global:shrPreflight.Registrations
            }
            if ($path -match '/deployments/?$') { return $global:shrPreflight.Deployments }
            if ($path -match '/deployments/') {
                $global:shrPreflight.Events += "$Method deployment $path"
                if ($Method -eq 'Put') { $global:shrPreflight.SubmittedBody = $Body | ConvertFrom-Json }
                return
            }
            throw "Unexpected ARM request: $Method $Uri"
        }
        Mock Invoke-GraphApiWithRetry {
            param($Method, $Uri)
            $global:shrPreflight.Events += "$Method Graph $Uri"
            if ($global:shrPreflight.DenyGraph) { throw (New-ReplacerTestHttpException 403) }
            if ($global:shrPreflight.MalformedGraph) { return [PSCustomObject]@{} }
            $directory = if ($Uri -like '*managedDevices*') { 'Intune' } else { 'Entra' }
            $records = $global:shrPreflight[$directory]
            if ($Method -eq 'Delete') {
                $id = $Uri.Split('/')[-1]
                foreach ($name in @($records.Keys)) {
                    $records[$name] = @($records[$name] | Where-Object { $_.id -ne $id })
                }
                return
            }
            $filter = [Uri]::UnescapeDataString($Uri)
            if ($filter -notmatch "(?:displayName|deviceName) eq '(.*)'") { throw "Unexpected Graph query: $Uri" }
            $name = $Matches[1].Replace("''", "'")
            return [PSCustomObject]@{ value = @($records[$name] | Where-Object { $null -ne $_ }) }
        }
    }

    AfterAll { Remove-Variable shrPreflight -Scope Global -ErrorAction SilentlyContinue }

    It 'cleans native Entra and Intune records before submitting the exact vacant VM name' {
        $result = Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1
        $result.SessionHostNames | Should Be @('avd-01')
        $global:shrPreflight.Entra['avd-01'].Count | Should Be 0
        $global:shrPreflight.Intune['avd-01'].Count | Should Be 0
        $global:shrPreflight.Events[0] | Should Be 'checkpoint'
        $body = $global:shrPreflight.SubmittedBody
        $body.properties.parameters.sessionHostNames.value | Should Be @('avd-01')
        $body.properties.parameters.Tags.value.'Microsoft.Compute/virtualMachines'.AutoReplaceDeploymentName | Should Be $result.DeploymentName
        ($global:shrPreflight.State.PendingHostMappings | ConvertFrom-Json).'avd-01'.ResourceId |
            Should Be (New-ReplacerTestHost).ResourceId
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Put deployment*' }).Count | Should Be 1
    }

    It 'removes and verifies a stale AVD registration before deploying' {
        $global:shrPreflight.Registrations = @(New-ReplacerTestRegistration)
        Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 | Out-Null
        $global:shrPreflight.Registrations.Count | Should Be 0
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete AVD*' }).Count | Should Be 1
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Get AVD*' }).Count | Should Be 2
    }

    It 'blocks the complete batch on Graph failure and successfully retries its durable name' {
        $global:shrPreflight.DenyGraph = $true
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'Simulated HTTP 403'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Put deployment*' }).Count | Should Be 0
        ($global:shrPreflight.State.PendingHostMappings | ConvertFrom-Json).'avd-01'.ResourceId |
            Should Be (New-ReplacerTestHost).ResourceId
        $global:shrPreflight.DenyGraph = $false
        (Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1).SessionHostNames | Should Be @('avd-01')
    }

    It 'checks every VM in the batch before deleting any identity or registration' {
        $hostToKeep = New-ReplacerTestHost avd-02
        $global:shrPreflight.Resources[$hostToKeep.ResourceId] = [PSCustomObject]@{ id = $hostToKeep.ResourceId }
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 2 } 'VM absence is not confirmed'
        @($global:shrPreflight.Events | Where-Object { $_ -like '* Graph *' -or $_ -like 'Delete AVD*' -or $_ -like 'Put deployment*' }).Count | Should Be 0
    }

    It 'does not interpret a VM authorization error as absence' {
        $global:shrPreflight.Resources[(New-ReplacerTestHost).ResourceId] = 403
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'Simulated HTTP 403'
        @($global:shrPreflight.Events | Where-Object { $_ -like '* Graph *' -or $_ -like 'Put deployment*' }).Count | Should Be 0
    }

    It 'does not interpret a null VM response as absence' {
        $global:shrPreflight.Resources[(New-ReplacerTestHost).ResourceId] = $null
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'Empty resource lookup response'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Put deployment*' }).Count | Should Be 0
    }

    It 'requires a Graph token even when SideBySide cleanup flags are disabled for native Entra' {
        $global:shrPreflight.GraphToken = ''
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'Required Graph token'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Put deployment*' }).Count | Should Be 0
    }

    It 'blocks malformed directory lookup responses instead of treating them as empty' {
        $global:shrPreflight.MalformedGraph = $true
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'Invalid Entra device lookup'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete Graph*' -or $_ -like 'Put deployment*' }).Count | Should Be 0
    }

    It 'follows pagination and blocks ambiguous duplicate device names without deleting either' {
        Mock Invoke-GraphApiWithRetry {
            param($Uri)
            if ($Uri -like '*skiptoken*') {
                return [PSCustomObject]@{ value = @([PSCustomObject]@{ id = 'second'; displayName = 'avd-01' }) }
            }
            [PSCustomObject]@{
                value = @([PSCustomObject]@{ id = 'first'; displayName = 'avd-01' })
                '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/devices?$skiptoken=next'
            }
        }
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'Multiple Entra'
        Assert-MockCalled Invoke-GraphApiWithRetry -Times 2 -Exactly -Scope It
        Assert-MockCalled Invoke-GraphApiWithRetry -Times 0 -Exactly -Scope It -ParameterFilter { $Method -eq 'Delete' }
    }

    It 'keeps hybrid directory cleanup optional while still verifying VM and AVD absence' {
        $global:shrPreflight.Settings.SessionHostParameters.IdentitySolution = 'ActiveDirectoryDomainServices'
        Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 | Out-Null
        @($global:shrPreflight.Events | Where-Object { $_ -like '* Graph *' }).Count | Should Be 0
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Get AVD*' }).Count | Should Be 2
    }

    It 'treats EntraKerberos-Hybrid as native Entra join but skips Intune if not enrolled or enabled' {
        $global:shrPreflight.Settings.SessionHostParameters.IdentitySolution = 'EntraKerberos-Hybrid'
        $global:shrPreflight.Settings.SessionHostParameters.IntuneEnrollment = $false
        Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 | Out-Null
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete Graph*/devices/*' }).Count | Should Be 1
        @($global:shrPreflight.Events | Where-Object { $_ -like '*managedDevices*' }).Count | Should Be 0
    }

    It 'blocks a stale registration referencing a different VM before deleting identities' {
        $registration = New-ReplacerTestRegistration
        $registration.properties.resourceId = (New-ReplacerTestHost avd-99).ResourceId
        $global:shrPreflight.Registrations = @($registration)
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'references a different VM'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete *' -or $_ -like 'Put deployment*' }).Count | Should Be 0
    }

    It 'classifies a definitive VM 404 as a ghost without a second uncertain lookup' {
        $global:shrPreflight.Registrations = @(New-ReplacerTestRegistration)
        $hosts = @(Get-SessionHosts -ARMToken token -FixSessionHostTags:$false -IncludePreExistingSessionHosts $false)
        $hosts.Count | Should Be 1
        $hosts[0].IsUnavailable | Should Be $true
        $hosts[0].ImageVersion | Should BeNullOrEmpty
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Get VM*' }).Count | Should Be 1
    }

    It 'does not classify a VM service failure as a ghost' {
        $global:shrPreflight.Registrations = @(New-ReplacerTestRegistration)
        $global:shrPreflight.Resources[(New-ReplacerTestHost).ResourceId] = 503
        Assert-ReplacerOperationBlocked {
            Get-SessionHosts -ARMToken token -FixSessionHostTags:$false -IncludePreExistingSessionHosts $false
        } 'Simulated HTTP 503'
    }

    It 'classifies an explicit ResourceNotFound response as a ghost' {
        $global:shrPreflight.Registrations = @(New-ReplacerTestRegistration)
        $global:shrPreflight.Resources[(New-ReplacerTestHost).ResourceId] = [PSCustomObject]@{ error = @{ code = 'ResourceNotFound' } }
        $hosts = @(Get-SessionHosts -ARMToken token -FixSessionHostTags:$false -IncludePreExistingSessionHosts $false)
        $hosts[0].IsUnavailable | Should Be $true
    }

    It 'does no cleanup or deployment if the required checkpoint cannot be saved' {
        $global:shrPreflight.FailSave = $true
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'Checkpoint failed'
        $global:shrPreflight.Events | Should Be @('checkpoint')
    }

    It 'blocks a changed VM naming convention for an existing recovery mapping' {
        $global:shrPreflight.State.PendingHostMappings = '{"avd-01":{"ResourceId":"/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/old-avd-01"}}'
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'VM naming changed'
        @($global:shrPreflight.Events | Where-Object { $_ -like '* Graph *' -or $_ -like 'Put deployment*' }).Count | Should Be 0
    }

    It 'blocks a changed legacy VM name before overwriting its recovery mapping' {
        $global:shrPreflight.State.PendingHostMappings = '{"avd-01":{"VMName":"old-avd-01"}}'
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'legacy VM name'
        @($global:shrPreflight.Events | Where-Object { $_ -like '* Graph *' -or $_ -like 'Put deployment*' }).Count | Should Be 0
        ($global:shrPreflight.State.PendingHostMappings | ConvertFrom-Json).'avd-01'.VMName | Should Be 'old-avd-01'
    }

    It 'uses one nine-read safety gate for a one-host DeleteFirst replacement without reacquiring Graph authentication' {
        $hostToRemove = New-ReplacerRemovalTestHost
        $global:shrPreflight.State.PendingHostMappings = @{
            'avd-01' = @{ VMName = $hostToRemove.VMName; ResourceId = $hostToRemove.ResourceId }
        } | ConvertTo-Json -Compress
        $result = Remove-SessionHosts -ARMToken token -GraphToken graph-token -SessionHostsPendingDelete @($hostToRemove) `
            -ReplacementMode DeleteFirst -EnableShutdownRetention $false -DeferDeviceCleanup
        $result.SuccessfulDeletions | Should Be @('avd-01')
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Get *' -or $_ -like '* Graph *' }).Count | Should Be 0

        Deploy-SessionHosts -ARMToken token -GraphToken graph-token -NewSessionHostsCount 1 `
            -PreferredSessionHostNames $result.SuccessfulDeletions -WaitForVMDeletion | Out-Null
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Get *' }).Count | Should Be 9
        Assert-MockCalled Confirm-SessionHostDeletions -Times 1 -Exactly -Scope It
        Assert-MockCalled Get-AccessToken -Times 0 -Exactly -Scope It
        $global:shrPreflight.Entra['avd-01'].Count | Should Be 0
        $global:shrPreflight.Intune['avd-01'].Count | Should Be 0
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Put deployment*' }).Count | Should Be 1
    }

    It 'overlaps all DeleteFirst VM deletions before a single batch wait and directory verification' {
        $hostsToRemove = @(New-ReplacerRemovalTestHost avd-01; New-ReplacerRemovalTestHost avd-02)
        $global:shrPreflight.DeferVMDeletion = $true
        Mock Start-Sleep {
            @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete VM*' }).Count | Should Be 2
            @($global:shrPreflight.Events | Where-Object { $_ -like '* Graph *' }).Count | Should Be 0
            foreach ($id in $global:shrPreflight.PendingDeletions) { $global:shrPreflight.Resources.Remove($id) }
        }
        $result = Remove-SessionHosts -ARMToken token -GraphToken graph-token -SessionHostsPendingDelete $hostsToRemove `
            -ReplacementMode DeleteFirst -EnableShutdownRetention $false -DeferDeviceCleanup
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Get VM*' }).Count | Should Be 0
        Deploy-SessionHosts -ARMToken token -GraphToken graph-token -NewSessionHostsCount 2 `
            -PreferredSessionHostNames $result.SuccessfulDeletions -WaitForVMDeletion | Out-Null
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Get VM*' }).Count | Should Be 8
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Get Graph*' }).Count | Should Be 8
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Get AVD*' }).Count | Should Be 2
        Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
        Assert-MockCalled Confirm-SessionHostDeletions -Times 1 -Exactly -Scope It
    }

    It 'completes SideBySide retirement through one shared gate after requesting every deletion' {
        $hostsToRemove = @(New-ReplacerRemovalTestHost avd-01; New-ReplacerRemovalTestHost avd-02)
        $result = Remove-SessionHosts -ARMToken token -GraphToken graph-token -SessionHostsPendingDelete $hostsToRemove `
            -ReplacementMode SideBySide -EnableShutdownRetention $false
        $result.SuccessfulDeletions.Count | Should Be 2
        $events = $global:shrPreflight.Events
        $events[0] | Should Match '^Delete AVD'
        $events[1] | Should Match '^Delete VM'
        $events[2] | Should Match '^Delete AVD'
        $events[3] | Should Match '^Delete VM'
        @($events | Where-Object { $_ -like 'Get VM*' }).Count | Should Be 6
        Assert-MockCalled Confirm-SessionHostDeletions -Times 1 -Exactly -Scope It
    }

    It 'does not allow SideBySide retirement to defer its required cleanup to a nonexistent deployment' {
        Assert-ReplacerOperationBlocked {
            Remove-SessionHosts -ARMToken token -SessionHostsPendingDelete @(New-ReplacerRemovalTestHost) `
                -ReplacementMode SideBySide -EnableShutdownRetention $false -DeferDeviceCleanup
        } 'Only a checkpointed'
        $global:shrPreflight.Events.Count | Should Be 0
    }

    It 'cleans an accepted retirement deletion after a later deletion fails and stops before the next host' {
        $hostsToRemove = @(New-ReplacerRemovalTestHost avd-01; New-ReplacerRemovalTestHost avd-02; New-ReplacerRemovalTestHost avd-03)
        $global:shrPreflight.DenyVMDeletionId = $hostsToRemove[1].ResourceId
        Assert-ReplacerOperationBlocked {
            Remove-SessionHosts -ARMToken token -GraphToken graph-token -SessionHostsPendingDelete $hostsToRemove `
                -ReplacementMode SideBySide -EnableShutdownRetention $false
        } 'Simulated HTTP 403'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete VM*' }).Count | Should Be 2
        $global:shrPreflight.Entra['avd-01'].Count | Should Be 0
        $global:shrPreflight.Entra['avd-02'].Count | Should Be 1
        $global:shrPreflight.Entra['avd-03'].Count | Should Be 1
        Assert-MockCalled Confirm-SessionHostDeletions -Times 1 -Exactly -Scope It
    }

    It 'retains standalone removal cleanup and waits before returning' {
        $hostToRemove = New-ReplacerRemovalTestHost
        Remove-VirtualMachine -ARMToken token -GraphToken graph-token -VMName $hostToRemove.VMName `
            -VMId $hostToRemove.ResourceId -FQDN $hostToRemove.FQDN
        $global:shrPreflight.Resources.ContainsKey($hostToRemove.ResourceId) | Should Be $false
        $global:shrPreflight.Entra['avd-01'].Count | Should Be 0
        $global:shrPreflight.Intune['avd-01'].Count | Should Be 0
        Assert-MockCalled Confirm-SessionHostDeletions -Times 1 -Exactly -Scope It
    }

    It 'cleans the actual computer names of retained VMs with prefixed ARM resource names in one batch' {
        $hostsToRemove = @(New-ReplacerRemovalTestHost avd-01; New-ReplacerRemovalTestHost avd-02)
        $global:shrPreflight.Registrations = @()
        $vms = @($hostsToRemove | ForEach-Object {
            [PSCustomObject]@{
                id = $_.ResourceId
                name = $_.VMName
                tags = [PSCustomObject]@{ Shutdown = [datetime]::UtcNow.AddDays(-4).ToString('o') }
            }
        })
        Mock Get-VMPowerStates {
            $states = @{}
            foreach ($id in $global:shrPreflight.Resources.Keys) { $states[$id] = $true }
            $states
        }
        $result = Remove-ExpiredShutdownVMs -ARMToken token -GraphToken graph-token -CachedVMs $vms `
            -ShutdownRetentionDays 3 -TagShutdownTimestamp Shutdown
        $result.CleanedUpCount | Should Be 2
        $result.DeletedVMNames | Should Be @('vm-avd-01', 'vm-avd-02')
        $global:shrPreflight.Entra['avd-01'].Count | Should Be 0
        $global:shrPreflight.Entra['avd-02'].Count | Should Be 0
        $global:shrPreflight.Intune['avd-01'].Count | Should Be 0
        $global:shrPreflight.Intune['avd-02'].Count | Should Be 0
        Assert-MockCalled Confirm-SessionHostDeletions -Times 1 -Exactly -Scope It
    }

    It 'does not guess a retained computer name when neither registration nor VM profile identifies it' {
        $hostToRemove = New-ReplacerRemovalTestHost
        $global:shrPreflight.Registrations = @()
        $global:shrPreflight.Resources[$hostToRemove.ResourceId].properties.osProfile = @{}
        Assert-ReplacerOperationBlocked {
            Remove-VirtualMachine -ARMToken token -VMName $hostToRemove.VMName -VMId $hostToRemove.ResourceId
        } 'Cannot establish the computer name'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete *' }).Count | Should Be 0
    }

    It 'does not permit a VM that appears during cleanup to be overwritten' {
        Mock Confirm-SessionHostDeletions {
            $vm = New-ReplacerTestHost
            $global:shrPreflight.Resources[$vm.ResourceId] = [PSCustomObject]@{ id = $vm.ResourceId }
            [PSCustomObject]@{ TotalHosts = 1; IncompleteHosts = @() }
        }
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'appeared during cleanup'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Put deployment*' }).Count | Should Be 0
    }

    It 'cannot verify a deleted host that has no resource mapping' {
        Assert-ReplacerOperationBlocked {
            Confirm-SessionHostDeletions -ARMToken token -DeletedHostNames avd-02 -SessionHosts @(New-ReplacerTestHost)
        } 'resource ID'
    }

    It 'cannot verify required device cleanup without a Graph token' {
        Assert-ReplacerOperationBlocked {
            Confirm-SessionHostDeletions -ARMToken token -DeletedHostNames avd-01 -SessionHosts @(New-ReplacerTestHost) -RemoveEntraDevice $true
        } 'Graph token'
    }

    It 'blocks on incomplete AVD verification even with both directory flags disabled' {
        $global:shrPreflight.Settings.SessionHostParameters.IdentitySolution = 'ActiveDirectoryDomainServices'
        Mock Confirm-SessionHostDeletions {
            [PSCustomObject]@{ TotalHosts = 1; IncompleteHosts = @([PSCustomObject]@{ Name = 'avd-01'; AVDConfirmed = $false }) }
        }
        Assert-ReplacerOperationBlocked { Deploy-SessionHosts -ARMToken token -NewSessionHostsCount 1 } 'remains incomplete'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Put deployment*' }).Count | Should Be 0
    }

    It 'recognizes Accepted deployments as in-flight' {
        $global:shrPreflight.Deployments = @([PSCustomObject]@{
            name = 'shr-pool_Count_1_VMs_20260920000000'
            properties = @{ provisioningState = 'Accepted'; parameters = @{ sessionHostNames = @{ value = @('avd-01') } } }
        })
        @( (Get-Deployments -ARMToken token).RunningDeployments ).Count | Should Be 1
    }

    It 'does not delete a similarly named VM during failed-deployment cleanup' {
        $global:shrPreflight.State.PendingHostMappings = @{ 'avd-01' = @{ ResourceId = (New-ReplacerTestHost).ResourceId } } | ConvertTo-Json -Compress
        $other = New-ReplacerTestHost avd-010
        $global:shrPreflight.VMs = @([PSCustomObject]@{ id = $other.ResourceId; name = 'vm-avd-010'; tags = @{} })
        Remove-FailedDeploymentArtifacts -ARMToken token -FailedDeployments @([PSCustomObject]@{
            DeploymentName = 'shr-pool-failed'; SessionHostNames = @('avd-01')
        }) -RegisteredSessionHostNames @()
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete VM*' }).Count | Should Be 0
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete deployment*' }).Count | Should Be 1
    }

    It 'preserves failed deployment history when VM deletion is denied' {
        $vm = New-ReplacerTestHost
        $global:shrPreflight.VMs = @([PSCustomObject]@{
            id = $vm.ResourceId; name = 'vm-avd-01'; tags = @{ AutoReplaceDeploymentName = 'shr-pool-failed' }
        })
        $global:shrPreflight.Resources[$vm.ResourceId] = $global:shrPreflight.VMs[0]
        $global:shrPreflight.DenyVMDeletion = $true
        Assert-ReplacerOperationBlocked { Remove-FailedDeploymentArtifacts -ARMToken token -FailedDeployments @([PSCustomObject]@{
            DeploymentName = 'shr-pool-failed'; SessionHostNames = @('avd-01')
        }) -RegisteredSessionHostNames @() } 'Simulated HTTP 403'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete deployment*' -or $_ -like '* Graph *' }).Count | Should Be 0
    }

    It 'refuses automatic deletion of legacy failed VMs without ownership evidence' {
        $vm = New-ReplacerTestHost
        $global:shrPreflight.VMs = @([PSCustomObject]@{ id = $vm.ResourceId; name = 'vm-avd-01'; tags = @{} })
        Assert-ReplacerOperationBlocked { Remove-FailedDeploymentArtifacts -ARMToken token -FailedDeployments @([PSCustomObject]@{
            DeploymentName = 'shr-pool-failed'; SessionHostNames = @('avd-01')
        }) -RegisteredSessionHostNames @() } 'Cannot prove ownership'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete *' }).Count | Should Be 0
    }

    It 'preserves failed deployment history when directory cleanup fails after the VM is gone' {
        $global:shrPreflight.State.PendingHostMappings = @{ 'avd-01' = @{ ResourceId = (New-ReplacerTestHost).ResourceId } } | ConvertTo-Json -Compress
        $global:shrPreflight.DenyGraph = $true
        Assert-ReplacerOperationBlocked {
            Remove-FailedDeploymentArtifacts -ARMToken token -FailedDeployments @([PSCustomObject]@{
                DeploymentName = 'shr-pool-failed'; SessionHostNames = @('avd-01')
            }) -RegisteredSessionHostNames @()
        } 'Simulated HTTP 403'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete deployment*' }).Count | Should Be 0
    }

    It 'requires operator review for legacy failed hosts without any durable resource inventory' {
        Assert-ReplacerOperationBlocked {
            Remove-FailedDeploymentArtifacts -ARMToken token -FailedDeployments @([PSCustomObject]@{
                DeploymentName = 'shr-pool-failed'; SessionHostNames = @('avd-01')
            }) -RegisteredSessionHostNames @()
        } 'no durable VM ID'
        @($global:shrPreflight.Events | Where-Object { $_ -like 'Delete *' }).Count | Should Be 0
    }

    It 'normalizes an empty ARM collection to zero items and rejects malformed envelopes' {
        Mock Invoke-RestMethod { [PSCustomObject]@{ value = @() } }
        @(& $invokeAzureRestMethodActual -ARMToken token -Uri 'https://management.azure.com/list' -RequireCollection).Count | Should Be 0
        Mock Invoke-RestMethod { [PSCustomObject]@{} }
        Assert-ReplacerOperationBlocked {
            & $invokeAzureRestMethodActual -ARMToken token -Uri 'https://management.azure.com/list' -RequireCollection
        } 'Invalid collection response'
    }

    It 'blocks the entire requested batch without directory mutations when VM deletion times out' {
        $hostsToRemove = @(New-ReplacerRemovalTestHost avd-01; New-ReplacerRemovalTestHost avd-02)
        $global:shrPreflight.DeferVMDeletion = $true
        Remove-SessionHosts -ARMToken token -GraphToken graph-token -SessionHostsPendingDelete $hostsToRemove `
            -ReplacementMode DeleteFirst -EnableShutdownRetention $false -DeferDeviceCleanup | Out-Null
        $global:shrPreflight.Clock = 0
        $global:shrPreflight.TimeProvider = {
            $global:shrPreflight.Clock++
            $seconds = $global:shrPreflight.Clock * 3600
            ([datetime]'2026-09-20T00:00:00Z').AddSeconds($seconds)
        }
        Mock Start-Sleep {}
        Assert-ReplacerOperationBlocked {
            Deploy-SessionHosts -ARMToken token -GraphToken graph-token -NewSessionHostsCount 2 `
                -PreferredSessionHostNames @('avd-01', 'avd-02') -WaitForVMDeletion
        }
        @($global:shrPreflight.Events | Where-Object { $_ -like '* Graph *' -or $_ -like 'Put deployment*' }).Count | Should Be 0
        @((($global:shrPreflight.State.PendingHostMappings | ConvertFrom-Json).PSObject.Properties).Name).Count | Should Be 2
    }

    It 'actually leaves AVD verification incomplete while a registration remains, with directory cleanup disabled' {
        $global:shrPreflight.Registrations = @(New-ReplacerTestRegistration)
        $global:shrPreflight.Clock = 0
        $global:shrPreflight.TimeProvider = {
            $global:shrPreflight.Clock++
            $seconds = if ($global:shrPreflight.Clock -le 3) { $global:shrPreflight.Clock } else { 3600 }
            ([datetime]'2026-09-20T00:00:00Z').AddSeconds($seconds)
        }
        $result = & $confirmSessionHostDeletionsActual -ARMToken token `
            -DeletedHostNames avd-01 -SessionHosts @(New-ReplacerTestHost) `
            -RemoveEntraDevice $false -RemoveIntuneDevice $false -MaxWaitMinutes 1
        $result.TotalHosts | Should Be 1
        $result.VMsConfirmed | Should Be 1
        $result.AVDConfirmed | Should Be 0
        @($result.IncompleteHosts).Count | Should Be 1
    }
}
