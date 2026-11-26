BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptPath = Join-Path $repoRoot 'deployments\add-ons\fslogixProfileManagement\scripts\run.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "Cleanup script has $($parseErrors.Count) parse errors." }
    foreach ($definition in $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst]
    }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $entryStatements = $ast.EndBlock.Statements |
        Where-Object { $_ -isnot [Management.Automation.Language.FunctionDefinitionAst] }
    $entryPoint = [scriptblock]::Create(($entryStatements.Extent.Text -join "`n"))
    function Invoke-TestCleanupRun {
        [CmdletBinding(SupportsShouldProcess)]
        param()
        . $entryPoint
    }
    function New-TestFile {
        param(
            [string]$Name = 'Profile.vhdx',
            [long]$Size = 10,
            [string]$Access = '2020-01-01T00:00:00Z',
            [string]$Write = '2020-01-01T00:00:00Z'
        )
        $escapedName = [Security.SecurityElement]::Escape($Name)
        "<File><Name>$escapedName</Name><Properties><Content-Length>$Size</Content-Length><LastAccessTime>$Access</LastAccessTime><LastWriteTime>$Write</LastWriteTime></Properties></File>"
    }
    function New-TestDirectory {
        param([string]$Name)
        '<Directory><Name>' + [Security.SecurityElement]::Escape($Name) + '</Name></Directory>'
    }
    function Set-TestListing {
        param(
            [string]$Path = '',
            [string[]]$Entries = @(),
            [string]$NextMarker = '',
            [string]$Marker = '',
            [string]$Share = $script:testShare
        )
        $uri = $Share
        if ($Path) { $uri += '/' + $Path }
        $uri += '?restype=directory&comp=list&include=Timestamps'
        if ($Marker) { $uri += '&marker=' + [uri]::EscapeDataString($Marker) }
        $script:filePages[$uri] = '<EnumerationResults><Entries>' + ($Entries -join '') +
            '</Entries><NextMarker>' + [Security.SecurityElement]::Escape($NextMarker) + '</NextMarker></EnumerationResults>'
    }
    function Set-TestDiscovery {
        param([string]$SubscriptionId = $script:firstSubscription, [string[]]$Accounts = @('profiles'))
        $accountsUri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Storage/storageAccounts?api-version=2023-05-01"
        $script:armPages[$accountsUri] = @{
            value = @($Accounts | ForEach-Object {
                $accountId = "/subscriptions/$SubscriptionId/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/$_"
                $script:armPages["https://management.azure.com$accountId/fileServices/default/shares?api-version=2023-05-01"] = @{
                    value = @(@{ name = 'profilecontainers' })
                }
                @{ id = $accountId; name = $_; properties = @{ primaryEndpoints = @{ file = "https://$_.file.core.windows.net/" } } }
            })
        }
    }
    function New-TestHttpFailure {
        param([int]$Status, [string]$Code = '')
        $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Status)
        if ($Code) { $null = $response.Headers.TryAddWithoutValidation('x-ms-error-code', $Code) }
        $null = $response.Headers.TryAddWithoutValidation('x-ms-request-id', 'test-request')
        [Microsoft.PowerShell.Commands.HttpResponseException]::new("Simulated HTTP $Status $Code", $response)
    }
    $originalEnvironment = @{}
    foreach ($name in @('Cloud', 'SubscriptionIds', 'DeleteOlderThanDays', 'FileShareName')) {
        $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

Describe 'FSLogix profile cleanup regression coverage' {
    BeforeEach {
        $script:testShare = 'https://profiles.file.core.windows.net/profilecontainers'
        $script:firstSubscription = '11111111-1111-1111-1111-111111111111'
        $script:secondSubscription = '22222222-2222-2222-2222-222222222222'
        $script:filePages = @{}
        $script:armPages = @{}
        $script:httpFailures = @{}
        $script:requests = [Collections.Generic.List[string]]::new()
        $script:records = [Collections.Generic.List[object]]::new()
        $script:LogContext = @{}
        $script:RunId = 'test-run'
        $script:ProfileUsers = @{}
        $ResourceManagerUrl = 'https://management.azure.com/'
        $StorageAudience = 'https://storage.azure.com/'
        $cutoff = [DateTimeOffset]'2026-01-01T00:00:00Z'
        $env:Cloud = 'AzureCloud'
        $env:SubscriptionIds = $script:firstSubscription
        $env:DeleteOlderThanDays = '60'
        $env:FileShareName = 'profilecontainers'
        Mock Get-ManagedIdentityToken { 'test-token' }
        Mock Write-Information {
            param($MessageData)
            $script:records.Add(($MessageData | ConvertFrom-Json))
        }
        Mock Invoke-RestMethod {
            param($Uri)
            $key = [string]$Uri
            if (!$script:armPages.ContainsKey($key)) { throw "Unexpected ARM or Graph request: $key" }
            $script:armPages[$key]
        }
        Mock Invoke-WebRequest {
            param($Method, $Uri)
            $key = "$Method $Uri"
            $script:requests.Add($key)
            if ($script:httpFailures.ContainsKey($key)) { throw $script:httpFailures[$key] }
            if ($Method -eq 'Delete') { return }
            if (!$script:filePages.ContainsKey([string]$Uri)) { throw "Unexpected FileREST listing: $Uri" }
            @{ Content = $script:filePages[[string]$Uri] }
        }
        Set-TestDiscovery
    }

    AfterAll {
        foreach ($name in $originalEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name])
        }
    }

    It 'preserves a disk with <Activity> at or after the cutoff' -TestCases @(
        @{ Activity = 'access'; Access = '2026-01-02T00:00:00Z'; Write = '2020-01-01T00:00:00Z' }
        @{ Activity = 'writes'; Access = '2020-01-01T00:00:00Z'; Write = '2026-01-02T00:00:00Z' }
        @{ Activity = 'access exactly at cutoff'; Access = '2026-01-01T00:00:00Z'; Write = '2020-01-01T00:00:00Z' }
        @{ Activity = 'writes exactly at cutoff'; Access = '2020-01-01T00:00:00Z'; Write = '2026-01-01T00:00:00Z' }
    ) {
        param($Activity, $Access, $Write)
        Set-TestListing -Entries (New-TestFile -Access $Access -Write $Write)
        Invoke-ProfileCleanup -ShareUri $script:testShare -DeleteBefore $cutoff
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Method -eq 'Delete' }
        $snapshot = $script:records | Where-Object EventType -eq ShareInventoryCompleted
        $snapshot.ProfileCountAfter | Should -Be 1
        $snapshot.EligibleProfiles | Should -Be 0
    }

    It 'fails closed on <Kind> timestamps before deleting any part of a profile' -TestCases @(
        @{ Kind = 'missing access'; Access = ''; Write = '2020-01-01T00:00:00Z' }
        @{ Kind = 'invalid write'; Access = '2020-01-01T00:00:00Z'; Write = 'invalid' }
    ) {
        param($Kind, $Access, $Write)
        Set-TestListing -Entries (New-TestDirectory user)
        Set-TestListing -Path user -Entries @(
            (New-TestFile -Name recent.vhdx -Access '2099-01-01T00:00:00Z')
            (New-TestFile -Name unknown.vhdx -Access $Access -Write $Write)
        )
        { Invoke-TestCleanupRun } | Should -Throw '*refusing to determine expiration*'
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Method -eq 'Delete' }
        @($script:records | Where-Object EventType -eq RunFailed).Count | Should -Be 1
    }

    It 'deletes an expired profile disk before ancillary files and child directories without double-counting bytes' {
        Set-TestListing -Entries @(
            (New-TestDirectory expired)
            (New-TestFile -Name recent.vhdx -Size 50 -Access '2099-01-01T00:00:00Z')
            (New-TestFile -Name notes.txt -Size 5)
            (New-TestDirectory excluded)
            (New-TestDirectory empty)
        )
        Set-TestListing -Path expired -Entries @(
            (New-TestFile -Size 100)
            (New-TestFile -Name Merge.vhdx -Size 10 -Access '2099-01-01T00:00:00Z')
            (New-TestFile -Name RW.vhdx -Size 10 -Access '2099-01-01T00:00:00Z')
            (New-TestDirectory child)
        )
        Set-TestListing -Path expired/child -Entries (New-TestFile -Name config.txt -Size 20)
        Set-TestListing -Path excluded -Entries (New-TestFile -Name Merge.vhdx -Size 7)
        Set-TestListing -Path empty
        Invoke-TestCleanupRun
        $deletes = @($script:requests | Where-Object { $_ -like 'Delete *' })
        $deletes | Should -Be @(
            "Delete $script:testShare/expired/Profile.vhdx"
            "Delete $script:testShare/expired/Merge.vhdx"
            "Delete $script:testShare/expired/RW.vhdx"
            "Delete $script:testShare/expired/child/config.txt"
            "Delete $script:testShare/expired/child?restype=directory"
            "Delete $script:testShare/expired?restype=directory"
        )
        $snapshot = $script:records | Where-Object EventType -eq ShareInventoryCompleted
        $snapshot.ProfileCountBefore | Should -Be 2
        $snapshot.ProfileCountAfter | Should -Be 1
        $snapshot.TotalBytesBefore | Should -Be 202
        $snapshot.TotalBytesAfter | Should -Be 62
        $snapshot.DeletedBytes | Should -Be 140
        $snapshot.DeletedProfiles | Should -Be 1
        $snapshot.EligibleBytes | Should -Be 140
        $snapshot.InventoryComplete | Should -BeTrue
        ($script:records | Where-Object EventType -in @('DiskDeleted', 'FileDeleted') |
            Measure-Object SizeBytes -Sum).Sum | Should -Be 140
        @($script:records | Where-Object EventType -eq ProfileDeleted).Count | Should -Be 1
    }

    It 'retains an entire profile when a nested qualifying disk is recent' {
        Set-TestListing -Entries (New-TestDirectory user)
        Set-TestListing -Path user -Entries @((New-TestFile), (New-TestDirectory child))
        Set-TestListing -Path user/child -Entries (New-TestFile -Name other.vhd -Access '2099-01-01T00:00:00Z')
        Invoke-ProfileCleanup -ShareUri $script:testShare -DeleteBefore $cutoff
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Method -eq 'Delete' }
        ($script:records | Where-Object EventType -eq ProfileInventoried).Eligible | Should -BeFalse
    }

    It 'previews expired folders and root disks without deletion, Graph requests, or success-shaped deletion events' {
        Mock Resolve-ProfileUser { throw 'Preview must not query Graph.' }
        Set-TestListing -Entries @((New-TestDirectory user), (New-TestFile -Name root.vhdx))
        Set-TestListing -Path user -Entries (New-TestFile)
        Invoke-TestCleanupRun -WhatIf
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Method -eq 'Delete' }
        Should -Invoke Resolve-ProfileUser -Times 0
        @($script:records | Where-Object { $_.EventType -in @('ProfileDeleted', 'DiskDeleted', 'FileDeleted', 'DirectoryDeleted') }).Count |
            Should -Be 0
        $snapshot = $script:records | Where-Object EventType -eq ShareInventoryCompleted
        $snapshot.Preview | Should -BeTrue
        $snapshot.ProfileCountAfter | Should -Be 2
        $snapshot.TotalBytesAfter | Should -Be 20
        $snapshot.DeletedBytes | Should -Be 0
    }

    It 'follows opaque FileREST continuation markers and decodes encoded names once' {
        Set-TestListing -Entries (New-TestFile -Name first.vhdx) -NextMarker 'opaque+/='
        Set-TestListing -Marker 'opaque+/='
        $pageUri = $script:testShare + '?restype=directory&comp=list&include=Timestamps&marker=opaque%2B%2F%3D'
        $script:filePages[$pageUri] = '<EnumerationResults><Entries><File><Name Encoded="true">user%25.vhdx</Name><Properties><Content-Length>20</Content-Length></Properties></File></Entries><NextMarker /></EnumerationResults>'
        $ShareUri = $script:testShare
        $entries = @(Get-FileRestEntries)
        $entries.Path | Should -Be @('first.vhdx', 'user%.vhdx')
        ($entries | Measure-Object SizeBytes -Sum).Sum | Should -Be 30
        Invoke-FileRest -Method Delete -Path $entries[1].Path | Out-Null
        $script:requests[-1] | Should -Be "Delete $script:testShare/user%25.vhdx"
    }

    It 'rejects <Kind> FileREST listings rather than inventing an inventory' -TestCases @(
        @{ Kind = 'missing Entries'; Xml = '<EnumerationResults />' }
        @{ Kind = 'missing name'; Xml = '<EnumerationResults><Entries><File><Properties><Content-Length>1</Content-Length></Properties></File></Entries></EnumerationResults>' }
        @{ Kind = 'traversal name'; Xml = '<EnumerationResults><Entries><Directory><Name>..</Name></Directory></Entries></EnumerationResults>' }
        @{ Kind = 'missing size'; Xml = '<EnumerationResults><Entries><File><Name>Profile.vhdx</Name><Properties /></File></Entries></EnumerationResults>' }
        @{ Kind = 'negative size'; Xml = '<EnumerationResults><Entries><File><Name>Profile.vhdx</Name><Properties><Content-Length>-1</Content-Length></Properties></File></Entries></EnumerationResults>' }
    ) {
        param($Kind, $Xml)
        $script:filePages[$script:testShare + '?restype=directory&comp=list&include=Timestamps'] = $Xml
        { Invoke-TestCleanupRun } | Should -Throw
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Method -eq 'Delete' }
        @($script:records | Where-Object EventType -eq ShareInventoryCompleted).Count | Should -Be 0
        @($script:records | Where-Object EventType -eq RunFailed).Count | Should -Be 1
    }

    It 'follows ARM nextLink pages and rejects a continuation outside Resource Manager' {
        $firstUri = 'https://management.azure.com/resources?api-version=test'
        $nextUri = 'https://management.azure.com/resources?api-version=test&next=2'
        $script:armPages[$firstUri] = @{ value = @(@{ name = 'first' }); nextLink = $nextUri }
        $script:armPages[$nextUri] = @{ value = @(@{ name = 'second' }) }
        @(Get-ArmResources $firstUri).name | Should -Be @('first', 'second')
        $script:armPages[$firstUri].nextLink = 'https://example.invalid/resources'
        { Get-ArmResources $firstUri } | Should -Throw '*Unexpected Resource Manager discovery URL*'
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -like 'https://example.invalid/*' }
    }

    It 'continues across accounts and subscriptions after a FileREST 403 during <Operation>' -TestCases @(
        @{ Operation = 'listing'; Method = 'Get'; Preview = $false }
        @{ Operation = 'deletion'; Method = 'Delete'; Preview = $false }
        @{ Operation = 'preview listing'; Method = 'Get'; Preview = $true }
    ) {
        param($Operation, $Method, $Preview)
        $env:SubscriptionIds = "$script:firstSubscription,$script:secondSubscription"
        Set-TestDiscovery -Accounts @('denied', 'profiles')
        Set-TestDiscovery -SubscriptionId $script:secondSubscription -Accounts @('other')
        foreach ($account in @('denied', 'profiles', 'other')) {
            Set-TestListing -Share "https://$account.file.core.windows.net/profilecontainers" -Entries (New-TestFile)
        }
        $failedUri = 'https://denied.file.core.windows.net/profilecontainers'
        $failedUri += if ($Method -eq 'Get') { '?restype=directory&comp=list&include=Timestamps' } else { '/Profile.vhdx' }
        $script:httpFailures["$Method $failedUri"] = New-TestHttpFailure 403
        Invoke-TestCleanupRun -WhatIf:$Preview
        $denial = $script:records | Where-Object { $_.EventType -eq 'AccountSkipped' -and $_.Level -eq 'Error' }
        $denial.StorageAccount | Should -Be denied
        $denial.SubscriptionId | Should -Be $script:firstSubscription
        $denial.Message | Should -Match '403'
        @($script:records | Where-Object { $_.EventType -eq 'ShareCleanupCompleted' }).StorageAccount |
            Should -Be @('profiles', 'other')
        @($script:records | Where-Object EventType -eq RunCompleted).Count | Should -Be 1
        @($script:records | Where-Object EventType -eq RunFailed).Count | Should -Be 0
        if ($Preview) { Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Method -eq 'Delete' } }
    }

    It 'skips a profile after <Code> during <Operation> and processes the next root disk' -TestCases @(
        @{ Code = 'SharingViolation'; Operation = 'disk deletion'; Method = 'Delete'; Suffix = '/user/Profile.vhdx'; Complete = $true; BytesDeleted = 10 }
        @{ Code = 'DirectoryNotEmpty'; Operation = 'folder deletion'; Method = 'Delete'; Suffix = '/user?restype=directory'; Complete = $true; BytesDeleted = 20 }
        @{ Code = 'SharingViolation'; Operation = 'inventory'; Method = 'Get'; Suffix = '/user?restype=directory&comp=list&include=Timestamps'; Complete = $false; BytesDeleted = 10 }
    ) {
        param($Code, $Operation, $Method, $Suffix, $Complete, $BytesDeleted)
        Set-TestListing -Entries @((New-TestDirectory user), (New-TestFile -Name next.vhdx))
        Set-TestListing -Path user -Entries (New-TestFile)
        $script:httpFailures["$Method $script:testShare$Suffix"] = New-TestHttpFailure 409 $Code
        Invoke-TestCleanupRun
        $skipped = $script:records | Where-Object EventType -eq ProfileSkipped
        $skipped.ProfileFolder | Should -Be user
        $skipped.Level | Should -Be Warning
        $skipped.Message | Should -Match $Code
        $skipped.Message | Should -Match 'test-request'
        @($script:records | Where-Object EventType -eq ProfileDeleted).Count | Should -Be 0
        @($script:records | Where-Object { $_.EventType -eq 'DiskDeleted' -and $_.Path -eq 'next.vhdx' }).Count | Should -Be 1
        $snapshot = $script:records | Where-Object EventType -eq ShareInventoryCompleted
        $snapshot.InventoryComplete | Should -Be $Complete
        $snapshot.DeletedBytes | Should -Be $BytesDeleted
    }

    It 'records only successful partial deletions and leaves ancillary files untouched after a locked disk' {
        Set-TestListing -Entries (New-TestDirectory user)
        Set-TestListing -Path user -Entries @(
            (New-TestFile -Name first.vhdx -Size 10)
            (New-TestFile -Name locked.vhdx -Size 20)
            (New-TestFile -Name config.txt -Size 5)
        )
        $script:httpFailures["Delete $script:testShare/user/locked.vhdx"] = New-TestHttpFailure 409 SharingViolation
        Invoke-TestCleanupRun
        @($script:requests | Where-Object { $_ -like 'Delete *' }) | Should -Be @(
            "Delete $script:testShare/user/first.vhdx"
            "Delete $script:testShare/user/locked.vhdx"
        )
        @($script:records | Where-Object EventType -eq DiskDeleted).Count | Should -Be 1
        @($script:records | Where-Object EventType -eq ProfileDeleted).Count | Should -Be 0
        $snapshot = $script:records | Where-Object EventType -eq ShareInventoryCompleted
        $snapshot.DeletedBytes | Should -Be 10
        $snapshot.TotalBytesAfter | Should -Be 25
        $snapshot.ProfileCountAfter | Should -Be 1
    }

    It 'skips a locked root disk without attempting to remove the share root' {
        Set-TestListing -Entries @((New-TestFile -Name locked.vhdx), (New-TestFile -Name next.vhdx))
        $script:httpFailures["Delete $script:testShare/locked.vhdx"] = New-TestHttpFailure 409 SharingViolation
        Invoke-TestCleanupRun
        ($script:records | Where-Object EventType -eq ProfileSkipped).ItemType | Should -Be File
        ($script:records | Where-Object EventType -eq DiskDeleted).Path | Should -Be next.vhdx
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Method -eq 'Delete' -and $Uri -eq $script:testShare }
    }

    It 'stops and emits RunFailed for an unrecognized HTTP <Status> failure' -TestCases @(
        @{ Status = 409; Code = 'LeaseIdMissing' }
        @{ Status = 500; Code = 'InternalError' }
    ) {
        param($Status, $Code)
        Set-TestListing -Entries @((New-TestFile -Name first.vhdx), (New-TestFile -Name next.vhdx))
        $script:httpFailures["Delete $script:testShare/first.vhdx"] = New-TestHttpFailure $Status $Code
        { Invoke-TestCleanupRun } | Should -Throw "*Simulated HTTP $Status*"
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Method -eq 'Delete' -and $Uri -like '*/next.vhdx' }
        @($script:records | Where-Object EventType -eq RunFailed).Count | Should -Be 1
        @($script:records | Where-Object EventType -eq RunCompleted).Count | Should -Be 0
        @($script:records | Where-Object EventType -eq ShareInventoryCompleted).Count | Should -Be 0
    }

    It 'surfaces ARM and managed-identity failures instead of treating them as account skips' -TestCases @(
        @{ Failure = 'ARM' }
        @{ Failure = 'identity' }
    ) {
        param($Failure)
        if ($Failure -eq 'ARM') { Mock Invoke-RestMethod { throw 'ARM unavailable' } }
        else { Mock Get-ManagedIdentityToken { throw 'identity unavailable' } }
        { Invoke-TestCleanupRun } | Should -Throw "*$Failure unavailable*"
        Should -Invoke Invoke-WebRequest -Times 0
        @($script:records | Where-Object EventType -eq RunFailed).Count | Should -Be 1
        @($script:records | Where-Object EventType -eq AccountSkipped).Count | Should -Be 0
    }

    It 'validates the entire subscription list before any discovery or deletion' {
        $env:SubscriptionIds = "$script:firstSubscription,not-a-guid"
        { Invoke-TestCleanupRun } | Should -Throw '*Invalid subscription GUID*'
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        @($script:records | Where-Object EventType -eq RunFailed).Count | Should -Be 1
    }

    It 'cleans only the configured share and logs its actual name and URI' {
        $env:FileShareName = 'custom-profiles'
        $script:testShare = 'https://profiles.file.core.windows.net/custom-profiles'
        $sharesUri = "https://management.azure.com/subscriptions/$script:firstSubscription/resourceGroups/test/providers/Microsoft.Storage/storageAccounts/profiles/fileServices/default/shares?api-version=2023-05-01"
        $script:armPages[$sharesUri].value = @(
            @{ name = 'profilecontainers' }
            @{ name = 'custom-profiles-old' }
            @{ name = 'Custom-Profiles' }
            @{ name = 'custom-profiles' }
        )
        Set-TestListing -Entries (New-TestFile)
        Invoke-TestCleanupRun
        @($script:requests | Where-Object { $_ -like 'Delete *' }) | Should -Be @(
            "Delete $script:testShare/Profile.vhdx"
        )
        $completed = $script:records | Where-Object EventType -eq ShareCleanupCompleted
        $completed.ShareName | Should -Be 'custom-profiles'
        $completed.ShareUri | Should -Be $script:testShare
    }

    It 'skips accounts without the configured share instead of falling back to profilecontainers' {
        $env:FileShareName = 'custom-profiles'
        Invoke-TestCleanupRun
        Should -Invoke Invoke-WebRequest -Times 0
        ($script:records | Where-Object EventType -eq AccountSkipped).Message | Should -Be "No 'custom-profiles' share"
        @($script:records | Where-Object EventType -eq RunCompleted).Count | Should -Be 1
    }

    It 'rejects <Kind> share names before any requests' -TestCases @(
        @{ Kind = 'missing'; Name = $null }
        @{ Kind = 'blank'; Name = ' ' }
        @{ Kind = 'too short'; Name = 'ab' }
        @{ Kind = 'too long'; Name = ('a' * 64) }
        @{ Kind = 'uppercase'; Name = 'Profiles' }
        @{ Kind = 'consecutive hyphens'; Name = 'my--profiles' }
        @{ Kind = 'leading hyphen'; Name = '-profiles' }
        @{ Kind = 'trailing hyphen'; Name = 'profiles-' }
        @{ Kind = 'path'; Name = 'profiles/other' }
        @{ Kind = 'trailing newline'; Name = "profiles`n" }
    ) {
        param($Kind, $Name)
        $env:FileShareName = $Name
        { Invoke-TestCleanupRun } | Should -Throw '*FileShareName must*'
        Should -Invoke Invoke-RestMethod -Times 0
        Should -Invoke Invoke-WebRequest -Times 0
        @($script:records | Where-Object EventType -eq RunFailed).Count | Should -Be 1
    }

    It 'trims and deduplicates subscription IDs before discovering shares' {
        $env:SubscriptionIds = " $script:firstSubscription ,$script:firstSubscription"
        Set-TestListing
        Invoke-TestCleanupRun
        @($script:records | Where-Object EventType -eq SubscriptionStarted).Count | Should -Be 1
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -match '/providers/Microsoft\.Storage/storageAccounts\?' }
    }

    Describe 'FSLogix profile share deployment contract' {
        It 'passes the Portal share name through the deployment parameter to the Function App setting' {
            $addonPath = Join-Path $repoRoot 'deployments\add-ons\fslogixProfileManagement'
            $template = Get-Content -LiteralPath (Join-Path $addonPath 'main.json') -Raw | ConvertFrom-Json
            $form = Get-Content -LiteralPath (Join-Path $addonPath 'uiFormDefinition.json') -Raw | ConvertFrom-Json
            $settings = ($form.view.properties.steps | Where-Object name -eq script).elements |
                Where-Object name -eq settings
            $control = $settings.elements | Where-Object name -eq fileShareName
            $control.defaultValue | Should -Be $template.parameters.fileShareName.defaultValue
            $template.parameters.fileShareName.defaultValue | Should -Be 'profilecontainers'
            $form.view.outputs.parameters.fileShareName | Should -Be "[steps('script').settings.fileShareName]"
            $module = $template.resources.functionApp
            ($module.properties.parameters.functionAppAppSettings.value | Where-Object name -eq FileShareName).value |
                Should -Be "[parameters('fileShareName')]"
        }
    }

    It 'warns on Graph failure but preserves the SID and completes an approved deletion' {
        $sid = 'S-1-5-21-1-2-3-1001'
        Set-TestListing -Entries (New-TestDirectory $sid)
        Set-TestListing -Path $sid -Entries (New-TestFile)
        Mock Invoke-RestMethod { throw 'Graph permission denied' } -ParameterFilter { $Uri -like 'https://graph.microsoft.com/*' }
        Invoke-TestCleanupRun
        $warning = $script:records | Where-Object EventType -eq UserLookupFailed
        $warning.Level | Should -Be Warning
        $warning.Message | Should -Match 'Graph permission denied'
        $deleted = $script:records | Where-Object EventType -eq ProfileDeleted
        $deleted.UserSid | Should -Be $sid
        $deleted.UserLookupStatus | Should -Be Failed
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like 'https://graph.microsoft.com/*' }
        @($script:records | Where-Object EventType -eq RunCompleted).Count | Should -Be 1
    }
}
