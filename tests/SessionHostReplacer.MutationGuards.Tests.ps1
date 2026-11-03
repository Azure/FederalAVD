$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1'

Describe 'SHR Graph mutation ownership guards' {
    BeforeAll { Import-Module $modulePath -Force }
    AfterAll { Remove-Module SessionHostReplacer -Force }
    BeforeEach {
        $global:shrGraphGuard = @{
            Lost = $true
            LeaseChecks = 0
            Requests = @()
            RejectFirst = $false
        }

        Mock Assert-ShrWorkerLease -ModuleName SessionHostReplacer.Core {
            $global:shrGraphGuard.LeaseChecks++
            if ($global:shrGraphGuard.Lost) { throw 'Worker ownership lost.' }
        }
        Mock Invoke-RestMethod -ModuleName SessionHostReplacer.Core {
            param($Uri, $Method)
            $global:shrGraphGuard.Requests += @{ Uri = $Uri; Method = $Method }
            if ($global:shrGraphGuard.RejectFirst -and $global:shrGraphGuard.Requests.Count -eq 1) {
                $global:shrGraphGuard.Lost = $true
                $exception = [Exception]::new('Injected HTTP 403.')
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([PSCustomObject]@{
                    StatusCode = [Net.HttpStatusCode]::Forbidden
                })
                throw $exception
            }
            return @{ Accepted = $true }
        }
        Mock Get-AccessToken -ModuleName SessionHostReplacer.Core { 'test-token' }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Core {}
    }
    AfterEach { Remove-Variable shrGraphGuard -Scope Global }

    It 'blocks Graph <Method> before sending HTTP after ownership is lost' -TestCases @(
        @{ Method = 'Delete' }
        @{ Method = 'Patch' }
        @{ Method = 'Put' }
        @{ Method = 'Post' }
    ) {
        param($Method)
        {
            Invoke-GraphApiWithRetry -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token `
                -Method $Method -Uri '/v1.0/devices/nonexistent' -ClientId test-client
        } | Should Throw 'Worker ownership lost'
        $global:shrGraphGuard.Requests.Count | Should Be 0
    }

    It 'allows read-only directory discovery without requiring an active worker lease' {
        Invoke-GraphApiWithRetry -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token `
            -Method Get -Uri '/v1.0/devices' -ClientId test-client | Out-Null
        $global:shrGraphGuard.Requests.Count | Should Be 1
        $global:shrGraphGuard.LeaseChecks | Should Be 0
    }

    It 'blocks the directory deletion call path after worker ownership is lost' {
        InModuleScope SessionHostReplacer.DeviceCleanup {
            {
                Remove-SessionHostDirectoryDevice -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token `
                    -Name nonexistent -Id nonexistent -Directory Entra -ClientId test-client
            } | Should Throw 'Worker ownership lost'
        }
        $global:shrGraphGuard.Requests.Count | Should Be 0
    }

    It 'rechecks ownership after token acquisition before <Helper> retries a Graph mutation' -TestCases @(
        @{ Helper = 'Invoke-GraphRestMethod' }
        @{ Helper = 'Invoke-GraphApiWithRetry' }
    ) {
        param($Helper)
        $global:shrGraphGuard.Lost = $false
        $global:shrGraphGuard.RejectFirst = $true
        {
            if ($Helper -eq 'Invoke-GraphRestMethod') {
                Invoke-GraphRestMethod -GraphToken test-token -Method Delete `
                    -Uri 'https://graph.microsoft.us/v1.0/devices/nonexistent'
            } else {
                Invoke-GraphApiWithRetry -GraphEndpoint 'https://graph.microsoft.us' -GraphToken test-token `
                    -Method Delete -Uri '/v1.0/devices/nonexistent' -ClientId test-client
            }
        } | Should Throw 'Worker ownership lost'
        $global:shrGraphGuard.Requests.Count | Should Be 1
        $global:shrGraphGuard.LeaseChecks | Should Be 2
    }
}

Describe 'SHR repeat-safe directory deletion logging' {
    BeforeAll { Import-Module $modulePath -Force }
    AfterAll { Remove-Module SessionHostReplacer -Force }
    BeforeEach {
        $global:shrGraphDelete = @{
            Status = 404
            IntegerStatus = $false
            Directory = 'Entra'
            ThrowOnError = $true
            Requests = @()
            Logs = @()
        }
        Mock Assert-ShrWorkerLease -ModuleName SessionHostReplacer.Core {}
        Mock Invoke-RestMethod -ModuleName SessionHostReplacer.Core {
            param($Uri, $Method)
            $global:shrGraphDelete.Requests += @{ Uri = $Uri; Method = $Method }
            if ($global:shrGraphDelete.Requests.Count -eq 2 -and $global:shrGraphDelete.ContainsKey('SecondStatus')) {
                $global:shrGraphDelete.Status = $global:shrGraphDelete.SecondStatus
            }
            if ($global:shrGraphDelete.Status -eq 204) { return }
            if ($null -eq $global:shrGraphDelete.Status) { throw [IO.IOException]::new('Simulated transport failure.') }
            $exception = [Exception]::new("Simulated HTTP $($global:shrGraphDelete.Status).")
            $response = [PSCustomObject]@{
                StatusCode = if ($global:shrGraphDelete.IntegerStatus) {
                    $global:shrGraphDelete.Status
                } else { [Net.HttpStatusCode]$global:shrGraphDelete.Status }
            }
            $response | Add-Member ScriptMethod GetResponseStream {
                [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"error":{"code":"ResourceNotFound"}}'))
            }
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
            throw $exception
        }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Core {
            param($Message, $Level = 'Information')
            $global:shrGraphDelete.Logs += @{ Message = $Message; Level = $Level }
            if ($Level -eq 'Error' -and $global:shrGraphDelete.ThrowOnError) { throw 'Error logger terminated.' }
        }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.DeviceCleanup {
            param($Message, $Level = 'Information')
            $global:shrGraphDelete.Logs += @{ Message = $Message; Level = $Level }
        }
    }
    AfterEach { Remove-Variable shrGraphDelete -Scope Global }

    It 'logs an already-absent <Directory> device at Information without invoking the error logger' -TestCases @(
        @{ Directory = 'Entra'; DisplayName = 'Entra ID'; Collection = 'devices' }
        @{ Directory = 'Intune'; DisplayName = 'Intune'; Collection = 'deviceManagement/managedDevices' }
    ) {
        param($Directory, $DisplayName, $Collection)
        $global:shrGraphDelete.Directory = $Directory
        InModuleScope SessionHostReplacer.DeviceCleanup {
            Remove-SessionHostDirectoryDevice -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token `
                -Name old-host -Id old-id -Directory $global:shrGraphDelete.Directory -ClientId test-client
        }
        $global:shrGraphDelete.Requests.Count | Should Be 1
        $global:shrGraphDelete.Requests[0].Uri | Should Be "https://graph.microsoft.com/v1.0/$Collection/old-id"
        @($global:shrGraphDelete.Logs | Where-Object Level -eq 'Error').Count | Should Be 0
        $info = @($global:shrGraphDelete.Logs | Where-Object Level -eq 'Information')
        $info.Count | Should Be 1
        $info[0].Message | Should Be "Device old-host is already absent from $DisplayName; cleanup verification is still required."
        $global:shrGraphDelete.Logs.Message -join "`n" | Should Not Match 'Successfully removed'
    }

    It 'preserves a DELETE 404 exception for its caller when suppression is explicitly enabled' {
        $global:shrGraphDelete.IntegerStatus = $true
        $failure = $null
        try {
            Invoke-GraphApiWithRetry -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token `
                -Method Delete -Uri '/v1.0/devices/old-id' -ClientId test-client -SuppressNotFoundError
        } catch { $failure = $_ }
        $failure.Exception.Message | Should Be 'Simulated HTTP 404.'
        [int]$failure.Exception.Response.StatusCode | Should Be 404
        @($global:shrGraphDelete.Logs | Where-Object Level -eq 'Error').Count | Should Be 0
    }

    It 'retains error logging for a <Method> 404 without a device-delete opt-in' -TestCases @(
        @{ Method = 'Get'; Suppress = $true }
        @{ Method = 'Delete'; Suppress = $false }
    ) {
        param($Method, $Suppress)
        $global:shrGraphDelete.ThrowOnError = $false
        {
            Invoke-GraphApiWithRetry -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token `
                -Method $Method -Uri '/v1.0/devices/old-id' -ClientId test-client -SuppressNotFoundError:$Suppress
        } | Should Throw 'Simulated HTTP 404'
        @($global:shrGraphDelete.Logs | Where-Object Level -eq 'Error').Count | Should BeGreaterThan 0
    }

    It 'does not classify HTTP <Status> as an already-absent device' -TestCases @(
        @{ Status = 400 }
        @{ Status = 401 }
        @{ Status = 403 }
        @{ Status = 429 }
        @{ Status = 500 }
    ) {
        param($Status)
        $global:shrGraphDelete.Status = $Status
        $global:shrGraphDelete.ThrowOnError = $false
        InModuleScope SessionHostReplacer.DeviceCleanup {
            {
                Remove-SessionHostDirectoryDevice -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token `
                    -Name old-host -Id old-id -Directory Entra -ClientId test-client
            } | Should Throw 'Simulated HTTP'
        }
        @($global:shrGraphDelete.Logs | Where-Object Level -eq 'Error').Count | Should BeGreaterThan 0
        $global:shrGraphDelete.Logs.Message -join "`n" | Should Not Match 'already absent|Successfully removed'
    }

    It 'preserves transport failures as errors' {
        $global:shrGraphDelete.Status = $null
        $global:shrGraphDelete.ThrowOnError = $false
        InModuleScope SessionHostReplacer.DeviceCleanup {
            {
                Remove-SessionHostDirectoryDevice -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token `
                    -Name old-host -Id old-id -Directory Entra -ClientId test-client
            } | Should Throw 'Simulated transport failure'
        }
        @($global:shrGraphDelete.Logs | Where-Object Level -eq 'Error').Count | Should BeGreaterThan 0
    }

    It 'retains the GCCH-to-DoD fallback after HTTP <Status> and checks ownership before both DELETEs' -TestCases @(
        @{ Status = 401; IntegerStatus = $false }
        @{ Status = 403; IntegerStatus = $true }
    ) {
        param($Status, $IntegerStatus)
        $global:shrGraphDelete.Status = $Status
        $global:shrGraphDelete.IntegerStatus = $IntegerStatus
        $global:shrGraphDelete.SecondStatus = 204
        $global:shrGraphDelete.ThrowOnError = $false
        Mock Get-AccessToken -ModuleName SessionHostReplacer.Core { 'dod-token' }
        InModuleScope SessionHostReplacer.DeviceCleanup {
            Remove-SessionHostDirectoryDevice -GraphEndpoint 'https://graph.microsoft.us' -GraphToken test-token `
                -Name old-host -Id old-id -Directory Entra -ClientId test-client
        }
        $global:shrGraphDelete.Requests.Count | Should Be 2
        $global:shrGraphDelete.Requests[1].Uri | Should Be 'https://dod-graph.microsoft.us/v1.0/devices/old-id'
        Assert-MockCalled Get-AccessToken -ModuleName SessionHostReplacer.Core -Scope It -Times 1 -Exactly -ParameterFilter {
            $ResourceUri -eq 'https://dod-graph.microsoft.us' -and $ClientId -eq 'test-client'
        }
        Assert-MockCalled Assert-ShrWorkerLease -ModuleName SessionHostReplacer.Core -Scope It -Times 2 -Exactly
        $global:shrGraphDelete.Logs.Message | Should Contain 'Successfully removed device old-host from Entra ID'
    }

    It 'retains the successful deletion message after HTTP 204' {
        $global:shrGraphDelete.Status = 204
        InModuleScope SessionHostReplacer.DeviceCleanup {
            Remove-SessionHostDirectoryDevice -GraphEndpoint 'https://graph.microsoft.com' -GraphToken test-token `
                -Name old-host -Id old-id -Directory Entra -ClientId test-client
        }
        $global:shrGraphDelete.Logs.Message | Should Contain 'Successfully removed device old-host from Entra ID'
        @($global:shrGraphDelete.Logs | Where-Object Level -eq 'Error').Count | Should Be 0
    }
}

Describe 'SHR recovery-state mutation boundaries' {
    BeforeAll { Import-Module $modulePath -Force }
    AfterAll { Remove-Module SessionHostReplacer -Force }
    BeforeEach {
        $global:shrRecoveryGuard = @{ Lost = $false; Writes = @(); Timeout = $false }
        Mock Assert-ShrWorkerLease -ModuleName SessionHostReplacer.Deployment {
            if ($global:shrRecoveryGuard.Lost) {
                if ($global:shrRecoveryGuard.Timeout) { throw [TimeoutException]::new('Invocation budget reached.') }
                throw 'Worker ownership lost.'
            }
        }
        Mock Get-ShrWorkerState -ModuleName SessionHostReplacer.Deployment { @{ Id = 'operation' } }
        Mock Get-AccessToken -ModuleName SessionHostReplacer.Deployment { 'test-token' }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Deployment {}
        Mock Invoke-RestMethod -ModuleName SessionHostReplacer.Deployment {
            param($Uri, $Method)
            if ($Method -ne 'GET') {
                $global:shrRecoveryGuard.Writes += $Method
                return @{}
            }
            if ($Uri -like '*/Tables') {
                return @{ value = @(@{ TableName = 'sessionHostDeploymentState' }) }
            }
            $global:shrRecoveryGuard.Lost = $true
            return @{}
        }
        $global:shrRecoveryStorageUri = $env:AzureWebJobsStorage__blobServiceUri
        $env:AzureWebJobsStorage__blobServiceUri = 'https://teststorage.blob.core.windows.net'
    }
    AfterEach {
        $env:AzureWebJobsStorage__blobServiceUri = $global:shrRecoveryStorageUri
        Remove-Variable shrRecoveryGuard,shrRecoveryStorageUri -Scope Global
    }

    It 'does not merge recovery state after ownership is lost during its existence lookup' {
        {
            Save-DeploymentState -DeploymentState ([PSCustomObject]@{ LastStatus = 'Succeeded' }) `
                -HostPoolName test-pool -ClientId test-client -RequireSuccess
        } | Should Throw 'Worker ownership lost'
        $global:shrRecoveryGuard.Writes.Count | Should Be 0
    }

    It 'preserves an invocation-budget timeout so the continuation worker can yield safely' {
        $global:shrRecoveryGuard.Timeout = $true
        $exception = $null
        try {
            Save-DeploymentState -DeploymentState ([PSCustomObject]@{ LastStatus = 'Succeeded' }) `
                -HostPoolName test-pool -ClientId test-client -RequireSuccess
        } catch { $exception = $_.Exception }
        $exception -is [TimeoutException] | Should Be $true
        $global:shrRecoveryGuard.Writes.Count | Should Be 0
    }
}

Describe 'SHR deadlines across ownership storage reads' {
    BeforeAll { Import-Module $modulePath -Force }
    AfterAll { Remove-Module SessionHostReplacer -Force }

    It 'blocks a mutation when <Boundary> elapses during the ownership read' -TestCases @(
        @{ Boundary = 'OperationDeadline'; ExpectedMessage = 'deadline expired' }
        @{ Boundary = 'InvocationBudget'; ExpectedMessage = 'invocation budget reached' }
        @{ Boundary = 'LeaseExpiry'; ExpectedMessage = 'lease is no longer owned' }
    ) {
        param($Boundary, $ExpectedMessage)
        $global:shrBoundary = $Boundary
        $global:shrBoundaryMessage = $ExpectedMessage
        InModuleScope SessionHostReplacer.Continuation {
            $state = @{
                Id = ('b' * 32)
                LockOwner = 'owner'
                LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMinutes(30).ToString('o')
                DeadlineUtc = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
            }
            $script:WorkerContext = @{
                Operation = @{ State = $state }
                InvocationDeadline = [DateTimeOffset]::UtcNow.AddMinutes(8)
                YieldRequested = $false
            }
            Mock Get-ShrOperation {
                switch ($global:shrBoundary) {
                    'OperationDeadline' { $script:WorkerContext.Operation.State.DeadlineUtc = [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString('o') }
                    'InvocationBudget' { $script:WorkerContext.InvocationDeadline = [DateTimeOffset]::UtcNow.AddSeconds(-1) }
                    'LeaseExpiry' {
                        Start-Sleep -Milliseconds 50
                        $script:WorkerContext.Operation.State.LockExpiresUtc = [DateTimeOffset]::UtcNow.AddMilliseconds(-20).ToString('o')
                    }
                }
                return @{ State = $script:WorkerContext.Operation.State }
            }
            try {
                { Assert-ShrWorkerLease } | Should Throw $global:shrBoundaryMessage
                Assert-MockCalled Get-ShrOperation -Times 1 -Exactly -Scope It
                if ($global:shrBoundary -eq 'InvocationBudget') { $script:WorkerContext.YieldRequested | Should Be $true }
            } finally {
                $script:WorkerContext = $null
                Remove-Variable shrBoundary,shrBoundaryMessage -Scope Global
            }
        }
    }
}
