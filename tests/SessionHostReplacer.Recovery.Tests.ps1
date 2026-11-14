BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $recoveryPath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\Repair-SessionHostReplacerOperation.ps1'
    $modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'
    function New-RecoveryResponse {
        param([object] $Content, [int] $StatusCode = 200, [string] $ETag = 'version-1')
        [PSCustomObject]@{
            StatusCode = $StatusCode
            Content = if ($null -ne $Content) { $Content | ConvertTo-Json -Depth 60 -Compress } else { '' }
            Headers = @{ ETag = @($ETag) }
        }
    }
}

Describe 'SHR checked operator recovery' {
    BeforeAll {
        Import-Module Az.Accounts
        Import-Module $modulePath -Force

        function Set-TestRecoveryState {
            param([scriptblock] $Change)
            $value = $global:shrRecoveryTest.Entity.State | ConvertFrom-Json -AsHashtable
            & $Change $value
            $global:shrRecoveryTest.Entity.State = $value | ConvertTo-Json -Depth 40 -Compress
        }

        function Set-TestWrongTemplate {
            $prior = @{}
            foreach ($key in $global:shrRecoveryTest.Settings.Keys) { $prior[$key] = $global:shrRecoveryTest.Settings[$key] }
            $prior.SessionHostTemplate = '/subscriptions/subscription/resourceGroups/rg-ops/providers/Microsoft.Resources/templateSpecs/replacer'
            $oldHash = & $script:recoveryCoordinator { param($Values) Get-ShrConfigurationHash -Settings $Values } $prior
            Set-TestRecoveryState {
                param($value)
                $value.ConfigurationHash = $oldHash
                $body = $value.DeploymentIntent.Body | ConvertFrom-Json -AsHashtable
                $body.properties.templateLink.id = "$($prior.SessionHostTemplate)/versions/15.0.0"
                $value.DeploymentIntent.Body = $body | ConvertTo-Json -Depth 20 -Compress
            }
        }
    }
    BeforeEach {
        $script:recoveryCoordinator = Get-Module SessionHostReplacer.Continuation -All | Select-Object -First 1
        $settings = @{
            ReplacementMode = 'SideBySide'
            HostPoolSubscriptionId = 'subscription'
            HostPoolResourceGroupName = 'rg-control'
            HostPoolName = 'pool'
            VirtualMachinesSubscriptionId = 'subscription'
            VirtualMachinesResourceGroupName = 'rg-hosts'
            SessionHostTemplate = '/subscriptions/subscription/resourceGroups/rg-ops/providers/Microsoft.Resources/templateSpecs/session-hosts'
            TargetSessionHostCount = '10'
            AzureWebJobsStorage__tableServiceUri = 'https://sashr.table.core.windows.net'
        }
        $hash = & $script:recoveryCoordinator { param($Values) Get-ShrConfigurationHash -Settings $Values } $settings
        $state = @{
            Id = ('a' * 32)
            Status = 'NeedsAttention'
            ConfigurationHash = $hash
            DeadlineUtc = [DateTimeOffset]::UtcNow.AddHours(24).ToString('o')
            LockOwner = ''
            LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
            InitiationExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')
            Image = @{ Definition = '/gallery/images/avd'; Version = '2.0.0' }
            BatchNumber = 1
            BatchHostNames = @('avd04', 'avd05')
            DeploymentHostNames = @('avd04', 'avd05')
            Generation = 3
            LastError = 'Response status code does not indicate success: 400 (Bad Request).'
            CleanupIntent = $null
            DeploymentIntent = @{
                Name = "shr_$('a' * 32)"
                Uri = "https://management.azure.com/subscriptions/subscription/resourceGroups/rg-hosts/providers/Microsoft.Resources/deployments/shr_$('a' * 32)?api-version=2021-04-01"
                Timestamp = '20261102130100'
                HostNames = @('avd04', 'avd05')
                Body = (@{
                    properties = @{
                        mode = 'Incremental'
                        templateLink = @{ id = "$($settings.SessionHostTemplate)/versions/1.0.0" }
                        parameters = @{
                            sessionHostNames = @{ value = @('avd04', 'avd05') }
                            subnetResourceId = @{ value = '/subnet' }
                            administratorPassword = @{ value = 'fake-secret-for-backup-test' }
                        }
                    }
                } | ConvertTo-Json -Depth 20 -Compress)
            }
        }
        $global:shrRecoveryTest = @{
            Settings = $settings
            Entity = @{ PartitionKey = 'SHR'; RowKey = 'test-key'; State = ($state | ConvertTo-Json -Depth 40 -Compress) }
            RecoveryRecord = @{ LastStatus = 'None'; PendingHostMappings = '{"old":"new"}' }
            Calls = @()
            ETag = 'version-1'
            OperationReads = 0
            SettingsReads = 0
            Race = $false
            SettingsRace = $false
            TemplateRace = $false
            TemplateLists = 0
            AppState = 'Running'
            AppReads = 0
            ConcurrentStart = $false
            EmptyDeploymentResponse = $false
            Deployments = @()
            ExistingDeployment = $null
            Vms = @()
            Hosts = @()
            VmNextPage = $false
            MergeFailure = $false
            ReadFailure = $false
            VerificationFailure = $false
            TemplateParameters = @{
                sessionHostNames = @{ type = 'array' }
                subnetResourceId = @{ type = 'string' }
                administratorPassword = @{ type = 'secureString' }
            }
        }
        Mock Get-AzContext {
            $context = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
            $context.Subscription = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureSubscription]::new()
            $context.Subscription.Id = 'subscription'
            $context.Environment = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureEnvironment]::new()
            $context.Environment.Name = 'AzureCloud'
            $context
        }
        Mock Get-AzEnvironment {
            [PSCustomObject]@{ ResourceManagerUrl = 'https://management.azure.com/'; StorageEndpointSuffix = 'core.windows.net' }
        }
        Mock Get-AzAccessToken { [PSCustomObject]@{ Token = 'unit-test-token' } }
        Mock Start-Sleep {}
        Mock Invoke-AzRestMethod {
            param($Path, $Method)
            $sim = $global:shrRecoveryTest
            $sim.Calls += @{ Surface = 'ARM'; Method = $Method; Path = $Path }
            if ($Path -like '*/config/appsettings/list?*') {
                $sim.SettingsReads++
                if ($sim.SettingsRace -and $sim.SettingsReads -gt 1) { $sim.Settings.TargetSessionHostCount = '11' }
                return New-RecoveryResponse @{ properties = $sim.Settings }
            }
            if ($Path -like '*/stop?*') { $sim.AppState = 'Stopped'; return New-RecoveryResponse $null }
            if ($Path -like '*/start?*') { $sim.AppState = 'Running'; return New-RecoveryResponse $null }
            if ($Path -like '*/Microsoft.Web/sites/function?*') {
                $sim.AppReads++
                if ($sim.ConcurrentStart -and $sim.AppReads -gt 1) { $sim.AppState = 'Running' }
                return New-RecoveryResponse @{ properties = @{ state = $sim.AppState } }
            }
            if ($Path -like '*/Microsoft.Resources/deployments?api-version=*') {
                return New-RecoveryResponse @{ value = $sim.Deployments }
            }
            if ($Path -like '*/Microsoft.Resources/deployments/shr_*') {
                if ($sim.EmptyDeploymentResponse) { return New-RecoveryResponse $null }
                if ($sim.ExistingDeployment) { return New-RecoveryResponse $sim.ExistingDeployment }
                return New-RecoveryResponse @{ error = @{ code = 'DeploymentNotFound' } } 404
            }
            if ($Path -like '*/Microsoft.Compute/virtualMachines?*') {
                if ($sim.VmNextPage -and $Path -notlike '*page=2*') {
                    return New-RecoveryResponse @{ value = @(); nextLink = 'https://management.azure.com/subscriptions/subscription/resourceGroups/rg-hosts/providers/Microsoft.Compute/virtualMachines?api-version=2024-07-01&page=2' }
                }
                return New-RecoveryResponse @{ value = $sim.Vms }
            }
            if ($Path -like '*/sessionHosts?*') { return New-RecoveryResponse @{ value = $sim.Hosts } }
            if ($Path -like '*/templateSpecs/session-hosts/versions/*') {
                return New-RecoveryResponse @{ properties = @{ mainTemplate = @{ parameters = $sim.TemplateParameters } } }
            }
            throw "Unexpected ARM request: $Method $Path"
        }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Deployment {
            param($Method, $Uri)
            $sim = $global:shrRecoveryTest
            $sim.Calls += @{ Surface = 'Resolver'; Method = $Method; Path = $Uri }
            if ($Uri -like '*/templateSpecs/session-hosts?api-version=*') {
                return [PSCustomObject]@{ type = 'Microsoft.Resources/templateSpecs' }
            }
            if ($Uri -like '*/templateSpecs/session-hosts/versions?*') {
                $sim.TemplateLists++
                $version = if ($sim.TemplateRace -and $sim.TemplateLists -gt 1) { '3.0.0' } else { '2.0.0' }
                return [PSCustomObject]@{
                    name = $version
                    id = "$($sim.Settings.SessionHostTemplate)/versions/$version"
                    systemData = [PSCustomObject]@{ lastModifiedAt = '2026-11-02T11:00:00Z' }
                }
            }
            throw "Unexpected resolver request: $Method $Uri"
        }
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Headers, $Body)
            $sim = $global:shrRecoveryTest
            $sim.Calls += @{ Surface = 'Table'; Method = $Method; Path = $Uri; ETag = $Headers['If-Match']; Body = $Body }
            if ($Uri -like '*sessionHostDeploymentState*') { return New-RecoveryResponse $sim.RecoveryRecord }
            if ($Uri -like '*shrContinuation*') {
                if ($sim.ReadFailure) { return New-RecoveryResponse $null 403 }
                if ($Method -eq 'MERGE') {
                    if ($sim.MergeFailure) { return New-RecoveryResponse $null 412 }
                    $sim.Entity = $Body | ConvertFrom-Json -AsHashtable
                    $sim.ETag = 'version-2'
                    return New-RecoveryResponse $null 204
                }
                $sim.OperationReads++
                if ($sim.Race -and $sim.OperationReads -gt 1) { $sim.ETag = 'concurrent-update' }
                if ($sim.VerificationFailure -and $sim.OperationReads -gt 2) {
                    $changed = $sim.Entity.State | ConvertFrom-Json -AsHashtable
                    $changed.Generation = 99
                    $sim.Entity.State = $changed | ConvertTo-Json -Depth 40 -Compress
                }
                return New-RecoveryResponse $sim.Entity 200 $sim.ETag
            }
            throw "Unexpected Table request: $Method $Uri"
        }
        $script:recoveryArguments = @{
            FunctionAppName = 'function'
            ResourceGroupName = 'rg-ops'
            BackupDirectory = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
            PassThru = $true
        }
    }
    AfterEach { Remove-Variable shrRecoveryTest -Scope Global -ErrorAction SilentlyContinue }
    AfterAll { Remove-Module SessionHostReplacer -Force }

    It 'previews by default without Azure mutations or backup files' {
        $result = & $recoveryPath @recoveryArguments
        $result.Status | Should -Be 'NeedsAttention'
        @($global:shrRecoveryTest.Calls | Where-Object { $_.Method -ne 'GET' -and $_.Path -notlike '*/config/appsettings/list?*' }).Count | Should -Be 0
        Test-Path $recoveryArguments.BackupDirectory | Should -Be $false
    }

    It 'honors WhatIf even when Apply is supplied' {
        & $recoveryPath @recoveryArguments -Apply -WhatIf
        @($global:shrRecoveryTest.Calls | Where-Object { $_.Path -like '*/stop?*' -or $_.Method -eq 'MERGE' }).Count | Should -Be 0
        Test-Path $recoveryArguments.BackupDirectory | Should -Be $false
    }

    It 'backs up both records and resumes the same operation with an exact ETag' {
        $before = $global:shrRecoveryTest.Entity.State | ConvertFrom-Json -AsHashtable
        & $recoveryPath @recoveryArguments -Apply -Confirm:$false
        $after = $global:shrRecoveryTest.Entity.State | ConvertFrom-Json -AsHashtable
        $after.Status | Should -Be 'Running'
        $after.Id | Should -Be $before.Id
        $after.Image.Version | Should -Be $before.Image.Version
        $after.Generation | Should -Be 3
        ($after.BatchHostNames -join ',') | Should -Be ($before.BatchHostNames -join ',')
        $after.DeploymentIntent.Body | Should -Be $before.DeploymentIntent.Body
        $after.DeadlineUtc | Should -Be $before.DeadlineUtc
        $after.LastError | Should -Be ''
        $write = @($global:shrRecoveryTest.Calls | Where-Object { $_.Method -eq 'MERGE' })
        $write.Count | Should -Be 1
        $write[0].ETag | Should -Be 'version-1'
        $global:shrRecoveryTest.AppState | Should -Be 'Running'
        $files = @(Get-ChildItem $recoveryArguments.BackupDirectory -Filter state.json -Recurse)
        $files.Count | Should -Be 1
        $backup = Get-Content $files[0].FullName -Raw | ConvertFrom-Json -AsHashtable
        $backup.Operation.State.Status | Should -Be 'NeedsAttention'
        $backup.DeploymentRecoveryRecord.PendingHostMappings | Should -Be '{"old":"new"}'
        if ($IsWindows) {
            (Get-Acl $files[0].DirectoryName).AreAccessRulesProtected | Should -Be $true
        }
    }

    It 'repairs only the rejected template link and configuration fingerprint' {
        Set-TestWrongTemplate
        $before = $global:shrRecoveryTest.Entity.State | ConvertFrom-Json -AsHashtable
        & $recoveryPath @recoveryArguments -RepairTemplateReference -Apply -Confirm:$false
        $after = $global:shrRecoveryTest.Entity.State | ConvertFrom-Json -AsHashtable
        $oldBody = $before.DeploymentIntent.Body | ConvertFrom-Json -AsHashtable
        $newBody = $after.DeploymentIntent.Body | ConvertFrom-Json -AsHashtable
        $newBody.properties.templateLink.id | Should -Be "$($global:shrRecoveryTest.Settings.SessionHostTemplate)/versions/2.0.0"
        ($newBody.properties.parameters | ConvertTo-Json -Depth 20 -Compress) | Should -Be ($oldBody.properties.parameters | ConvertTo-Json -Depth 20 -Compress)
        $after.ConfigurationHash | Should -Not -Be $before.ConfigurationHash
        $after.Id | Should -Be $before.Id
        $after.DeploymentIntent.Name | Should -Be $before.DeploymentIntent.Name
        $after.Generation | Should -Be $before.Generation
        @($global:shrRecoveryTest.Calls | Where-Object { $_.Surface -eq 'ARM' -and $_.Method -in @('PUT','PATCH','DELETE') }).Count | Should -Be 0
    }

    It 'blocks a configuration change unless explicitly repaired' {
        $global:shrRecoveryTest.Settings.TargetSessionHostCount = '11'
        { & $recoveryPath @recoveryArguments } | Should -Throw -ExpectedMessage '*Configuration changed*'
    }

    It 'blocks unrelated configuration changes during template repair' {
        Set-TestWrongTemplate
        $global:shrRecoveryTest.Settings.TargetSessionHostCount = '11'
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*other than SessionHostTemplate*'
    }

    It 'blocks recovery of a running operation' {
        Set-TestRecoveryState { param($value) $value.Status = 'Running' }
        { & $recoveryPath @recoveryArguments } | Should -Throw -ExpectedMessage '*not NeedsAttention*'
    }

    It 'blocks a worker lease that has not expired' {
        Set-TestRecoveryState { param($value) $value.LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o') }
        { & $recoveryPath @recoveryArguments } | Should -Throw -ExpectedMessage '*lease has not expired*'
    }

    It 'blocks cleanup recovery rather than clearing cleanup state' {
        Set-TestRecoveryState { param($value) $value.CleanupIntent = @{ Hosts = @('old') } }
        { & $recoveryPath @recoveryArguments } | Should -Throw -ExpectedMessage '*Pending cleanup*'
    }

    It 'requires explicit approval to extend an expired deadline' {
        Set-TestRecoveryState { param($value) $value.DeadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o') }
        { & $recoveryPath @recoveryArguments } | Should -Throw -ExpectedMessage '*deadline expired*'
        $result = & $recoveryPath @recoveryArguments -ExtendDeadlineHours 12 -Apply -Confirm:$false
        ([DateTimeOffset]$result.DeadlineUtc -gt [DateTimeOffset]::UtcNow.AddHours(11)) | Should -Be $true
        ([DateTimeOffset]($global:shrRecoveryTest.Entity.State | ConvertFrom-Json).DeadlineUtc).ToUniversalTime() |
            Should -Be ([DateTimeOffset]$result.DeadlineUtc).ToUniversalTime()
    }

    It 'blocks active related ARM deployments' {
        $global:shrRecoveryTest.Deployments = @(@{ name = "shr_$('a' * 32)_b2"; properties = @{ provisioningState = 'Running' } })
        { & $recoveryPath @recoveryArguments } | Should -Throw -ExpectedMessage '*still active*'
    }

    It 'refuses a template change after ARM accepted a deployment' {
        Set-TestWrongTemplate
        $global:shrRecoveryTest.ExistingDeployment = @{ properties = @{ provisioningState = 'Failed' } }
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*before deployment acceptance*'
    }

    It 'refuses template repair if a target VM exists on a later inventory page' {
        Set-TestWrongTemplate
        $global:shrRecoveryTest.VmNextPage = $true
        $global:shrRecoveryTest.Vms = @(@{ name = 'avd04' })
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*target VM or AVD registration*'
    }

    It 'refuses template repair if a target AVD registration exists' {
        Set-TestWrongTemplate
        $global:shrRecoveryTest.Hosts = @(@{ name = 'pool/avd04.contoso.test' })
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*target VM or AVD registration*'
    }

    It 'requires template parameters that match the saved request' {
        Set-TestWrongTemplate
        $global:shrRecoveryTest.TemplateParameters.Remove('subnetResourceId')
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*session-host VM parameters*'
    }

    It 'rejects a corrected template with additional required parameters' {
        Set-TestWrongTemplate
        $global:shrRecoveryTest.TemplateParameters.Add('requiredInput', @{ type = 'string' })
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*missing required template parameter ''requiredInput''*'
    }

    It 'refuses a concurrent operation update after stopping the app' {
        $global:shrRecoveryTest.Race = $true
        { & $recoveryPath @recoveryArguments -Apply -Confirm:$false -WarningAction SilentlyContinue } | Should -Throw -ExpectedMessage '*Operation changed after preview*'
        $global:shrRecoveryTest.AppState | Should -Be 'Stopped'
        @($global:shrRecoveryTest.Calls | Where-Object { $_.Method -eq 'MERGE' }).Count | Should -Be 0
    }

    It 'refuses changed settings after stopping the app' {
        $global:shrRecoveryTest.SettingsRace = $true
        { & $recoveryPath @recoveryArguments -Apply -Confirm:$false -WarningAction SilentlyContinue } | Should -Throw -ExpectedMessage '*App settings changed after preview*'
        $global:shrRecoveryTest.AppState | Should -Be 'Stopped'
    }

    It 'refuses a newly published template version after confirmation' {
        Set-TestWrongTemplate
        $global:shrRecoveryTest.TemplateRace = $true
        { & $recoveryPath @recoveryArguments -RepairTemplateReference -Apply -Confirm:$false -WarningAction SilentlyContinue } | Should -Throw -ExpectedMessage '*version changed after preview*'
        @($global:shrRecoveryTest.Calls | Where-Object { $_.Method -eq 'MERGE' }).Count | Should -Be 0
    }

    It 'leaves the app stopped when the conditional write conflicts' {
        $global:shrRecoveryTest.MergeFailure = $true
        { & $recoveryPath @recoveryArguments -Apply -Confirm:$false -WarningAction SilentlyContinue } | Should -Throw -ExpectedMessage '*HTTP 412*'
        $global:shrRecoveryTest.AppState | Should -Be 'Stopped'
        @(Get-ChildItem $recoveryArguments.BackupDirectory -Filter state.json -Recurse).Count | Should -Be 1
    }

    It 'does not restart the app when readback differs from the exact submitted state' {
        $global:shrRecoveryTest.VerificationFailure = $true
        { & $recoveryPath @recoveryArguments -Apply -Confirm:$false -WarningAction SilentlyContinue } | Should -Throw -ExpectedMessage '*could not be verified*'
        $global:shrRecoveryTest.AppState | Should -Be 'Stopped'
    }

    It 'surfaces Table authorization failures without creating a backup or stopping the app' {
        $global:shrRecoveryTest.ReadFailure = $true
        { & $recoveryPath @recoveryArguments } | Should -Throw -ExpectedMessage '*HTTP 403*'
        $global:shrRecoveryTest.AppState | Should -Be 'Running'
        Test-Path $recoveryArguments.BackupDirectory | Should -Be $false
    }

    It 'rejects a Table endpoint outside the active cloud before acquiring a token' {
        $global:shrRecoveryTest.Settings.AzureWebJobsStorage__tableServiceUri = 'https://untrusted.example'
        { & $recoveryPath @recoveryArguments } | Should -Throw -ExpectedMessage '*active Azure cloud*'
        Assert-MockCalled Get-AzAccessToken -Times 0 -Exactly -Scope It
    }

    It 'does not switch the shared Azure context' {
        { & $recoveryPath @recoveryArguments -SubscriptionId 'another-subscription' } | Should -Throw -ExpectedMessage '*match the active Az context*'
    }

    It 'requires a usable operation ETag even for preview' {
        $global:shrRecoveryTest.ETag = '*'
        { & $recoveryPath @recoveryArguments } | Should -Throw -ExpectedMessage '*usable ETag*'
    }

    It 'does not create new batch authorization for an unstarted operation' {
        Set-TestRecoveryState { param($value) $value.BatchHostNames = $null }
        { & $recoveryPath @recoveryArguments } | Should -Throw -ExpectedMessage '*No batch was checkpointed*'
    }

    It 'rejects template repair for later SideBySide batches' {
        Set-TestWrongTemplate
        Set-TestRecoveryState { param($value) $value.BatchNumber = 2 }
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*first SideBySide*'
    }

    It 'rejects template repair for failures other than validation or HTTP 400' {
        Set-TestWrongTemplate
        Set-TestRecoveryState { param($value) $value.LastError = 'HTTP 403' }
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*template-validation or HTTP 400*'
    }

    It 'rejects saved deployment scopes that differ from app settings' {
        Set-TestWrongTemplate
        Set-TestRecoveryState { param($value) $value.DeploymentIntent.Uri = 'https://untrusted.example/deployment' }
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*configured VM scope*'
    }

    It 'rejects mismatched saved host-name lists before changing the template' {
        Set-TestWrongTemplate
        Set-TestRecoveryState { param($value) $value.DeploymentIntent.HostNames = @('avd99') }
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*do not match its request*'
    }

    It 'does not update state or restart the app if backup creation fails' {
        $blockedPath = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).txt"
        Set-Content -LiteralPath $blockedPath -Value 'A file cannot be used as a backup directory.' -Encoding ascii
        $recoveryArguments.BackupDirectory = $blockedPath
        { & $recoveryPath @recoveryArguments -Apply -Confirm:$false -WarningAction SilentlyContinue } | Should -Throw
        $global:shrRecoveryTest.AppState | Should -Be 'Stopped'
        @($global:shrRecoveryTest.Calls | Where-Object { $_.Method -eq 'MERGE' }).Count | Should -Be 0
    }

    It 'supports secure-string access tokens without printing their contents' {
        Mock Get-AzAccessToken {
            [PSCustomObject]@{ Token = (ConvertTo-SecureString 'unit-test-token' -AsPlainText -Force) }
        }
        $result = & $recoveryPath @recoveryArguments
        $result.OperationId | Should -Be ('a' * 32)
    }

    It 'does not treat an empty successful ARM response as proof of deployment absence' {
        Set-TestWrongTemplate
        $global:shrRecoveryTest.EmptyDeploymentResponse = $true
        { & $recoveryPath @recoveryArguments -RepairTemplateReference } | Should -Throw -ExpectedMessage '*resource absence cannot be established*'
    }

    It 'refuses a state write if another operator restarts the app during recovery' {
        $global:shrRecoveryTest.ConcurrentStart = $true
        { & $recoveryPath @recoveryArguments -Apply -Confirm:$false -WarningAction SilentlyContinue } | Should -Throw -ExpectedMessage '*restarted during recovery*'
        @($global:shrRecoveryTest.Calls | Where-Object { $_.Method -eq 'MERGE' }).Count | Should -Be 0
    }
}

Describe 'Shared SHR recovery fingerprints' {
    BeforeAll {
        Import-Module $modulePath -Force
        $script:hashCoordinator = Get-Module SessionHostReplacer.Continuation -All | Select-Object -First 1
    }
    AfterAll { Remove-Module SessionHostReplacer -Force }

    It 'produces exactly the runtime fingerprint from supplied app settings' {
        $values = @{ HostPoolName = 'pool'; SessionHostTemplate = '/template'; TargetSessionHostCount = '10' }
        $original = @{}
        foreach ($name in $values.Keys) {
            $original[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $values[$name])
        }
        try {
            $fromEnvironment = & $script:hashCoordinator { Get-ShrConfigurationHash }
            $runtimeSettings = [Environment]::GetEnvironmentVariables()
            $fromSettings = & $script:hashCoordinator { param($Values) Get-ShrConfigurationHash -Settings $Values } $runtimeSettings
            $fromSettings | Should -Be $fromEnvironment
        } finally {
            foreach ($name in $values.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name]) }
        }
    }

    It 'uses the identical normalized host-pool identity for operation lookup' {
        $settings = @{ HostPoolSubscriptionId = 'Subscription'; HostPoolResourceGroupName = 'RG'; HostPoolName = 'Pool' }
        $actual = & $script:hashCoordinator { param($Values) Get-ShrOperationKey -Settings $Values } $settings
        $expected = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('subscription/rg/pool'))).ToLowerInvariant()
        $actual | Should -Be $expected
    }
}
