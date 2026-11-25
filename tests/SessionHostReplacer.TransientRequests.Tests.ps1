BeforeAll {
    $corePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.Core.psm1'
    Import-Module $corePath -Force
}

AfterAll { Remove-Module SessionHostReplacer.Core -Force }

Describe 'SHR recovery and image batch structured observability' {
    BeforeEach {
        Clear-ShrLogContext
        $global:shrRecoveryTelemetryMessages = @()
        $script:recoveryTelemetryState = @{
            Id = ('a' * 32)
            Status = 'Running'
            BatchNumber = 2
            ExpansionBlocked = $false
            LastProgressUtc = '2026-11-25T01:00:00Z'
            ProgressTimeoutHours = 24
            ScheduleWaitStartedUtc = '2026-11-25T02:00:00Z'
            AwaitingImageBatch = $false
            LastImageChangeRequestId = ('b' * 32)
            LastImageChangeRejectedId = ('c' * 32)
            LastError = 'SECRET-ERROR'
            ImageChangeError = 'SECRET-IMAGE-ERROR'
            PendingImageChangeRequestId = 'SECRET-PENDING-ID'
            UnrecognizedState = @{ Password = 'SECRET-PASSWORD' }
        }
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Core { $true }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Core {
            param($Message)
            $global:shrRecoveryTelemetryMessages += $Message
        }
    }
    AfterEach {
        Clear-ShrLogContext
        Remove-Variable shrRecoveryTelemetryMessages -Scope Global
    }

    It 'reports expansion-blocked Running as recovery rather than ordinary <EventName>' -TestCases @(
        @{ EventName = 'Progress' }
        @{ EventName = 'Waiting' }
        @{ EventName = 'ProgressStalled' }
        @{ EventName = 'Checkpoint' }
    ) {
        param($EventName)
        $script:recoveryTelemetryState.ExpansionBlocked = $true
        $script:recoveryTelemetryState.AwaitingImageBatch = $true
        Write-ShrEvent -Event $EventName -State $script:recoveryTelemetryState -Metrics @{
            RunningDeployments = 1; InDrain = 2; NewHostsSafeToProceed = $false
        }
        $data = ($global:shrRecoveryTelemetryMessages[-1] -split ' \| ', 2)[1] | ConvertFrom-Json
        $data.SchemaVersion | Should -Be 1
        $data.Event | Should -Be $EventName
        $data.Status | Should -Be 'Running'
        $data.Phase | Should -Be 'ExpansionBlockedRecovery'
        $data.Reason | Should -Be 'New expansion is blocked after the no-progress threshold; checkpointed recovery continues.'
        $data.ExpansionBlocked | Should -BeTrue
        $data.AwaitingImageBatch | Should -BeTrue
    }

    It 'identifies fresh image-batch authority waits for <EventName>' -TestCases @(
        @{ EventName = 'Progress' }
        @{ EventName = 'Waiting' }
        @{ EventName = 'ImageTargetChanged' }
    ) {
        param($EventName)
        $script:recoveryTelemetryState.AwaitingImageBatch = $true
        Write-ShrEvent -Event $EventName -State $script:recoveryTelemetryState -Metrics @{ InDrain = 2 }
        $data = ($global:shrRecoveryTelemetryMessages[-1] -split ' \| ', 2)[1] | ConvertFrom-Json
        $data.Phase | Should -Be 'WaitingForImageBatchAuthorization'
        $data.Reason | Should -Be 'The approved image target requires fresh scheduled initiation authority before its next batch can start.'
        $data.Status | Should -Be 'Running'
        $data.ExpansionBlocked | Should -BeFalse
        $data.AwaitingImageBatch | Should -BeTrue
    }

    It 'retains terminal status precedence for <Status>' -TestCases @(
        @{ Status = 'Completed' }
        @{ Status = 'NeedsAttention' }
        @{ Status = 'Superseded' }
    ) {
        param($Status)
        $script:recoveryTelemetryState.Status = $Status
        $script:recoveryTelemetryState.ExpansionBlocked = $true
        $script:recoveryTelemetryState.AwaitingImageBatch = $true
        Write-ShrEvent -Event Progress -State $script:recoveryTelemetryState
        $data = ($global:shrRecoveryTelemetryMessages[-1] -split ' \| ', 2)[1] | ConvertFrom-Json
        $data.Phase | Should -Be $Status
    }

    It 'emits only explicitly allowlisted scalar recovery fields without IDs in Reason' {
        $script:recoveryTelemetryState.ExpansionBlocked = $true
        Write-ShrEvent -Event Progress -State $script:recoveryTelemetryState
        $text = $global:shrRecoveryTelemetryMessages[-1]
        $data = ($text -split ' \| ', 2)[1] | ConvertFrom-Json
        $text | Should -Match '"LastProgressUtc":"2026-11-25T01:00:00Z"'
        $data.ProgressTimeoutHours | Should -Be 24
        $text | Should -Match '"ScheduleWaitStartedUtc":"2026-11-25T02:00:00Z"'
        $data.LastImageChangeRequestId | Should -Be ('b' * 32)
        $data.LastImageChangeRejectedId | Should -Be ('c' * 32)
        $data.Reason | Should -Not -Match '[abc]{32}|SECRET'
        $text | Should -Not -Match 'SECRET|LastError|ImageChangeError|PendingImageChangeRequestId|UnrecognizedState|Password'
        $data.ExpansionBlocked | Should -BeOfType [bool]
        $data.ProgressTimeoutHours | Should -BeOfType [long]
        $data.AwaitingImageBatch | Should -BeOfType [bool]
    }

    It 'leaves ordinary Running phase selection intact without recovery flags' {
        Write-ShrEvent -Event Progress -State $script:recoveryTelemetryState -Metrics @{ InDrain = 2 }
        $data = ($global:shrRecoveryTelemetryMessages[-1] -split ' \| ', 2)[1] | ConvertFrom-Json
        $data.Phase | Should -Be 'Draining'
        $data.ExpansionBlocked | Should -BeFalse
        $data.AwaitingImageBatch | Should -BeFalse
    }
}

Describe 'SHR typed transient failure evidence' {
    It 'classifies HTTP <Status> as transient=<Expected> without losing status evidence' -TestCases @(
        @{ Status = 408; Expected = $true }
        @{ Status = 429; Expected = $true }
        @{ Status = 500; Expected = $true }
        @{ Status = 502; Expected = $true }
        @{ Status = 503; Expected = $true }
        @{ Status = 504; Expected = $true }
        @{ Status = 400; Expected = $false }
        @{ Status = 401; Expected = $false }
        @{ Status = 403; Expected = $false }
        @{ Status = 404; Expected = $false }
        @{ Status = 409; Expected = $false }
        @{ Status = 501; Expected = $false }
    ) {
        param($Status, $Expected)
        $exception = [Exception]::new('HTTP failure; no status in message.')
        $exception | Add-Member Response ([pscustomobject]@{ StatusCode = [Net.HttpStatusCode]$Status })
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'http', 'NotSpecified', $null)
        Get-ShrHttpStatusCode -ErrorRecord $record | Should -Be $Status
        Test-ShrTransientFailure -ErrorRecord $record | Should -Be $Expected
        [int]$record.Exception.Response.StatusCode | Should -Be $Status
    }

    It 'accepts typed <Kind> failures including relevant inner exceptions' -TestCases @(
        @{ Kind = 'Http' }
        @{ Kind = 'Timeout' }
        @{ Kind = 'Canceled' }
        @{ Kind = 'WebTimeout' }
        @{ Kind = 'WebConnect' }
        @{ Kind = 'Inner' }
        @{ Kind = 'Aggregate' }
    ) {
        param($Kind)
        $exception = switch ($Kind) {
            Http { [Net.Http.HttpRequestException]::new('transport') }
            Timeout { [TimeoutException]::new('transport') }
            Canceled { [Threading.Tasks.TaskCanceledException]::new('transport') }
            WebTimeout { [Net.WebException]::new('transport', [Net.WebExceptionStatus]::Timeout) }
            WebConnect { [Net.WebException]::new('transport', [Net.WebExceptionStatus]::ConnectFailure) }
            Inner { [Exception]::new('wrapper', [Net.Http.HttpRequestException]::new('transport')) }
            Aggregate { [AggregateException]::new('wrapper', [TimeoutException]::new('transport')) }
        }
        Test-ShrTransientFailure $exception | Should -BeTrue
        Get-ShrHttpStatusCode $exception | Should -BeNullOrEmpty
    }

    It 'rejects arbitrary strings and nontransport exception <Kind>' -TestCases @(
        @{ Kind = 'String' }
        @{ Kind = 'Exception' }
        @{ Kind = 'IO' }
        @{ Kind = 'Argument' }
        @{ Kind = 'Canceled' }
        @{ Kind = 'WebTrust' }
        @{ Kind = 'WebProtocol' }
    ) {
        param($Kind)
        $failure = switch ($Kind) {
            String { 'HTTP 503 timeout connection reset' }
            Exception { [Exception]::new('HTTP 503 timeout connection reset') }
            IO { [IO.IOException]::new('HTTP 503 timeout connection reset') }
            Argument { [ArgumentException]::new('timeout') }
            Canceled { [OperationCanceledException]::new('canceled by caller') }
            WebTrust { [Net.WebException]::new('certificate', [Net.WebExceptionStatus]::TrustFailure) }
            WebProtocol { [Net.WebException]::new('HTTP 503', [Net.WebExceptionStatus]::ProtocolError) }
        }
        Test-ShrTransientFailure $failure | Should -BeFalse
        Get-ShrHttpStatusCode $failure | Should -BeNullOrEmpty
    }

    It 'gives permanent HTTP status precedence over transport wrappers' {
        $inner = [Net.Http.HttpRequestException]::new('permanent', $null, [Net.HttpStatusCode]::Forbidden)
        $exception = [TimeoutException]::new('wrapper', $inner)
        Get-ShrHttpStatusCode -Exception $exception | Should -Be 403
        Test-ShrTransientFailure -Exception $exception | Should -BeFalse
    }

    It 'does not let a transient aggregate sibling conceal permanent HTTP evidence' {
        $exception = [AggregateException]::new([Exception[]]@(
            [TimeoutException]::new('transient'),
            [Net.Http.HttpRequestException]::new('permanent', $null, [Net.HttpStatusCode]::BadRequest)
        ))
        Test-ShrTransientFailure $exception | Should -BeFalse
    }

    It 'honors storage status evidence in exception Data for HTTP <Status>' -TestCases @(
        @{ Status = 429; Expected = $true }
        @{ Status = 503; Expected = $true }
        @{ Status = 403; Expected = $false }
        @{ Status = 409; Expected = $false }
    ) {
        param($Status, $Expected)
        $exception = [InvalidOperationException]::new('storage operation failed')
        $exception.Data['StatusCode'] = $Status
        $record = [System.Management.Automation.ErrorRecord]::new($exception, 'storage', 'NotSpecified', $null)
        Get-ShrHttpStatusCode -ErrorRecord $record | Should -Be $Status
        Test-ShrTransientFailure -ErrorRecord $record | Should -Be $Expected
    }

    It 'never classifies marked ownership conflicts as transient even with inner transport errors' {
        $exception = [InvalidOperationException]::new('ownership lost', [TimeoutException]::new('transport'))
        $exception.Data['ShrOwnershipConflict'] = $true
        $exception.Data['StatusCode'] = 503
        Test-ShrTransientFailure -ErrorRecord $exception | Should -BeFalse
        $wrapper = [TimeoutException]::new('outer transport', $exception)
        Test-ShrTransientFailure -ErrorRecord $wrapper | Should -BeFalse
        Get-ShrHttpStatusCode -ErrorRecord $exception | Should -Be 503
    }
}

Describe 'SHR bounded requests through normal ARM and Graph helpers' {
    BeforeAll {
        InModuleScope SessionHostReplacer.Core {
            function script:Assert-ShrWorkerLease {}
        }
    }
    BeforeEach {
        $global:shrTransientRequest = @{
            Calls = @()
            Sleeps = @()
            Logs = @()
            Failure = [Net.Http.HttpRequestException]::new('original transport failure')
            Failures = 1
            LeaseChecks = 0
            LoseOnCheck = 0
            NextPage = $false
            InvalidCollection = $false
        }
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Core { 'test-pool' }
        Mock Get-AccessToken -ModuleName SessionHostReplacer.Core { 'dod-token' }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Core {
            param($Message, $Level)
            $global:shrTransientRequest.Logs += @{ Message = $Message; Level = $Level }
        }
        Mock Start-Sleep -ModuleName SessionHostReplacer.Core {
            param($Seconds)
            $global:shrTransientRequest.Sleeps += $Seconds
        }
        Mock Assert-ShrWorkerLease -ModuleName SessionHostReplacer.Core {
            $global:shrTransientRequest.LeaseChecks++
            if ($global:shrTransientRequest.LoseOnCheck -eq $global:shrTransientRequest.LeaseChecks) {
                throw [InvalidOperationException]::new('ownership or invocation budget lost')
            }
        }
        Mock Invoke-RestMethod -ModuleName SessionHostReplacer.Core {
            param($Uri, $Method, $TimeoutSec, $ConnectionTimeoutSeconds, $OperationTimeoutSeconds)
            $state = $global:shrTransientRequest
            $timeout = if ($null -ne $ConnectionTimeoutSeconds) { $ConnectionTimeoutSeconds } else { $TimeoutSec }
            $state.Calls += @{ Uri = $Uri; Method = $Method; Timeout = $timeout; OperationTimeout = $OperationTimeoutSeconds }
            if ($state.Calls.Count -le $state.Failures) { throw $state.Failure }
            if ($state.InvalidCollection) { return @{ unexpected = 'not a collection' } }
            if ($state.NextPage -and $Uri -notlike '*page=2*') {
                return [pscustomobject]@{ value = @('first'); nextLink = 'https://management.example.test/items?page=2' }
            }
            return [pscustomobject]@{ value = @('success') }
        }
    }
    AfterEach { Remove-Variable shrTransientRequest -Scope Global }
    AfterAll {
        InModuleScope SessionHostReplacer.Core {
            Remove-Item Function:\Assert-ShrWorkerLease
        }
    }

    It 'retries GET once and succeeds through <Helper>' -TestCases @(
        @{ Helper = 'ARM' }
        @{ Helper = 'ARMWrapper' }
        @{ Helper = 'Graph' }
        @{ Helper = 'GraphWrapper' }
    ) {
        param($Helper)
        $result = switch ($Helper) {
            ARM { Invoke-AzureRestMethod -ARMToken test-token -Uri 'https://management.example.test/items' }
            ARMWrapper { Invoke-AzureRestMethodWithRetry -ARMToken test-token -Method Get -Uri 'https://management.example.test/items' }
            Graph { Invoke-GraphRestMethod -GraphToken test-token -Method Get -Uri 'https://graph.microsoft.com/v1.0/devices' }
            GraphWrapper { Invoke-GraphApiWithRetry -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token -Method Get -Uri '/v1.0/devices' -ClientId test-client }
        }
        $global:shrTransientRequest.Calls.Count | Should -Be 2
        $global:shrTransientRequest.Sleeps | Should -HaveCount 1
        $global:shrTransientRequest.Sleeps[0] | Should -Be 1
        $global:shrTransientRequest.Calls[0].Timeout | Should -BeGreaterThan 0
        $global:shrTransientRequest.Calls[0].Timeout | Should -BeLessOrEqual 10
        if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('OperationTimeoutSeconds')) {
            $global:shrTransientRequest.Calls[0].OperationTimeout | Should -Be $global:shrTransientRequest.Calls[0].Timeout
        }
        $result | Should -Not -BeNullOrEmpty
    }

    It 'never replays transient <Method> through <Helper>' -TestCases @(
        foreach ($helper in @('ARM', 'ARMWrapper', 'Graph', 'GraphWrapper')) {
            foreach ($method in @('Post', 'Put', 'Patch', 'Delete')) {
                @{ Helper = $helper; Method = $method }
            }
        }
    ) {
        param($Helper, $Method)
        $failure = $null
        try {
            switch ($Helper) {
                ARM { Invoke-AzureRestMethod -ARMToken test-token -Method $Method -Uri 'https://management.example.test/items' }
                ARMWrapper { Invoke-AzureRestMethodWithRetry -ARMToken test-token -Method $Method -Uri 'https://management.example.test/items' }
                Graph { Invoke-GraphRestMethod -GraphToken test-token -Method $Method -Uri 'https://graph.microsoft.com/v1.0/devices' }
                GraphWrapper { Invoke-GraphApiWithRetry -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token -Method $Method -Uri '/v1.0/devices' -ClientId test-client }
            }
        } catch { $failure = $_ }
        [object]::ReferenceEquals($failure.Exception, $global:shrTransientRequest.Failure) | Should -BeTrue
        $global:shrTransientRequest.Calls.Count | Should -Be 1
        $global:shrTransientRequest.Sleeps | Should -HaveCount 0
    }

    It 'caps total GET attempts without nesting the legacy wrapper retry loop' {
        $global:shrTransientRequest.Failures = 100
        {
            Invoke-AzureRestMethodWithRetry -ARMToken test-token -Method Get -Uri 'https://management.example.test/items' -MaxRetries 100
        } | Should -Throw '*original transport failure*'
        $global:shrTransientRequest.Calls.Count | Should -Be 3
        $global:shrTransientRequest.Sleeps | Should -HaveCount 2
        @($global:shrTransientRequest.Logs | Where-Object { $_.Level -eq 'Error' -and $_.Message -like '*retries exhausted*' }).Count | Should -Be 1
    }

    It 'honors an explicit single-attempt GET budget' {
        {
            Invoke-AzureRestMethodWithRetry -ARMToken test-token -Method Get -Uri 'https://management.example.test/items' -MaxRetries 1
        } | Should -Throw '*original transport failure*'
        $global:shrTransientRequest.Calls.Count | Should -Be 1
        $global:shrTransientRequest.Sleeps | Should -HaveCount 0
    }

    It 'honors bounded Retry-After <Seconds> without retrying before the server allows' -TestCases @(
        @{ Seconds = 3; Attempts = 2; Sleeps = 1 }
        @{ Seconds = 60; Attempts = 1; Sleeps = 0 }
    ) {
        param($Seconds, $Attempts, $Sleeps)
        $exception = [Exception]::new('throttled')
        $exception | Add-Member Response ([pscustomobject]@{
            StatusCode = 429; Headers = @{ 'Retry-After' = [string]$Seconds }
        })
        $global:shrTransientRequest.Failure = $exception
        try { Invoke-AzureRestMethod -ARMToken test-token -Uri 'https://management.example.test/items' | Out-Null }
        catch { [object]::ReferenceEquals($_.Exception, $exception) | Should -BeTrue }
        $global:shrTransientRequest.Calls.Count | Should -Be $Attempts
        $global:shrTransientRequest.Sleeps | Should -HaveCount $Sleeps
        if ($Sleeps) { $global:shrTransientRequest.Sleeps[0] | Should -Be $Seconds }
    }

    It 'honors typed HTTP response Retry-After dates beyond the local budget by deferring' {
        $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::ServiceUnavailable)
        try {
            $response.Headers.RetryAfter = [Net.Http.Headers.RetryConditionHeaderValue]::new([DateTimeOffset]::UtcNow.AddMinutes(1))
            $exception = [Exception]::new('unavailable')
            $exception | Add-Member Response $response
            $global:shrTransientRequest.Failure = $exception
            { Invoke-AzureRestMethod -ARMToken test-token -Uri 'https://management.example.test/items' } | Should -Throw '*unavailable*'
            $global:shrTransientRequest.Calls.Count | Should -Be 1
            $global:shrTransientRequest.Sleeps | Should -HaveCount 0
        } finally { $response.Dispose() }
    }

    It 'does not retry after ownership or invocation budget checks fail at check <Check>' -TestCases @(
        @{ Check = 1; Sleeps = 0 }
        @{ Check = 2; Sleeps = 1 }
    ) {
        param($Check, $Sleeps)
        $global:shrTransientRequest.LoseOnCheck = $Check
        { Invoke-AzureRestMethod -ARMToken test-token -Uri 'https://management.example.test/items' } | Should -Throw '*ownership or invocation budget lost*'
        $global:shrTransientRequest.Calls.Count | Should -Be 1
        $global:shrTransientRequest.Sleeps | Should -HaveCount $Sleeps
    }

    It 'never retries permanent HTTP failures' {
        $exception = [Net.Http.HttpRequestException]::new('forbidden', $null, [Net.HttpStatusCode]::Forbidden)
        $global:shrTransientRequest.Failure = $exception
        { Invoke-AzureRestMethod -ARMToken test-token -Uri 'https://management.example.test/items' } | Should -Throw '*forbidden*'
        $global:shrTransientRequest.Calls.Count | Should -Be 1
    }

    It 'retains GCCH-to-DoD authentication fallback through <Helper>' -TestCases @(
        @{ Helper = 'Graph' }
        @{ Helper = 'GraphWrapper' }
    ) {
        param($Helper)
        $global:shrTransientRequest.Failure = [Net.Http.HttpRequestException]::new('forbidden', $null, [Net.HttpStatusCode]::Forbidden)
        if ($Helper -eq 'Graph') {
            Invoke-GraphRestMethod -GraphToken test-token -Method Delete -Uri 'https://graph.microsoft.us/v1.0/devices/old-id' | Out-Null
        } else {
            Invoke-GraphApiWithRetry -GraphEndpoint 'https://graph.microsoft.us' -GraphToken test-token -Method Delete -Uri '/v1.0/devices/old-id' -ClientId test-client | Out-Null
        }
        $global:shrTransientRequest.Calls.Count | Should -Be 2
        $global:shrTransientRequest.Calls[1].Uri | Should -Be 'https://dod-graph.microsoft.us/v1.0/devices/old-id'
        $global:shrTransientRequest.Sleeps | Should -HaveCount 0
        $global:shrTransientRequest.LeaseChecks | Should -Be 2
        Should -Invoke Get-AccessToken -ModuleName SessionHostReplacer.Core -Times 1 -Exactly
    }

    It 'does not retry or hide malformed collection envelopes' {
        $global:shrTransientRequest.Failures = 0
        $global:shrTransientRequest.InvalidCollection = $true
        { Invoke-AzureRestMethod -ARMToken test-token -Uri 'https://management.example.test/items' -RequireCollection } | Should -Throw '*Invalid collection response*'
        $global:shrTransientRequest.Calls.Count | Should -Be 1
    }

    It 'retries a failing page without replaying successful collection pages' {
        $global:shrTransientRequest.Failures = 0
        $global:shrTransientRequest.NextPage = $true
        Mock Invoke-RestMethod -ModuleName SessionHostReplacer.Core {
            param($Uri)
            $state = $global:shrTransientRequest
            $state.Calls += @{ Uri = $Uri }
            if ($state.Calls.Count -eq 1) {
                return [pscustomobject]@{ value = @('first'); nextLink = 'https://management.example.test/items?page=2' }
            }
            if ($state.Calls.Count -eq 2) { throw $state.Failure }
            return [pscustomobject]@{ value = @('second') }
        }
        $result = @(Invoke-AzureRestMethod -ARMToken test-token -Uri 'https://management.example.test/items' -RequireCollection)
        $result | Should -HaveCount 2
        $result[0] | Should -Be 'first'
        $result[1] | Should -Be 'second'
        $global:shrTransientRequest.Calls.Count | Should -Be 3
        $global:shrTransientRequest.Calls[1].Uri | Should -Be $global:shrTransientRequest.Calls[2].Uri
    }
}

Describe 'SHR error logging preserves the original request exception' {
    BeforeEach {
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Core { 'test-pool' }
        Mock Start-Sleep -ModuleName SessionHostReplacer.Core {}
        $global:shrOriginalFailure = [Net.Http.HttpRequestException]::new('original failure', $null, [Net.HttpStatusCode]::ServiceUnavailable)
        Mock Invoke-RestMethod -ModuleName SessionHostReplacer.Core { throw $global:shrOriginalFailure }
    }
    AfterEach { Remove-Variable shrOriginalFailure -Scope Global }

    It 'writes a nonterminating error even with ErrorActionPreference Stop' {
        $ErrorActionPreference = 'Stop'
        $errors = @()
        Write-LogEntry -Message 'logged failure' -Level Error -ErrorVariable +errors 2>$null
        $errors | Should -HaveCount 1
        $errors[0].Exception.Message | Should -Be '[test-pool] logged failure'
    }

    It 'preserves exception identity and status after exhausted <Helper> retries under Stop' -TestCases @(
        @{ Helper = 'ARM' }
        @{ Helper = 'Graph' }
        @{ Helper = 'GraphWrapper' }
    ) {
        param($Helper)
        $ErrorActionPreference = 'Stop'
        $failure = $null
        try {
            switch ($Helper) {
                ARM { Invoke-AzureRestMethod -ARMToken test-token -Uri 'https://management.example.test/items' 2>$null }
                Graph { Invoke-GraphRestMethod -GraphToken test-token -Method Get -Uri 'https://graph.microsoft.com/v1.0/devices' 2>$null }
                GraphWrapper { Invoke-GraphApiWithRetry -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token -Method Get -Uri '/v1.0/devices' -ClientId test-client 2>$null }
            }
        } catch { $failure = $_ }
        [object]::ReferenceEquals($failure.Exception, $global:shrOriginalFailure) | Should -BeTrue
        Get-ShrHttpStatusCode $failure | Should -Be 503
        Should -Invoke Invoke-RestMethod -ModuleName SessionHostReplacer.Core -Times 3 -Exactly
    }
}
