<#
.SYNOPSIS
    Previews or collects bounded domain-join guest-log excerpts from one SHR Windows VM.
.DESCRIPTION
    Preview performs only ARM reads. Apply runs a read-only PowerShell payload as SYSTEM
    through VM action Run Command, after confirmation, and saves a restricted local report.
    No passwords, app settings, operation state, VM power state, or logging settings change.
    Collection is independent of SHR recovery and must never be its prerequisite.

    Requires PowerShell 7.4+, Az.Accounts and Az.Compute, an active matching subscription,
    VM read and Microsoft.Compute/virtualMachines/runCommand/action permission.
    Run Command requires a ready VM agent and its approved cloud endpoint connectivity.
    A stopped/deleted VM or blocked agent cannot provide logs. Do not retry blindly after
    a timeout: a previously submitted command can still be running.

    Excerpts are deliberately small to fit action Run Command's 4,096-byte output limit.
    Credential-like assignments and URLs are redacted, but this is not comprehensive DLP.
    Reports can contain account names, domains, OU paths and other sensitive context.
    Review locally before sharing; do not attach raw reports to public issues.
.PARAMETER VirtualMachineResourceId
    Exact resource ID of the failed SHR VM, not the extension or deployment ID.
.PARAMETER Apply
    Collects logs after confirmation. Without this switch, previews only.
.PARAMETER OutputDirectory
    Parent of a new restricted report directory. Defaults to git-ignored customer storage.
.EXAMPLE
    .\Export-SessionHostReplacerGuestDiagnostics.ps1 -VirtualMachineResourceId $vmId
.EXAMPLE
    .\Export-SessionHostReplacerGuestDiagnostics.ps1 -VirtualMachineResourceId $vmId -Apply
#>
#Requires -Version 7.4
#Requires -Modules Az.Accounts, Az.Compute

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^/subscriptions/[^/?#]+/resourceGroups/[^/?#]+/providers/Microsoft\.Compute/virtualMachines/[^/?#]+$')]
    [string] $VirtualMachineResourceId,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '..\..\..\..\customer\shr-diagnostics'),
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
$context = Get-AzContext
if (-not $context) { throw 'Sign in using Connect-AzAccount first.' }
$parts = $VirtualMachineResourceId.Split('/')
if ($parts[2] -ne $context.Subscription.Id) {
    throw 'The VM subscription must match the active Az context. No context was switched.'
}
function Get-DiagnosticVm {
    $response = Invoke-AzRestMethod -Path "${VirtualMachineResourceId}?api-version=2024-07-01" `
        -Method GET -DefaultProfile $context
    if ([int]$response.StatusCode -ne 200) { throw "VM read failed with HTTP $($response.StatusCode)." }
    $value = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($value.id -ine $VirtualMachineResourceId -or -not $value.properties.vmId -or
        $value.properties.storageProfile.osDisk.osType -ne 'Windows' -or
        [string]::IsNullOrWhiteSpace($value.tags.AutoReplaceDeploymentName)) {
        throw 'Expected an existing Windows VM with a VM ID and SHR AutoReplaceDeploymentName tag.'
    }
    return $value
}
$vm = Get-DiagnosticVm
if (-not $Apply) {
    return [pscustomobject]@{
        VirtualMachineResourceId = $VirtualMachineResourceId
        DeploymentName = $vm.tags.AutoReplaceDeploymentName
        Action = 'PreviewOnly; Apply executes read-only guest log collection as SYSTEM'
        Sources = @('NetSetup.log', 'Latest JsonADDomainExtension log')
        OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
    }
}
if (-not $PSCmdlet.ShouldProcess($VirtualMachineResourceId, 'Run guest diagnostic collection as SYSTEM and save a restricted local report')) { return }
$fresh = Get-DiagnosticVm
if ($fresh.properties.vmId -ne $vm.properties.vmId -or
    $fresh.tags.AutoReplaceDeploymentName -ne $vm.tags.AutoReplaceDeploymentName) {
    throw 'VM identity or deployment ownership changed. Re-preview the selected VM.'
}

$directory = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) ([guid]::NewGuid().ToString('N')))
if ($IsWindows) {
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($sid)
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    Set-Acl -LiteralPath $directory.FullName -AclObject $acl
} else {
    [IO.File]::SetUnixFileMode($directory.FullName,
        [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
}

$guestScript = {
    $ErrorActionPreference = 'Stop'
    $sources = @()
    foreach ($name in @('NetSetup', 'DomainJoinExtension')) {
        $source = @{ Name = $name; Outcome = 'Missing'; Lines = @() }
        try {
            $path = if ($name -eq 'NetSetup') { "$env:windir\debug\NetSetup.log" } else {
                $root = 'C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.JsonADDomainExtension'
                if (Test-Path -LiteralPath $root) {
                    Get-ChildItem -LiteralPath $root -Filter '*.log' -File -Recurse -ErrorAction Stop |
                        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 -ExpandProperty FullName
                }
            }
            if ($path -and (Test-Path -LiteralPath $path)) {
                $lines = @(Get-Content -LiteralPath $path -Tail 64 -ErrorAction Stop |
                    Where-Object { $_ -match '(?i)error|fail|netp.*(?:join|dc|status)|errcode|0x[0-9a-f]+' } |
                    Select-Object -Last 12)
                $source.Lines = @($lines | ForEach-Object {
                    $line = $_ -replace '(?i)((?:password|passwd|pwd|token|secret|authorization)\s*["'']?\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^\s,;]+)', '$1[REDACTED]'
                    $line = $line -replace 'https?://[^\s"''<>]+', '[URL REDACTED]'
                    $line.Substring(0, [Math]::Min(600, $line.Length))
                })
                $source.Outcome = if ($source.Lines.Count) { 'Collected' } else { 'NoMatchingLines' }
            }
        } catch {
            $source.Outcome = 'ReadFailed'
            $source.ErrorType = $_.Exception.GetType().Name
        }
        $sources += $source
    }
    $report = @{ SchemaVersion = 1; Bounded = $true; Sources = $sources }
    $json = $report | ConvertTo-Json -Depth 8 -Compress
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt 3500) {
        $largest = $sources | Sort-Object { $_.Lines.Count } -Descending | Select-Object -First 1
        if (-not $largest.Lines.Count) { throw 'Diagnostic envelope exceeds the output budget.' }
        $largest.Lines = @($largest.Lines | Select-Object -Skip 1)
        if (-not $largest.Lines.Count) { $largest.Outcome = 'OmittedForOutputBudget' }
        $json = $report | ConvertTo-Json -Depth 8 -Compress
    }
    Write-Output "SHR_GUEST_DIAGNOSTICS | $json"
}.ToString()

$result = Invoke-AzVMRunCommand -ResourceGroupName $parts[4] -VMName $parts[8] `
    -CommandId RunPowerShellScript -ScriptString $guestScript -DefaultProfile $context -ErrorAction Stop
$stdout = @($result.Value | Where-Object Code -eq 'ComponentStatus/StdOut/succeeded')
$stderr = @($result.Value | Where-Object { $_.Code -match '/failed$' -or ($_.Code -match '/StdErr/' -and $_.Message) })
if ($stderr.Count -or $stdout.Count -ne 1 -or
    $stdout[0].Message -notmatch '(?m)^SHR_GUEST_DIAGNOSTICS \| (\{[^\r\n]*\})\s*$') {
    throw 'Run Command failed or returned incomplete diagnostics. No raw command output was printed. Check agent/command status before retrying.'
}
$report = $Matches[1] | ConvertFrom-Json -AsHashtable -ErrorAction Stop
if ($report.SchemaVersion -ne 1 -or $report.Sources.Count -ne 2 -or
    @($report.Sources | Where-Object { $_.Name -notin @('NetSetup', 'DomainJoinExtension') }).Count) {
    throw 'Run Command returned an unsupported diagnostic report.'
}
$report.VirtualMachineResourceId = $VirtualMachineResourceId
$report.CollectedUtc = [DateTimeOffset]::UtcNow.ToString('o')
$path = Join-Path $directory.FullName 'guest-diagnostics.json'
[IO.File]::WriteAllText($path, ($report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$collected = @($report.Sources | Where-Object { $_.Outcome -eq 'Collected' -and $_.Lines.Count }).Count
if ($collected -ne 2) {
    Write-Warning "Guest diagnostics incomplete: $collected of 2 sources supplied excerpts. Review per-source outcomes in the restricted report: $path"
}
[pscustomobject]@{ ReportPath = $path; CollectedSources = $collected; ExpectedSources = 2 }
