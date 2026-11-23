Describe 'StorageQuotaManager' {
BeforeAll {
    $runbookPath = Join-Path $PSScriptRoot '..\deployments\add-ons\storageQuotaManager\runbook\run.ps1'
    function Get-AutomationVariable { param($Name) }
    function Connect-AzAccount { param([switch]$Identity) }
    function Get-AzAccessToken { param($ResourceUrl) }

    function Initialize-QuotaScenario {
        param([string]$Sku = 'StandardV2_LRS', [string]$Kind = 'FileStorage')
        $script:account = @{ name = 'files'; kind = $Kind; sku = @{ name = $Sku }; properties = @{} }
        $script:shareProperties = @{
            shareQuota = 300; shareUsageBytes = 280GB; enabledProtocols = 'SMB'
            provisionedIops = 4321; provisionedBandwidthMibps = 123
            metadata = @{ owner = 'keep-me' }
        }
        $script:usage = @{
            fileShareLimits = @{ minProvisionedStorageGiB = 32; maxProvisionedStorageGiB = 262144 }
            storageAccountLimits = @{ maxProvisionedStorageGiB = 4194304 }
            storageAccountUsage = @{ liveShares = @{ provisionedStorageGiB = 300 } }
        }
        $script:patches = [Collections.Generic.List[object]]::new()
        $script:requests = [Collections.Generic.List[string]]::new()
        $script:patchError = $null
        $script:getError = $null
        $script:badPatchQuota = $false
        $script:badPatchPerformance = $false
        $script:badPatchBandwidth = $false
        $script:emptyPatchResponse = $false
        $script:emptyAccountPage = $false
        $script:paginate = $false
        $script:badNextLink = $false
        $script:additionalShares = @()
    }

    function Invoke-QuotaScenario {
        & ([scriptblock]::Create([IO.File]::ReadAllText($runbookPath))) *>&1 | ForEach-Object { "$_" }
    }
}

BeforeEach {
    Mock Get-AutomationVariable {
        switch ($Name) {
            ResourceGroupName { 'storage-rg' }
            SubscriptionId { 'subscription' }
            ResourceManagerUri { 'https://management.example.test/' }
        }
    }
    Mock Connect-AzAccount {}
    Mock Get-AzAccessToken { @{ Token = 'offline-test-token' } }
    Mock Invoke-RestMethod {
        $script:requests.Add("$Method $Uri")
        if ($script:getError -and $Method -eq 'GET') { throw $script:getError }
        $response = if ($Method -eq 'PATCH') {
            if ($script:patchError) { throw $script:patchError }
            $update = $Body | ConvertFrom-Json -AsHashtable
            $script:patches.Add($update)
            if ($script:emptyPatchResponse) { return $null }
            $resultProperties = $script:shareProperties.Clone()
            $resultProperties.shareQuota = if ($script:badPatchQuota) { 999 } else { $update.properties.shareQuota }
            if ($script:badPatchPerformance) { $resultProperties.provisionedIops++ }
            if ($script:badPatchBandwidth) { $resultProperties.provisionedBandwidthMibps++ }
            @{ properties = $resultProperties }
        }
        elseif ($Uri -match '/storageAccounts\?') {
            if ($script:badNextLink) { @{ value = @(); nextLink = 'https://other.example.test/page2' } }
            elseif ($script:paginate -and $Uri -notmatch 'page=2') { @{ value = @(); nextLink = "$Uri&page=2" } }
            elseif ($script:emptyAccountPage) { @{ value = @() } }
            else { @{ value = @($script:account) } }
        }
        elseif ($Uri -match '/usages/default\?') { @{ properties = $script:usage } }
        elseif ($Uri -match '/shares\?') {
            if ($script:paginate -and $Uri -notmatch 'page=2') { @{ value = @(); nextLink = "$Uri&page=2" } }
            else { @{ value = @(@{ name = 'profile'; properties = $script:shareProperties }) + $script:additionalShares } }
        }
        elseif ($Uri -match '/shares/profile\?') { @{ properties = $script:shareProperties } }
        elseif ($Uri -match '/shares/other\?') { @{ properties = @{ enabledProtocols = 'NFS' } } }
        else { throw "Unexpected REST call: $Method $Uri" }
        $response | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    }
}

Describe 'Provisioned v2 capacity scaling: <Sku>' -ForEach @(
    @{ Sku = 'StandardV2_LRS' }, @{ Sku = 'StandardV2_ZRS' },
    @{ Sku = 'PremiumV2_LRS' }, @{ Sku = 'PremiumV2_ZRS' }
) {
    BeforeEach { Initialize-QuotaScenario -Sku $Sku }

    It 'grows small shares without sending or changing performance' {
        $output = Invoke-QuotaScenario
        $script:patches.Count | Should -Be 1
        $script:patches[0].properties.shareQuota | Should -Be 400
        @($script:patches[0].properties.Keys) | Should -Be @('shareQuota')
        $output -join "`n" | Should -Match 'Storage quota check complete'
    }

    It 'grows large shares by 500 GiB even during a service decrease cooldown' {
        $script:shareProperties.shareQuota = 2000
        $script:shareProperties.shareUsageBytes = 1800GB
        $script:shareProperties.nextAllowedQuotaDowngradeTime = [DateTime]::UtcNow.AddHours(20).ToString('r')
        $script:usage.storageAccountUsage.liveShares.provisionedStorageGiB = 2000
        Invoke-QuotaScenario | Out-Null
        $script:patches[0].properties.shareQuota | Should -Be 2500
    }

    It 'shrinks small shares and preserves existing metadata without performance fields' {
        $script:shareProperties.shareUsageBytes = 50GB
        $script:shareProperties.nextAllowedQuotaDowngradeTime = [DateTime]::UtcNow.AddHours(-1).ToString('r')
        Invoke-QuotaScenario | Out-Null
        $script:patches[0].properties.shareQuota | Should -Be 200
        $script:patches[0].properties.metadata.owner | Should -Be 'keep-me'
        $script:patches[0].properties.metadata.sqmLastDecreased | Should -Not -BeNullOrEmpty
        $script:patches[0].properties.ContainsKey('provisionedIops') | Should -BeFalse
        $script:patches[0].properties.ContainsKey('provisionedBandwidthMibps') | Should -BeFalse
    }

    It 'shrinks large shares by 500 GiB' {
        $script:shareProperties.shareQuota = 2000
        $script:shareProperties.shareUsageBytes = 500GB
        $script:usage.storageAccountUsage.liveShares.provisionedStorageGiB = 2000
        Invoke-QuotaScenario | Out-Null
        $script:patches[0].properties.shareQuota | Should -Be 1500
    }

    It 'honors the service cooldown after an increase with no local decrease metadata' {
        $script:shareProperties.shareUsageBytes = 50GB
        $script:shareProperties.nextAllowedQuotaDowngradeTime = [DateTime]::UtcNow.AddHours(20).ToString('r')
        (Invoke-QuotaScenario) -join "`n" | Should -Match 'Service quota decrease cooldown'
        $script:patches.Count | Should -Be 0
    }

    It 'retains the independent local 24-hour decrease cooldown' {
        $script:shareProperties.shareUsageBytes = 50GB
        $script:shareProperties.metadata.sqmLastDecreased = [DateTime]::UtcNow.AddHours(-2).ToString('o')
        (Invoke-QuotaScenario) -join "`n" | Should -Match 'Local decrease cooldown'
        $script:patches.Count | Should -Be 0
    }

    It 'allows another decrease after both cooldowns expire' {
        $script:shareProperties.shareUsageBytes = 50GB
        $script:shareProperties.metadata.sqmLastDecreased = [DateTime]::UtcNow.AddHours(-25).ToString('o')
        $script:shareProperties.nextAllowedQuotaDowngradeTime = [DateTime]::UtcNow.AddHours(-1).ToString('r')
        Invoke-QuotaScenario | Out-Null
        $script:patches.Count | Should -Be 1
    }

    It 'clamps a decrease at the cloud service minimum' {
        $script:shareProperties.shareUsageBytes = 50GB
        $script:usage.fileShareLimits.minProvisionedStorageGiB = 256
        (Invoke-QuotaScenario) -join "`n" | Should -Match 'Decrease limited by minimum'
        $script:patches[0].properties.shareQuota | Should -Be 256
    }

    It 'accepts the v2 32 GiB minimum and retains the existing growth step' {
        $script:shareProperties.shareQuota = 32
        $script:shareProperties.shareUsageBytes = 1GB
        Invoke-QuotaScenario | Out-Null
        $script:patches[0].properties.shareQuota | Should -Be 132
    }

    It 'clamps growth to the service share maximum' {
        $script:usage.fileShareLimits.maxProvisionedStorageGiB = 350
        (Invoke-QuotaScenario) -join "`n" | Should -Match 'Growth limited'
        $script:patches[0].properties.shareQuota | Should -Be 350
    }

    It 'logs the maximum and does not PATCH a share already at 256 TiB' {
        $script:shareProperties.shareQuota = 262144
        $script:shareProperties.shareUsageBytes = 262140GB
        $script:usage.storageAccountUsage.liveShares.provisionedStorageGiB = 262144
        (Invoke-QuotaScenario) -join "`n" | Should -Match 'At capacity limit'
        $script:patches.Count | Should -Be 0
    }

    It 'respects shared account provisioned-capacity headroom' {
        $script:usage.storageAccountLimits.maxProvisionedStorageGiB = 2000
        $script:usage.storageAccountUsage.liveShares.provisionedStorageGiB = 1950
        (Invoke-QuotaScenario) -join "`n" | Should -Match 'headroom: 50GiB'
        $script:patches[0].properties.shareQuota | Should -Be 350
    }

    It 'keeps unused shares unchanged' {
        $script:shareProperties.shareUsageBytes = 0
        Invoke-QuotaScenario | Out-Null
        $script:patches.Count | Should -Be 0
    }

    It 'keeps exact thresholds unchanged' {
        $script:shareProperties.shareUsageBytes = 250GB
        Invoke-QuotaScenario | Out-Null
        $script:patches.Count | Should -Be 0
    }

    It 'fails on invalid stats instead of treating absent usage as zero' {
        $script:shareProperties.Remove('shareUsageBytes')
        { Invoke-QuotaScenario } | Should -Throw '*Invalid response*shareUsageBytes*'
        $script:patches.Count | Should -Be 0
    }

    It 'fails on invalid quota instead of PATCHing' {
        $script:shareProperties.shareQuota = -1
        { Invoke-QuotaScenario } | Should -Throw '*Invalid response*shareQuota*'
    }

    It 'rejects quota below the provisioned v2 minimum' {
        $script:shareProperties.shareQuota = 31
        { Invoke-QuotaScenario } | Should -Throw '*Invalid response/limits*'
        $script:patches.Count | Should -Be 0
    }

    It 'requires independent performance in the v2 GET response' {
        $script:shareProperties.Remove('provisionedIops')
        { Invoke-QuotaScenario } | Should -Throw '*Invalid response*provisionedIops*'
        $script:patches.Count | Should -Be 0
    }

    It 'fails closed on a malformed service downgrade time' {
        $script:shareProperties.shareUsageBytes = 50GB
        $script:shareProperties.nextAllowedQuotaDowngradeTime = 'not-a-date'
        { Invoke-QuotaScenario } | Should -Throw '*Invalid response*nextAllowedQuotaDowngradeTime*'
        $script:patches.Count | Should -Be 0
    }

    It 'fails closed on malformed local decrease metadata' {
        $script:shareProperties.shareUsageBytes = 50GB
        $script:shareProperties.metadata.sqmLastDecreased = 'not-a-date'
        { Invoke-QuotaScenario } | Should -Throw '*Invalid response*sqmLastDecreased*'
    }

    It 'fails on missing service limits without an API downgrade or fallback' {
        $script:usage.Remove('fileShareLimits')
        { Invoke-QuotaScenario } | Should -Throw '*Invalid response*service minimum*'
        $script:patches.Count | Should -Be 0
    }

    It 'propagates service capacity/performance constraint failures without retrying as success' {
        $script:patchError = '409 AccountCapacityExceeded: provisioned account limit'
        { Invoke-QuotaScenario } | Should -Throw '*Storage API PATCH failed*AccountCapacityExceeded*'
        @($script:requests | Where-Object { $_ -like 'PATCH *' }).Count | Should -Be 1
    }

    It 'propagates unsupported-cloud API failures without automatic downgrade' {
        $script:getError = 'InvalidApiVersionParameter'
        { Invoke-QuotaScenario } | Should -Throw '*No fallback or API downgrade*InvalidApiVersionParameter*'
        $script:requests.Count | Should -Be 1
    }

    It 'propagates service shrink failures without reporting success or retrying' {
        $script:shareProperties.shareUsageBytes = 50GB
        $script:patchError = '409 ShareQuotaDowngradeNotAllowed'
        { Invoke-QuotaScenario } | Should -Throw '*ShareQuotaDowngradeNotAllowed*'
        @($script:requests | Where-Object { $_ -like 'PATCH *' }).Count | Should -Be 1
    }

    It 'fails when PATCH does not confirm the requested quota' {
        $script:badPatchQuota = $true
        { Invoke-QuotaScenario } | Should -Throw '*Invalid PATCH response*'
    }

    It 'fails when PATCH unexpectedly changes independently provisioned performance' {
        $script:badPatchPerformance = $true
        { Invoke-QuotaScenario } | Should -Throw '*Unexpected performance change*'
    }

    It 'fails when PATCH unexpectedly changes independently provisioned bandwidth' {
        $script:badPatchBandwidth = $true
        { Invoke-QuotaScenario } | Should -Throw '*Unexpected performance change*'
    }

    It 'fails on an empty PATCH response instead of reporting success' {
        $script:emptyPatchResponse = $true
        { Invoke-QuotaScenario } | Should -Throw '*Invalid response*PATCH shareQuota*'
    }
}

Describe 'Legacy quota compatibility and discovery' {
    BeforeEach { Initialize-QuotaScenario -Sku 'Premium_LRS' }

    It 'preserves provisioned v1 growth without requiring v2 usage endpoints' {
        Invoke-QuotaScenario | Out-Null
        $script:patches[0].properties.shareQuota | Should -Be 400
        @($script:requests | Where-Object { $_ -match '/usages/' }).Count | Should -Be 0
    }

    It 'honors provisioned v1 service downgrade cooldowns' {
        $script:shareProperties.shareUsageBytes = 50GB
        $script:shareProperties.nextAllowedQuotaDowngradeTime = [DateTime]::UtcNow.AddHours(20).ToString('r')
        Invoke-QuotaScenario | Out-Null
        $script:patches.Count | Should -Be 0
    }

    It 'accounts for other provisioned v1 shares before growing' {
        $script:additionalShares = @(@{ name = 'other'; properties = @{ shareQuota = 102100 } })
        (Invoke-QuotaScenario) -join "`n" | Should -Match 'At capacity limit'
    }

    It 'supports StorageV2 pay-as-you-go SMB shares with legacy 5 TiB limits' {
        $script:account.kind = 'StorageV2'
        $script:account.sku.name = 'Standard_LRS'
        $script:shareProperties.shareQuota = 5100
        $script:shareProperties.shareUsageBytes = 5000GB
        Invoke-QuotaScenario | Out-Null
        $script:patches[0].properties.shareQuota | Should -Be 5120
    }

    It 'supports large-file-share StorageV2 limits' {
        $script:account.kind = 'StorageV2'
        $script:account.sku.name = 'Standard_ZRS'
        $script:account.properties.largeFileSharesState = 'Enabled'
        $script:shareProperties.shareQuota = 5100
        $script:shareProperties.shareUsageBytes = 5000GB
        Invoke-QuotaScenario | Out-Null
        $script:patches[0].properties.shareQuota | Should -Be 5600
    }

    It 'explicitly skips unsupported kinds/SKUs' {
        $script:account.kind = 'BlobStorage'
        (Invoke-QuotaScenario) -join "`n" | Should -Match 'Unsupported account kind/SKU'
        $script:patches.Count | Should -Be 0
        $script:requests.Count | Should -Be 1
    }

    It 'explicitly skips NFS shares' {
        $script:shareProperties.enabledProtocols = 'NFS'
        (Invoke-QuotaScenario) -join "`n" | Should -Match 'Unsupported protocol'
        $script:patches.Count | Should -Be 0
    }

    It 'uses the default SMB protocol when the legacy response omits it' {
        $script:shareProperties.Remove('enabledProtocols')
        Invoke-QuotaScenario | Out-Null
        $script:patches.Count | Should -Be 1
    }

    It 'handles an empty account list without Azure writes' {
        $script:emptyAccountPage = $true
        (Invoke-QuotaScenario) -join "`n" | Should -Match 'No storage accounts found'
        $script:patches.Count | Should -Be 0
    }

    It 'follows pagination for both accounts and shares' {
        $script:paginate = $true
        Invoke-QuotaScenario | Out-Null
        $script:patches.Count | Should -Be 1
        @($script:requests | Where-Object { $_ -match 'page=2' }).Count | Should -Be 2
    }

    It 'rejects pagination outside the configured ARM endpoint' {
        $script:badNextLink = $true
        { Invoke-QuotaScenario } | Should -Throw '*outside the configured ARM endpoint*'
        $script:requests.Count | Should -Be 1
    }

    It 'does not treat an invalid account response as an unsupported account' {
        $script:account.Remove('sku')
        { Invoke-QuotaScenario } | Should -Throw '*Invalid account response*'
    }
}

Describe 'Runbook source validation' {
    It 'uses ASCII-only PowerShell and parses without errors' {
        foreach ($path in @($runbookPath, $PSCommandPath)) {
            [IO.File]::ReadAllText($path) | Should -Not -Match '[^\x00-\x7F]'
            $parseTokens = $null
            $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseFile($path, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
            $parseErrors.Count | Should -Be 0
        }
    }
    }
}
