BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\functions\Modules\SessionHostReplacer\SessionHostReplacer.psd1') -Force
    $deploymentModule = Get-Module SessionHostReplacer.Deployment -All | Select-Object -First 1
    function Invoke-TestFailureCapture {
        & $deploymentModule {
            Publish-ShrDeploymentFailure -ARMToken token -DeploymentName shr_test `
                -ResourceManagerUri 'https://management.usgovcloudapi.net' `
                -SubscriptionId test -ResourceGroupName hosts
        }
    }
}

AfterAll {
    Remove-Module SessionHostReplacer -Force
    Remove-Variable shrFailureTest -Scope Global -ErrorAction SilentlyContinue
}

Describe 'SHR pre-cleanup deployment failure capture' {
    BeforeEach {
        $root = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Resources/deployments/shr_test'
        $extension = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/avd01/extensions/JsonADDomainExtension'
        $global:shrFailureTest = @{
            State = @{ Id = ('a' * 32); Status = 'Running' }
            Timestamp = '2026-11-25T10:00:00Z'
            TargetId = $extension
            TargetType = 'Microsoft.Compute/virtualMachines/extensions'
            Message = 'Error code 1330. private-provider-evidence'
            Calls = @()
            Events = @()
            Logs = @()
            Order = @()
            Transient = $false
            Nested = $false
            FailNested = $false
            InstanceViewMessage = 'private-instance-view-evidence'
            InstanceViewUnavailable = $false
        }
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Deployment {
            param($SettingKey)
            switch ($SettingKey) {
                VirtualMachinesSubscriptionId { 'test' }
                VirtualMachinesResourceGroupName { 'hosts' }
            }
        }
        Mock Get-ShrWorkerState -ModuleName SessionHostReplacer.Deployment { $global:shrFailureTest.State }
        Mock Assert-ShrWorkerLease -ModuleName SessionHostReplacer.Deployment {}
        Mock Save-ShrContinuationCheckpoint -ModuleName SessionHostReplacer.Deployment {
            $global:shrFailureTest.Order += 'checkpoint'
        }
        Mock Write-ShrEvent -ModuleName SessionHostReplacer.Deployment {
            param($EventName, $State)
            $global:shrFailureTest.Events += $EventName
            $global:shrFailureTest.Order += 'event'
        }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Deployment {
            param($Message)
            $global:shrFailureTest.Logs += $Message
        }
        Mock Get-ResourceManagerUri -ModuleName SessionHostReplacer.Deployment { 'https://management.usgovcloudapi.net' }
        Mock Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Deployment {
            param($Uri, $Method)
            $sim = $global:shrFailureTest
            $sim.Calls += @{ Uri = $Uri; Method = $Method }
            if ($Uri -like '*$expand=instanceView') {
                if ($sim.InstanceViewUnavailable) {
                    throw [Net.Http.HttpRequestException]::new('private-instance-view-request-error')
                }
                return [pscustomobject]@{
                    properties = @{ instanceView = @{ statuses = @(
                        @{ code = 'ProvisioningState/failed'; message = $sim.InstanceViewMessage }
                    ) } }
                }
            }
            if ($sim.Transient) { throw [Net.Http.HttpRequestException]::new('diagnostic request unavailable') }
            if ($sim.FailNested -and $Uri -like '*/nested/operations?*') {
                throw [Net.Http.HttpRequestException]::new('nested diagnostics unavailable')
            }
            if ($Uri -like '*/operations?*') {
                if ($sim.Nested -and $Uri -like '*/shr_test/operations?*') {
                    return @([pscustomobject]@{
                        properties = @{
                            provisioningState = 'Failed'
                            targetResource = @{
                                id = '/subscriptions/test/resourceGroups/hosts/providers/Microsoft.Resources/deployments/nested'
                                resourceType = 'Microsoft.Resources/deployments'
                            }
                            statusMessage = @{ error = @{ code = 'DeploymentFailed' } }
                        }
                    })
                }
                return @([pscustomobject]@{
                    properties = @{
                        provisioningState = 'Failed'
                        targetResource = @{ id = $sim.TargetId; resourceType = $sim.TargetType }
                        statusMessage = (@{
                            error = @{
                                code = 'VMExtensionProvisioningError'
                                details = @(@{ code = 'ExtensionError'; message = $sim.Message })
                            }
                        } | ConvertTo-Json -Depth 10 -Compress)
                    }
                })
            }
            return [pscustomobject]@{
                properties = @{
                    provisioningState = 'Failed'
                    timestamp = $sim.Timestamp
                    error = @{ code = 'DeploymentFailed'; message = 'A nested deployment failed.' }
                }
            }
        }
    }

    It 'classifies explicit domain credential evidence <Message> as <Code>' -TestCases @(
        @{ Message = 'Error code 1330'; Code = 'ERROR_PASSWORD_EXPIRED' }
        @{ Message = 'Error code: 1326'; Code = 'ERROR_LOGON_FAILURE' }
        @{ Message = 'Error code 1331'; Code = 'ERROR_ACCOUNT_DISABLED' }
        @{ Message = 'Error code 1907'; Code = 'ERROR_PASSWORD_MUST_CHANGE' }
        @{ Message = 'Error code 1909'; Code = 'ERROR_ACCOUNT_LOCKED_OUT' }
        @{ Message = 'Error code 0x532'; Code = 'ERROR_PASSWORD_EXPIRED' }
        @{ Message = 'Error code 0x52E'; Code = 'ERROR_LOGON_FAILURE' }
        @{ Message = 'Error code 0x533'; Code = 'ERROR_ACCOUNT_DISABLED' }
        @{ Message = 'Error code 0x773'; Code = 'ERROR_PASSWORD_MUST_CHANGE' }
        @{ Message = 'Error code 0x775'; Code = 'ERROR_ACCOUNT_LOCKED_OUT' }
        @{ Message = 'The password for this account has expired.'; Code = 'ERROR_PASSWORD_EXPIRED' }
    ) {
        param($Message, $Code)
        $global:shrFailureTest.Message = $Message
        $failure = Get-ShrDeploymentFailure -ARMToken token -DeploymentName shr_test
        $failure.Category | Should -Be 'DomainJoinCredentials'
        $failure.Code | Should -Be $Code
        $failure.RequiresAttention | Should -BeTrue
        $failure.ResourceId | Should -Be $extension
    }

    It 'does not diagnose an unknown domain or DNS error as an expired password' {
        $global:shrFailureTest.Message = 'Error code 1355. The specified domain could not be contacted.'
        $failure = Get-ShrDeploymentFailure -ARMToken token -DeploymentName shr_test
        $failure.Category | Should -Be 'DomainJoin'
        $failure.RequiresAttention | Should -BeFalse
    }

    It 'captures one bounded instance view without using it to invent a permanent credential diagnosis' {
        $global:shrFailureTest.Message = 'Error code 1355. Domain not reachable.'
        $global:shrFailureTest.InstanceViewMessage = 'Old error code 1330. ' + ('x' * 4000)
        $failure = Get-ShrDeploymentFailure -ARMToken token -DeploymentName shr_test
        $failure.Category | Should -Be 'DomainJoin'
        $failure.RequiresAttention | Should -BeFalse
        $failure.InstanceViewDiagnostics.Outcome | Should -Be 'Captured'
        $failure.InstanceViewDiagnostics.Evidence.Length | Should -Be 2048
        @($global:shrFailureTest.Calls | Where-Object Uri -Like '*$expand=instanceView').Count | Should -Be 1
        Should -Invoke Invoke-AzureRestMethod -ModuleName SessionHostReplacer.Deployment -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*$expand=instanceView' -and $MaxRetries -eq 1 -and $Method -eq 'GET'
        }
    }

    It 'does not block ordinary join recovery when supplemental diagnostics are unavailable' {
        $global:shrFailureTest.Message = 'Error code 1355. Domain not reachable.'
        $global:shrFailureTest.InstanceViewUnavailable = $true
        { Invoke-TestFailureCapture } | Should -Not -Throw
        $global:shrFailureTest.State.DeploymentFailure.InstanceViewDiagnostics.Outcome | Should -Be 'Unavailable'
        ($global:shrFailureTest.Logs -join "`n") | Should -Match 'diagnostics unavailable'
        ($global:shrFailureTest.Logs -join "`n") | Should -Not -Match 'private-instance-view-request-error'
    }

    It 'retains a confirmed credential stop even when supplemental diagnostics cannot be read' {
        $global:shrFailureTest.InstanceViewUnavailable = $true
        { Invoke-TestFailureCapture } | Should -Throw '*credential failure*'
        $global:shrFailureTest.State.DeploymentFailure.Code | Should -Be 'ERROR_PASSWORD_EXPIRED'
        $global:shrFailureTest.State.DeploymentFailure.InstanceViewDiagnostics.Outcome | Should -Be 'Unavailable'
    }

    It 'does not request extension details outside the configured VM scope' {
        $global:shrFailureTest.TargetId = $extension -replace '/hosts/', '/different/'
        $failure = Get-ShrDeploymentFailure -ARMToken token -DeploymentName shr_test
        $failure.InstanceViewDiagnostics.Outcome | Should -Be 'NotApplicable'
        @($global:shrFailureTest.Calls | Where-Object Uri -Like '*$expand=instanceView').Count | Should -Be 0
    }

    It 'does not interpret a registration error number as domain credentials without domain context' {
        $global:shrFailureTest.TargetId = $extension -replace '/extensions/JsonADDomainExtension$', '/runCommands/initializeSessionHost'
        $global:shrFailureTest.Message = 'Registration failed with error code 1326'
        $failure = Get-ShrDeploymentFailure -ARMToken token -DeploymentName shr_test
        $failure.Category | Should -Be 'HostRegistration'
        $failure.RequiresAttention | Should -BeFalse
    }

    It 'captures evidence and notifies before refusing any credential-failure cleanup' {
        { Remove-FailedDeploymentArtifacts -ARMToken token -RemoveEntraDevice $false -RemoveIntuneDevice $false -FailedDeployments @(
            [pscustomobject]@{ DeploymentName = 'shr_test'; SessionHostNames = @('avd01') }
        ) } | Should -Throw '*AcknowledgeCredentialFix*'
        $sim = $global:shrFailureTest
        $sim.State.DeploymentFailure.Evidence | Should -Match 'private-provider-evidence'
        ($sim.Logs -join "`n") | Should -Not -Match 'private-provider-evidence'
        ($sim.Order -join ',') | Should -Be 'event,checkpoint'
        @($sim.Calls | Where-Object Method -ne GET).Count | Should -Be 0
        @($sim.Calls | Where-Object Uri -Match '/virtualMachines\?').Count | Should -Be 0
    }

    It 'does not emit the same failure again but continues to refuse an unacknowledged failure' {
        { Invoke-TestFailureCapture } | Should -Throw '*credential failure*'
        { Invoke-TestFailureCapture } | Should -Throw '*credential failure*'
        $global:shrFailureTest.Events.Count | Should -Be 1
    }

    It 'follows nested deployment operations to identify the failing domain-join resource' {
        $global:shrFailureTest.Nested = $true
        $failure = Get-ShrDeploymentFailure -ARMToken token -DeploymentName shr_test
        $failure.Category | Should -Be 'DomainJoinCredentials'
        $failure.ResourceId | Should -Be $extension
        @($global:shrFailureTest.Calls | Where-Object Uri -Like '*/nested/operations?*').Count | Should -Be 1
    }

    It 'permits retry of an acknowledged attempt but stops a new failed attempt' {
        { Invoke-TestFailureCapture } | Should -Throw '*credential failure*'
        $global:shrFailureTest.State.DeploymentFailure.AcknowledgedUtc = '2026-11-25T10:10:00Z'
        { Invoke-TestFailureCapture } | Should -Not -Throw
        $oldId = $global:shrFailureTest.State.DeploymentFailure.Id
        $global:shrFailureTest.Timestamp = '2026-11-25T10:15:00Z'
        { Invoke-TestFailureCapture } | Should -Throw '*credential failure*'
        $global:shrFailureTest.State.DeploymentFailure.Id | Should -Not -Be $oldId
        $global:shrFailureTest.State.DeploymentFailure.AcknowledgedUtc | Should -Be ''
        $global:shrFailureTest.Events.Count | Should -Be 2
    }

    It 'surfaces transient diagnosis failures without inventing credential evidence or mutating resources' {
        $global:shrFailureTest.Transient = $true
        { Invoke-TestFailureCapture } | Should -Throw '*diagnostic request unavailable*'
        $global:shrFailureTest.State.DeploymentFailure | Should -BeNullOrEmpty
        $global:shrFailureTest.Events.Count | Should -Be 0
        @($global:shrFailureTest.Calls | Where-Object Method -ne GET).Count | Should -Be 0
    }

    It 'preserves a credential acknowledgement across other failed deployments and deduplicates both' {
        { Invoke-TestFailureCapture } | Should -Throw '*credential failure*'
        $sim = $global:shrFailureTest
        $sim.State.DeploymentFailure.AcknowledgedUtc = '2026-11-25T10:10:00Z'
        $sim.State.DeploymentFailureAttempts.shr_test.AcknowledgedUtc = '2026-11-25T10:10:00Z'
        $sim.TargetId = $sim.TargetId -replace 'JsonADDomainExtension$', 'OtherExtension'
        $sim.Message = 'An unrelated extension failed'
        & $deploymentModule {
            Publish-ShrDeploymentFailure -ARMToken token -DeploymentName shr_other `
                -ResourceManagerUri 'https://management.usgovcloudapi.net' -SubscriptionId test -ResourceGroupName hosts
        }
        $sim.TargetId = $extension
        $sim.Message = 'Error code 1330'
        { Invoke-TestFailureCapture } | Should -Not -Throw
        $sim.State.DeploymentFailure.AcknowledgedUtc | Should -Be '2026-11-25T10:10:00Z'
        $sim.Events.Count | Should -Be 2
    }

    It 'rejects invalid attempt timestamps instead of acknowledging an ambiguous retry identity' {
        $global:shrFailureTest.Timestamp = 'invalid'
        { Invoke-TestFailureCapture } | Should -Throw '*timestamp*'
    }

    It 'preserves evidence when nested operation reads have a transient failure' {
        $global:shrFailureTest.Nested = $true
        $global:shrFailureTest.FailNested = $true
        { Invoke-TestFailureCapture } | Should -Throw '*nested diagnostics unavailable*'
        $global:shrFailureTest.State.DeploymentFailure | Should -BeNullOrEmpty
        @($global:shrFailureTest.Calls | Where-Object Method -ne GET).Count | Should -Be 0
    }

    It 'refuses nested deployment traversal outside the configured VM resource group' {
        $global:shrFailureTest.TargetId = '/subscriptions/test/resourceGroups/another/providers/Microsoft.Resources/deployments/nested'
        $global:shrFailureTest.TargetType = 'Microsoft.Resources/deployments'
        { Invoke-TestFailureCapture } | Should -Throw '*outside the configured VM scope*'
        $global:shrFailureTest.State.DeploymentFailure | Should -BeNullOrEmpty
    }

    It 'keeps private provider messages out of structured telemetry' {
        Mock Read-FunctionAppSetting -ModuleName SessionHostReplacer.Core { $true }
        Mock Write-LogEntry -ModuleName SessionHostReplacer.Core {
            param($Message)
            $global:shrFailureTest.Logs += $Message
        }
        { Invoke-TestFailureCapture } | Should -Throw '*credential failure*'
        Write-ShrEvent -Event DeploymentFailed -State $global:shrFailureTest.State
        $message = $global:shrFailureTest.Logs[-1]
        $message | Should -Match '"FailureCategory":"DomainJoinCredentials"'
        $message | Should -Match '"FailureCode":"ERROR_PASSWORD_EXPIRED"'
        $message | Should -Match '"FailureInstanceViewOutcome":"Captured"'
        $message | Should -Not -Match 'private-provider-evidence|private-instance-view-evidence|Evidence'
    }
}

Describe 'SHR first-failure alert contract' {
    BeforeAll {
        $template = Get-Content (Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\alerts\deploymentFailures.json') -Raw | ConvertFrom-Json
        $rule = $template.resources | Where-Object type -eq 'Microsoft.Insights/scheduledQueryRules'
    }
    It 'alerts on the first failure without depending on failed timer invocations' {
        $rule.properties.criteria.allOf[0].threshold | Should -Be 0
        $rule.properties.criteria.allOf[0].operator | Should -Be 'GreaterThan'
        $rule.properties.criteria.allOf[0].failingPeriods.minFailingPeriodsToAlert | Should -Be 1
        $template.variables.query | Should -Match 'DeploymentFailed'
        $template.variables.query | Should -Not -Match '\brequests\b|NeedsAttention'
    }
    It 'routes to a required existing Action Group with a matching two-hour query range' {
        $template.parameters.actionGroupResourceId.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
        $rule.properties.actions.actionGroups[0] | Should -Match 'actionGroupResourceId'
        $rule.properties.overrideQueryTimeRange | Should -Be $rule.properties.windowSize
        $rule.properties.evaluationFrequency | Should -Be 'PT5M'
        $rule.apiVersion | Should -Not -Match 'preview'
    }
}
