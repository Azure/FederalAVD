BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $requestScript = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\tools\Request-SessionHostReplacerImageChange.ps1'
    $modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'
    Import-Module Az.Accounts
    Import-Module $modulePath -Force
    $coordinator = Get-Module SessionHostReplacer.Continuation -All | Select-Object -First 1

    function New-ImageRequestResponse {
        param($Value, [int] $Status = 200, [string] $ETag = 'request-etag')
        [PSCustomObject]@{
            StatusCode = $Status
            Content = if ($null -ne $Value) { $Value | ConvertTo-Json -Depth 50 -Compress } else { '' }
            Headers = @{ ETag = @($ETag) }
        }
    }

    function Invoke-TestImageRequest {
        param([switch] $Apply, [switch] $WhatIf, [string] $Version = '2.0.0', [string] $SubscriptionId)
        $arguments = @{
            FunctionAppName = 'shr-test'; ResourceGroupName = 'rg-test'
            ImageVersion = $Version; Apply = $Apply; Confirm = $false; WhatIf = $WhatIf
        }
        if ($SubscriptionId) { $arguments.SubscriptionId = $SubscriptionId }
        & $requestScript @arguments
    }

    function New-PreviousImageRequest {
        param([string] $OperationId = ('a' * 32))
        @{
            SchemaVersion = 1; Id = ('b' * 32); OperationId = $OperationId
            ExpectedImage = @{ Definition = $global:shrImageChangeTest.Definition; Version = '0.9.0' }
            Image = @{ Definition = $global:shrImageChangeTest.Definition; Version = '1.0.0'; Date = '2026-01-01T00:00:00Z' }
            RequestedUtc = '2026-01-01T00:00:00Z'
        }
    }
}

Describe 'SHR preview-first image-change operator request' {
    BeforeEach {
        $definition = '/subscriptions/subscription/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/gallery/images/desktop'
        $settings = @{
            HostPoolSubscriptionId = 'subscription'
            HostPoolResourceGroupName = 'rg-hosts'
            HostPoolName = 'pool'
            VirtualMachinesSubscriptionId = 'subscription'
            VirtualMachinesResourceGroupName = 'rg-hosts'
            SessionHostTemplate = '/subscriptions/subscription/resourceGroups/rg-ops/providers/Microsoft.Resources/templateSpecs/hosts'
            SessionHostParameters = '{"Location":"eastus"}'
            ReplacementMode = 'SideBySide'
            TargetSessionHostCount = '10'
            AzureWebJobsStorage__tableServiceUri = 'https://sashr.table.core.windows.net'
            AllowImageVersionRollback = 'false'
            IncludeExcludedImageVersions = 'false'
            ReplaceSessionHostOnNewImageVersionDelayDays = '0'
        }
        $state = @{
            Id = ('a' * 32); Status = 'Running'
            Image = @{ Definition = $definition; Version = '1.0.0' }
        }
        $state.ConfigurationHash = & $coordinator {
            param($Values, $State)
            Get-ShrConfigurationHash -Settings $Values -OperationState $State
        } $settings $state
        $script:imageChange = @{
            Settings = $settings; Operation = $state; Definition = $definition
            Previous = $null; ETag = 'request-etag'
            Writes = @(); ArmCalls = @(); TableCalls = @()
            SettingsReads = 0; OperationReads = 0; RequestReads = 0
            SettingsRace = $false; OperationRace = $false; ImageRace = $false; RequestRace = $false
            WriteStatus = 204; ArmStatus = 200; ReadError = $false
            Image = @{
                id = "$definition/versions/2.0.0"; name = '2.0.0'
                properties = @{
                    provisioningState = 'Succeeded'
                    publishingProfile = @{
                        publishedDate = '2026-01-01T00:00:00Z'
                        excludeFromLatest = $false
                        replicationMode = 'Full'
                        targetRegions = @(@{ name = 'East US'; regionalReplicaCount = 1 })
                    }
                    replicationStatus = @{ summary = @(@{ region = 'East US'; state = 'Completed' }) }
                }
            }
        }
        $global:shrImageChangeTest = $script:imageChange
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
        Mock Get-AzAccessToken { [PSCustomObject]@{ Token = (ConvertTo-SecureString 'test-token' -AsPlainText -Force) } }
        Mock Invoke-AzRestMethod {
            param($Path, $Method)
            $sim = $global:shrImageChangeTest
            $sim.ArmCalls += @{ Path = $Path; Method = $Method }
            if ($Path -like '*/config/appsettings/list?*') {
                $sim.SettingsReads++
                if ($sim.SettingsRace -and $sim.SettingsReads -gt 1) { $sim.Settings.TargetSessionHostCount = '11' }
                return New-ImageRequestResponse @{ properties = $sim.Settings }
            }
            if ($Path -like '*/versions/*') { return New-ImageRequestResponse $sim.Image -Status $sim.ArmStatus }
            throw "Unexpected ARM call: $Method $Path"
        }
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Body, $Headers)
            $sim = $global:shrImageChangeTest
            $sim.TableCalls += @{ Uri = $Uri; Method = $Method; Headers = $Headers }
            if ($Method -ne 'GET') {
                $sim.Writes += @{ Uri = $Uri; Method = $Method; Body = ($Body | ConvertFrom-Json -AsHashtable); Headers = $Headers }
                return New-ImageRequestResponse $null -Status $sim.WriteStatus
            }
            if ($sim.ReadError) { throw [InvalidOperationException]::new('original read failure') }
            if ($Uri -like '*-image-change*') {
                $sim.RequestReads++
                if ($sim.RequestRace -and $sim.RequestReads -gt 1) { $sim.Previous = New-PreviousImageRequest }
                if (-not $sim.Previous) { return New-ImageRequestResponse $null -Status 404 }
                return New-ImageRequestResponse @{ State = ($sim.Previous | ConvertTo-Json -Depth 20 -Compress) } -ETag $sim.ETag
            }
            $sim.OperationReads++
            if ($sim.OperationRace -and $sim.OperationReads -gt 1) { $sim.Operation.Id = ('c' * 32) }
            if ($sim.ImageRace -and $sim.OperationReads -gt 1) { $sim.Operation.Image.Version = '1.1.0' }
            New-ImageRequestResponse @{ State = ($sim.Operation | ConvertTo-Json -Depth 20 -Compress) }
        }
    }

    AfterAll {
        Remove-Variable shrImageChangeTest -Scope Global -ErrorAction SilentlyContinue
    }

    It 'parses and contains only ASCII' {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($requestScript, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        (Get-Content $requestScript -Raw) | Should -Not -Match '[^\x00-\x7F]'
    }

    It 'previews without writing, restarting, changing settings, or touching the process environment' {
        $before = [Environment]::GetEnvironmentVariables('Process')
        Invoke-TestImageRequest
        $script:imageChange.Writes.Count | Should -Be 0
        $script:imageChange.SettingsReads | Should -Be 1
        $script:imageChange.ArmCalls.Count | Should -Be 2
        $script:imageChange.TableCalls[0].Headers.Authorization | Should -Be 'Bearer test-token'
        $after = [Environment]::GetEnvironmentVariables('Process')
        Compare-Object @($before.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) @(
            $after.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }
        ) | Should -BeNullOrEmpty
    }

    It 'honors ShouldProcess WhatIf even with Apply' {
        Invoke-TestImageRequest -Apply -WhatIf
        $script:imageChange.Writes.Count | Should -Be 0
        $script:imageChange.SettingsReads | Should -Be 1
    }

    It 'inserts only the separate request with the exact schema and derived pool key' {
        Invoke-TestImageRequest -Apply
        $sim = $script:imageChange
        $sim.Writes.Count | Should -Be 1
        $sim.SettingsReads | Should -Be 2
        $sim.OperationReads | Should -Be 2
        $sim.RequestReads | Should -Be 2
        $write = $sim.Writes[0]
        $write.Method | Should -Be 'POST'
        $write.Headers.ContainsKey('If-Match') | Should -BeFalse
        $write.Uri | Should -Be 'https://sashr.table.core.windows.net/shrContinuation'
        $key = & $coordinator { param($Values) Get-ShrOperationKey -Settings $Values } $sim.Settings
        $write.Body.PartitionKey | Should -Be 'SHR'
        $write.Body.RowKey | Should -Be "$key-image-change"
        $request = $write.Body.State | ConvertFrom-Json -AsHashtable
        @($request.Keys | Sort-Object) -join ',' | Should -Be 'ExpectedImage,Id,Image,OperationId,RequestedUtc,SchemaVersion'
        $request.Id | Should -MatchExactly '^[0-9a-f]{32}$'
        $request.OperationId | Should -Be $sim.Operation.Id
        $request.ExpectedImage.Definition | Should -Be $sim.Definition
        $request.ExpectedImage.Version | Should -Be '1.0.0'
        @($request.Image.Keys | Sort-Object) -join ',' | Should -Be 'Date,Definition,Version'
        $request.Image.Version | Should -Be '2.0.0'
        ([DateTimeOffset]$request.Image.Date).UtcDateTime.ToString('o') | Should -Be '2026-01-01T00:00:00.0000000Z'
        $request.SchemaVersion | Should -Be 1
        $write.Body.State | Should -Match '"RequestedUtc":"[^"]+Z"'
    }

    It 'conditionally replaces a consumed request' {
        $script:imageChange.Previous = New-PreviousImageRequest
        $script:imageChange.Operation.LastImageChangeRequestId = ('b' * 32)
        Invoke-TestImageRequest -Apply
        $script:imageChange.Writes[0].Method | Should -Be 'PUT'
        $script:imageChange.Writes[0].Headers['If-Match'] | Should -Be 'request-etag'
    }

    It 'conditionally replaces an explicitly rejected request without changing the operation rejection record' {
        $script:imageChange.Previous = New-PreviousImageRequest
        $script:imageChange.Operation.LastImageChangeRejectedId = ('b' * 32)
        $script:imageChange.Operation.ImageChangeError = 'The previous requested image was ineligible.'
        Invoke-TestImageRequest -Apply
        $script:imageChange.Writes.Count | Should -Be 1
        $script:imageChange.Writes[0].Method | Should -Be 'PUT'
        $script:imageChange.Writes[0].Headers['If-Match'] | Should -Be 'request-etag'
        $script:imageChange.Operation.LastImageChangeRejectedId | Should -Be ('b' * 32)
        $script:imageChange.Operation.ImageChangeError | Should -Be 'The previous requested image was ineligible.'
        ($script:imageChange.Writes[0].Body.State | ConvertFrom-Json).Id | Should -Not -Be ('b' * 32)
    }

    It 'does not replace an outstanding request just because a different request was rejected' {
        $script:imageChange.Previous = New-PreviousImageRequest
        $script:imageChange.Operation.LastImageChangeRejectedId = ('c' * 32)
        { Invoke-TestImageRequest -Apply } | Should -Throw '*outstanding unconsumed*'
        $script:imageChange.Writes.Count | Should -Be 0
    }

    It 'conditionally replaces a validated stale request from a different operation' {
        $script:imageChange.Previous = New-PreviousImageRequest -OperationId ('d' * 32)
        Invoke-TestImageRequest -Apply
        $script:imageChange.Writes[0].Method | Should -Be 'PUT'
    }

    It 'rejects an outstanding request without a write' {
        $script:imageChange.Previous = New-PreviousImageRequest
        { Invoke-TestImageRequest -Apply } | Should -Throw '*outstanding unconsumed*'
        $script:imageChange.Writes.Count | Should -Be 0
    }

    It 'rejects unsafe operation or settings: <Case>' -ForEach @(
        @{ Case = 'non-running'; Change = { $script:imageChange.Operation.Status = 'Completed' }; Error = '*Running*' }
        @{ Case = 'marketplace'; Change = { $script:imageChange.Operation.Image.Definition = 'marketplace:pub/offer/sku' }; Error = '*Gallery*' }
        @{ Case = 'maintenance setting'; Change = { $script:imageChange.Settings.MaintenanceRequest = '{}' }; Error = '*MaintenanceRequest*' }
        @{ Case = 'maintenance operation'; Change = { $script:imageChange.Operation.MaintenanceRequest = @{ Id = 'maintenance' } }; Error = '*Maintenance*' }
        @{ Case = 'configuration drift'; Change = { $script:imageChange.Settings.TargetSessionHostCount = '12' }; Error = '*configuration*' }
        @{ Case = 'wrong cloud endpoint'; Change = { $script:imageChange.Settings.AzureWebJobsStorage__tableServiceUri = 'https://sashr.table.attacker.example' }; Error = '*endpoint*' }
    ) {
        & $Change
        { Invoke-TestImageRequest -Apply } | Should -Throw $Error
        $script:imageChange.Writes.Count | Should -Be 0
    }

    It 'rejects unavailable gallery metadata: <Case>' -ForEach @(
        @{ Case = 'unreplicated'; Change = { $script:imageChange.Image.properties.replicationStatus.summary[0].state = 'InProgress' }; Error = '*replication*' }
        @{ Case = 'missing region'; Change = { $script:imageChange.Image.properties.publishingProfile.targetRegions = @() }; Error = '*replication*' }
        @{ Case = 'shallow replication'; Change = { $script:imageChange.Image.properties.publishingProfile.replicationMode = 'Shallow' }; Error = '*replication*' }
        @{ Case = 'global exclusion'; Change = { $script:imageChange.Image.properties.publishingProfile.excludeFromLatest = $true }; Error = '*excluded*' }
        @{ Case = 'regional exclusion'; Change = { $script:imageChange.Image.properties.publishingProfile.targetRegions[0].excludeFromLatest = $true }; Error = '*excluded*' }
        @{ Case = 'missing exclusion metadata'; Change = { $script:imageChange.Image.properties.publishingProfile.Remove('excludeFromLatest') }; Error = '*metadata*' }
        @{ Case = 'missing date'; Change = { $script:imageChange.Image.properties.publishingProfile.Remove('publishedDate') }; Error = '*publication date*' }
        @{ Case = 'wrong version'; Change = { $script:imageChange.Image.name = '3.0.0' }; Error = '*exact gallery version*' }
        @{ Case = 'ARM failure'; Change = { $script:imageChange.ArmStatus = 403 }; Error = '*403*' }
    ) {
        & $Change
        { Invoke-TestImageRequest -Apply } | Should -Throw $Error
        $script:imageChange.Writes.Count | Should -Be 0
    }

    It 'allows exclusions only with the explicit pilot setting' {
        $script:imageChange.Settings.IncludeExcludedImageVersions = 'true'
        $script:imageChange.Image.properties.publishingProfile.excludeFromLatest = $true
        $script:imageChange.Operation.ConfigurationHash = & $coordinator {
            param($Values, $State) Get-ShrConfigurationHash -Settings $Values -OperationState $State
        } $script:imageChange.Settings $script:imageChange.Operation
        Invoke-TestImageRequest -Apply
        $script:imageChange.Writes.Count | Should -Be 1
    }

    It 'rejects a same-version request and a downgrade by default' {
        { Invoke-TestImageRequest -Version '1.0.0' } | Should -Throw '*already pinned*'
        { Invoke-TestImageRequest -Version '0.9.0' } | Should -Throw '*downgrade*'
        $script:imageChange.Writes.Count | Should -Be 0
    }

    It 'allows a downgrade only when configured and validates the exact requested version' {
        $script:imageChange.Settings.AllowImageVersionRollback = 'true'
        $script:imageChange.Operation.ConfigurationHash = & $coordinator {
            param($Values, $State) Get-ShrConfigurationHash -Settings $Values -OperationState $State
        } $script:imageChange.Settings $script:imageChange.Operation
        $script:imageChange.Image.name = '0.9.0'
        $script:imageChange.Image.id = "$($script:imageChange.Definition)/versions/0.9.0"
        Invoke-TestImageRequest -Version '0.9.0' -Apply
        $script:imageChange.Writes.Count | Should -Be 1
    }

    It 'blocks a request before the publication-age delay' {
        $script:imageChange.Settings.ReplaceSessionHostOnNewImageVersionDelayDays = '7'
        $script:imageChange.Operation.ConfigurationHash = & $coordinator {
            param($Values, $State) Get-ShrConfigurationHash -Settings $Values -OperationState $State
        } $script:imageChange.Settings $script:imageChange.Operation
        $script:imageChange.Image.properties.publishingProfile.publishedDate = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
        { Invoke-TestImageRequest } | Should -Throw '*publication-age delay*'
    }

    It 'rejects a race on <Race> before writing' -ForEach @(
        @{ Race = 'SettingsRace' }, @{ Race = 'OperationRace' }, @{ Race = 'ImageRace' }, @{ Race = 'RequestRace' }
    ) {
        $script:imageChange[$Race] = $true
        { Invoke-TestImageRequest -Apply } | Should -Throw
        $script:imageChange.Writes.Count | Should -Be 0
    }

    It 'reports HTTP <Status> as a concurrency conflict without retrying the write' -ForEach @(
        @{ Status = 409 }, @{ Status = 412 }
    ) {
        $script:imageChange.WriteStatus = $Status
        { Invoke-TestImageRequest -Apply } | Should -Throw '*Concurrency conflict*'
        $script:imageChange.Writes.Count | Should -Be 1
    }

    It 'refuses a wildcard ETag' {
        $script:imageChange.Previous = New-PreviousImageRequest -OperationId ('d' * 32)
        $script:imageChange.ETag = '*'
        { Invoke-TestImageRequest -Apply } | Should -Throw '*ETag*'
        $script:imageChange.Writes.Count | Should -Be 0
    }

    It 'preserves original read failures' {
        $script:imageChange.ReadError = $true
        { Invoke-TestImageRequest } | Should -Throw '*original read failure*'
    }

    It 'refuses a malformed stale request instead of treating it as consumed' {
        $script:imageChange.Previous = New-PreviousImageRequest -OperationId 'not-an-operation-id'
        { Invoke-TestImageRequest -Apply } | Should -Throw '*previous image-change request is invalid*'
        $script:imageChange.Writes.Count | Should -Be 0
    }

    It 'rejects a missing Az context before accessing Azure' {
        Mock Get-AzContext { $null }
        { Invoke-TestImageRequest } | Should -Throw '*Sign in*'
        $script:imageChange.ArmCalls.Count | Should -Be 0
    }

    It 'rejects invalid exact versions: <Version>' -ForEach @(
        @{ Version = 'latest' }, @{ Version = '1.2' }, @{ Version = '1.2.3.4' }, @{ Version = '1.2.3-preview' }
    ) {
        { Invoke-TestImageRequest -Version $Version } | Should -Throw
        $script:imageChange.ArmCalls.Count | Should -Be 0
    }

    It 'rejects a subscription different from the active context' {
        { Invoke-TestImageRequest -SubscriptionId 'other-subscription' } | Should -Throw '*active Az context*'
        $script:imageChange.ArmCalls.Count | Should -Be 0
    }
}
