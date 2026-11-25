BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $collector = Join-Path $repoRoot 'deployments\add-ons\sessionHostReplacer\tools\Export-SessionHostReplacerGuestDiagnostics.ps1'
    Import-Module Az.Accounts
    Import-Module Az.Compute
    $ast = [Management.Automation.Language.Parser]::ParseFile($collector, [ref]$null, [ref]$null)
    $assignment = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$guestScript'
    }, $true)
    $guestAst = $assignment.Right.Find({
        param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
    }, $true)
    $guestBlock = $guestAst.ScriptBlock.GetScriptBlock()
}

Describe 'SHR explicit guest diagnostic collection' {
    BeforeEach {
        $vmId = '/subscriptions/subscription/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/avd01'
        $global:shrGuestTest = @{
            Reads = 0; Runs = 0; Race = $false; Tagged = $true; Output = 'Valid'
        }
        Mock Get-AzContext {
            $value = [Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext]::new()
            $value.Subscription = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureSubscription]::new()
            $value.Subscription.Id = 'subscription'
            $value
        }
        Mock Invoke-AzRestMethod {
            $global:shrGuestTest.Reads++
            $value = @{
                id = '/subscriptions/subscription/resourceGroups/hosts/providers/Microsoft.Compute/virtualMachines/avd01'
                tags = @{ AutoReplaceDeploymentName = if ($global:shrGuestTest.Tagged) { 'shr_test' } else { '' } }
                properties = @{
                    vmId = if ($global:shrGuestTest.Race -and $global:shrGuestTest.Reads -gt 1) { 'new-id' } else { 'old-id' }
                    storageProfile = @{ osDisk = @{ osType = 'Windows' } }
                }
            }
            [pscustomobject]@{ StatusCode = 200; Content = ($value | ConvertTo-Json -Depth 10) }
        }
        Mock Invoke-AzVMRunCommand {
            $global:shrGuestTest.Runs++
            $message = if ($global:shrGuestTest.Output -eq 'Valid') {
                'SHR_GUEST_DIAGNOSTICS | {"SchemaVersion":1,"Bounded":true,"Sources":[{"Name":"NetSetup","Outcome":"Collected","Lines":["join failed"]},{"Name":"DomainJoinExtension","Outcome":"Missing","Lines":[]}]}'
            } else { 'truncated private-guest-output' }
            [pscustomobject]@{ Value = @([pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = $message }) }
        }
        $arguments = @{ VirtualMachineResourceId = $vmId; OutputDirectory = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
    }
    AfterEach { Remove-Variable shrGuestTest -Scope Global -ErrorAction SilentlyContinue }

    It 'previews without guest execution or report creation' {
        $preview = & $collector @arguments
        $preview.Action | Should -Match '^PreviewOnly'
        $global:shrGuestTest.Runs | Should -Be 0
        Test-Path $arguments.OutputDirectory | Should -BeFalse
    }
    It 'honors WhatIf without executing the payload' {
        & $collector @arguments -Apply -WhatIf
        $global:shrGuestTest.Runs | Should -Be 0
        Test-Path $arguments.OutputDirectory | Should -BeFalse
    }
    It 'saves a protected report and exposes partial collection explicitly' {
        $result = & $collector @arguments -Apply -Confirm:$false -WarningVariable warnings
        $global:shrGuestTest.Runs | Should -Be 1
        $result.CollectedSources | Should -Be 1
        ($warnings -join '') | Should -Match 'incomplete'
        $report = Get-Content -LiteralPath $result.ReportPath -Raw | ConvertFrom-Json
        $report.VirtualMachineResourceId | Should -Be $vmId
        $report.Sources[1].Outcome | Should -Be 'Missing'
        if ($IsWindows) {
            (Get-Acl (Split-Path $result.ReportPath)).AreAccessRulesProtected | Should -BeTrue
        }
        Should -Invoke Invoke-AzVMRunCommand -Times 1 -Exactly -ParameterFilter {
            $VMName -eq 'avd01' -and $ResourceGroupName -eq 'hosts' -and $CommandId -eq 'RunPowerShellScript'
        }
    }
    It 'rejects a subscription mismatch without VM access or context switching' {
        { & $collector -VirtualMachineResourceId ($vmId -replace '/subscription/', '/different/') } |
            Should -Throw '*active Az context*'
        $global:shrGuestTest.Reads | Should -Be 0
        $global:shrGuestTest.Runs | Should -Be 0
    }
    It 'rejects a VM without SHR deployment ownership metadata' {
        $global:shrGuestTest.Tagged = $false
        { & $collector @arguments -Apply -Confirm:$false } | Should -Throw '*AutoReplaceDeploymentName*'
        $global:shrGuestTest.Runs | Should -Be 0
    }
    It 'refuses a recreated VM before guest execution' {
        $global:shrGuestTest.Race = $true
        { & $collector @arguments -Apply -Confirm:$false } | Should -Throw '*identity or deployment ownership changed*'
        $global:shrGuestTest.Runs | Should -Be 0
    }
    It 'rejects truncated output without printing raw guest content or producing a success report' {
        $global:shrGuestTest.Output = 'Truncated'
        { & $collector @arguments -Apply -Confirm:$false } | Should -Throw '*incomplete diagnostics*'
        @(Get-ChildItem $arguments.OutputDirectory -File -Recurse).Count | Should -Be 0
    }
}

Describe 'SHR guest payload limits and redaction' {
    BeforeEach {
        Mock Test-Path { $true }
        Mock Get-ChildItem { [pscustomobject]@{ FullName = 'extension.log'; LastWriteTimeUtc = [datetime]::UtcNow } }
        Mock Get-Content { @('Error password="sensitive-value" token=private-token https://host/file?sig=private-signature') }
    }
    It 'redacts credential assignments and URLs before returning excerpts' {
        $output = & $guestBlock
        $output | Should -Not -Match 'sensitive-value|private-token|private-signature'
        $output | Should -Match 'REDACTED'
    }
    It 'keeps the UTF-8 envelope below the Run Command output limit even for multibyte content' {
        Mock Get-Content { 1..64 | ForEach-Object { 'Error ' + ([string][char]0x754c * 600) } }
        $output = & $guestBlock
        [Text.Encoding]::UTF8.GetByteCount($output) | Should -BeLessThan 3600
        { $output.Substring('SHR_GUEST_DIAGNOSTICS | '.Length) | ConvertFrom-Json -ErrorAction Stop } | Should -Not -Throw
    }
    It 'reports log read failure explicitly without returning its raw exception text' {
        Mock Get-Content { throw 'sensitive-provider-exception' }
        $output = & $guestBlock
        $output | Should -Match 'ReadFailed'
        $output | Should -Not -Match 'sensitive-provider-exception'
    }
    It 'contains only the intended read, filtering and serialization commands' {
        $allowed = @('Test-Path','Get-ChildItem','Sort-Object','Select-Object','Get-Content',
            'Where-Object','ForEach-Object','ConvertTo-Json','Write-Output')
        $commands = $guestAst.ScriptBlock.FindAll({
            param($node) $node -is [Management.Automation.Language.CommandAst]
        }, $true)
        foreach ($command in $commands) { $command.GetCommandName() | Should -BeIn $allowed }
    }
}
