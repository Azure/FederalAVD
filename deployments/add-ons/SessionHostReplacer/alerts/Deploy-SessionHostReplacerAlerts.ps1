#Requires -Version 7.0
#Requires -Modules Az.Monitor, Az.FunctionApp

<#
.SYNOPSIS
    Deploys monitoring alerts for SessionHostReplacer function

.DESCRIPTION
    This script deploys pre-configured monitoring alerts for the SessionHostReplacer function.
    Alerts are created in Azure Monitor using Application Insights data and notify via Action Groups.

.PARAMETER FunctionAppName
    Name of the SessionHostReplacer Function App to monitor

.PARAMETER ResourceGroupName
    Resource group containing the Function App

.PARAMETER ActionGroupResourceId
    Full resource ID of the Action Group for alert notifications
    Example: /subscriptions/{sub-id}/resourceGroups/{rg}/providers/Microsoft.Insights/actionGroups/{name}

.PARAMETER AlertLevel
    Level of alerts to deploy. Options:
    - Critical: Severity 0-1 only (deployment failures, blocking issues)
    - High: Severity 0-2 (includes registration issues, blocked operations)
    - Medium: Severity 0-3 (includes warnings, partial failures)
    - All: All severity levels including informational

.PARAMETER EnableInformationalAlerts
    Include informational alerts (Severity 4) such as cycle complete notifications

.PARAMETER DisableAlerts
    Deploy alert rules but keep them disabled

.PARAMETER WhatIf
    Show what would be deployed without actually creating resources

.EXAMPLE
    .\Deploy-SessionHostReplacerAlerts.ps1 -FunctionAppName "func-avd-shr-prod" -ResourceGroupName "rg-avd-management" -ActionGroupResourceId "/subscriptions/.../actionGroups/ag-avd-alerts"
    
    Deploys critical alerts for the specified function app

.EXAMPLE
    .\Deploy-SessionHostReplacerAlerts.ps1 -FunctionAppName "func-avd-shr-prod" -ResourceGroupName "rg-avd-management" -ActionGroupResourceId "/subscriptions/.../actionGroups/ag-avd-alerts" -AlertLevel High -EnableInformationalAlerts
    
    Deploys critical, high, and informational alerts

.NOTES
    Author: SessionHostReplacer Team
    Version: 1.0.0
    Requires: Az.Monitor, Az.FunctionApp PowerShell modules
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, HelpMessage = "Name of the SessionHostReplacer Function App")]
    [ValidateNotNullOrEmpty()]
    [string]$FunctionAppName,
    
    [Parameter(Mandatory, HelpMessage = "Resource group containing the Function App")]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory, HelpMessage = "Full resource ID of the Action Group")]
    [ValidatePattern('^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Insights/actionGroups/[^/]+$')]
    [string]$ActionGroupResourceId,
    
    [Parameter(HelpMessage = "Alert severity level to deploy")]
    [ValidateSet('Critical', 'High', 'Medium', 'All')]
    [string]$AlertLevel = 'Critical',
    
    [Parameter(HelpMessage = "Include informational alerts (cycle complete, milestones)")]
    [switch]$EnableInformationalAlerts,
    
    [Parameter(HelpMessage = "Deploy alert rules in disabled state")]
    [switch]$DisableAlerts,
    
    [Parameter(HelpMessage = "Use Bicep deployment instead of direct API calls")]
    [switch]$UseBicepDeployment
)

$ErrorActionPreference = 'Stop'

# Import required functions
function Write-ColorOutput {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White
    )
    Write-Host $Message -ForegroundColor $ForegroundColor
}

function Get-AlertConfigurations {
    param(
        [string]$FunctionName,
        [string]$Level,
        [bool]$IncludeInformational
    )
    
    $alerts = @(
        # ==================== CRITICAL ALERTS (Severity 0-1) ====================
        @{
            Name = "shr-$FunctionName-deployment-failure-pending-hosts"
            DisplayName = "SessionHostReplacer - Deployment Failure with Pending Hosts"
            Description = "Deployment failed and hosts are deleted but not replaced (DeleteFirst mode). CRITICAL: Capacity loss."
            Severity = 0
            Query = @"
traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(1h)
| where message has "Deployment failed" and message has "pending host mappings"
| summarize FailureCount = count(), LastFailure = max(timestamp), sample_message = any(message)
| where FailureCount > 0
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromMinutes(5)
            TimeWindow = [TimeSpan]::FromMinutes(15)
            Enabled = $true
        },
        @{
            Name = "shr-$FunctionName-device-cleanup-blocking"
            DisplayName = "SessionHostReplacer - Device Cleanup Failure Blocking Deployment"
            Description = "DeleteFirst mode blocked because Entra/Intune cleanup failed. Check Graph API permissions."
            Severity = 0
            Query = @"
traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(30m)
| where message has "Device cleanup verification failed" or message has "cannot safely reuse hostnames"
| summarize FailureCount = count(), LastFailure = max(timestamp), sample_message = any(message)
| where FailureCount > 0
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromMinutes(5)
            TimeWindow = [TimeSpan]::FromMinutes(30)
            Enabled = $true
        },
        @{
            Name = "shr-$FunctionName-safety-check-low-capacity"
            DisplayName = "SessionHostReplacer - Safety Check Failed with Low Capacity"
            Description = "SideBySide mode: New hosts not Available and pool capacity below 80%"
            Severity = 1
            Query = @"
let safety_failures = traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(1h)
| where message has "SAFETY CHECK FAILED"
| project timestamp;
let capacity_checks = traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(1h)
| where message has "Current available capacity" and message has "%"
| extend capacity_pct = todouble(extract(@"(\d+)%", 1, message))
| where capacity_pct < 80
| project timestamp, capacity_pct;
safety_failures
| join kind=inner capacity_checks on timestamp
| summarize FailureCount = count(), MinCapacity = min(capacity_pct), LastFailure = max(timestamp)
| where FailureCount > 0
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromMinutes(10)
            TimeWindow = [TimeSpan]::FromHours(1)
            Enabled = $true
        },
        # ==================== HIGH PRIORITY ALERTS (Severity 2) ====================
        @{
            Name = "shr-$FunctionName-registration-failure-pattern"
            DisplayName = "SessionHostReplacer - Registration Failure Pattern"
            Description = "Hosts deployed but consistently failing to register in AVD for >30 minutes"
            Severity = 2
            Query = @"
traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(2h)
| where message has "Deployment succeeded but hosts not yet registered" or 
        message has "hosts still not registered" or
        message has "PendingRegistration"
| summarize OccurrenceCount = count(), 
            FirstOccurrence = min(timestamp),
            LastOccurrence = max(timestamp),
            UnresolvedDuration = datetime_diff('minute', max(timestamp), min(timestamp)),
            sample_message = any(message)
| where UnresolvedDuration > 30
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromMinutes(15)
            TimeWindow = [TimeSpan]::FromHours(2)
            Enabled = $true
        },
        @{
            Name = "shr-$FunctionName-blocked-deletions"
            DisplayName = "SessionHostReplacer - Blocked Deletions Due to Unresolved Hosts"
            Description = "DeleteFirst mode blocked from deleting more hosts due to unresolved previous deletions"
            Severity = 2
            Query = @"
traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(1h)
| where message has "BLOCKING new deletions" or 
        message has "Cannot delete more hosts while previous deletions have unresolved"
| summarize BlockCount = count(),
            FirstBlock = min(timestamp),
            LastBlock = max(timestamp),
            BlockedDuration = datetime_diff('minute', max(timestamp), min(timestamp)),
            sample_message = any(message)
| where BlockedDuration > 60
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromMinutes(30)
            TimeWindow = [TimeSpan]::FromHours(1)
            Enabled = $true
        },
        @{
            Name = "shr-$FunctionName-scaleup-stuck"
            DisplayName = "SessionHostReplacer - Progressive Scale-Up Stuck"
            Description = "ConsecutiveSuccesses remains at 0 after multiple runs (5+ runs over 2+ hours)"
            Severity = 2
            Query = @"
traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(6h)
| where message has "Progressive scale-up: Using" and message has "ConsecutiveSuccesses: 0"
| summarize RunCount = count(), 
            FirstRun = min(timestamp),
            LastRun = max(timestamp),
            StuckDuration = datetime_diff('hour', max(timestamp), min(timestamp)),
            sample_message = any(message)
| where RunCount >= 5 and StuckDuration >= 2
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromHours(1)
            TimeWindow = [TimeSpan]::FromHours(6)
            Enabled = $true
        },
        # ==================== MEDIUM PRIORITY ALERTS (Severity 3) ====================
        @{
            Name = "shr-$FunctionName-graph-permissions-warning"
            DisplayName = "SessionHostReplacer - Graph API Permission Warnings"
            Description = "Function attempting device cleanup but lacks Graph API permissions"
            Severity = 3
            Query = @"
traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(1h)
| where (message has "Failed to acquire Graph access token" or
         message has "Get-AccessToken returned null or empty" or
         message has "Device cleanup will be skipped") and
        (message has "Directory.ReadWrite.All" or message has "DeviceManagementManagedDevices.ReadWrite.All")
| summarize WarningCount = count(), LastWarning = max(timestamp), sample_message = any(message)
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromHours(1)
            TimeWindow = [TimeSpan]::FromHours(1)
            Enabled = $true
        },
        @{
            Name = "shr-$FunctionName-partial-deletion-failures"
            DisplayName = "SessionHostReplacer - Partial Deletion Failures"
            Description = "Some hosts failed to delete (VM, Entra, or Intune cleanup incomplete)"
            Severity = 3
            Query = @"
traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(2h)
| where message has "session host deletion(s) failed" or 
        message has "FailedDeletions" or
        message has "IncompleteHosts"
| extend failed_count = toint(extract(@"(\d+) session host", 1, message))
| where failed_count > 0
| summarize TotalFailures = sum(failed_count), LastFailure = max(timestamp), sample_message = any(message)
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromHours(1)
            TimeWindow = [TimeSpan]::FromHours(2)
            Enabled = $true
        },
        @{
            Name = "shr-$FunctionName-capacity-below-minimum"
            DisplayName = "SessionHostReplacer - Capacity Below Minimum Threshold"
            Description = "Available capacity dropped below configured minimum during replacement"
            Severity = 3
            Query = @"
traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(30m)
| where message has "Current available capacity" and message has "%"
| extend capacity_pct = todouble(extract(@"(\d+)%", 1, message))
| extend min_capacity_pct = todouble(extract(@"minimum capacity \((\d+)%\)", 1, message))
| where capacity_pct < min_capacity_pct
| summarize MinCapacity = min(capacity_pct), LastOccurrence = max(timestamp), sample_message = any(message)
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromMinutes(15)
            TimeWindow = [TimeSpan]::FromMinutes(30)
            Enabled = $true
        },
        # ==================== INFORMATIONAL ALERTS (Severity 4) ====================
        @{
            Name = "shr-$FunctionName-cycle-complete"
            DisplayName = "SessionHostReplacer - Replacement Cycle Complete"
            Description = "All session hosts successfully replaced"
            Severity = 4
            Query = @"
traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(1h)
| where message has "All session hosts are up to date" or
        message has "Session host replacement cycle complete"
| summarize CompletionCount = count(), LastCompletion = max(timestamp)
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromHours(1)
            TimeWindow = [TimeSpan]::FromHours(1)
            Enabled = $IncludeInformational
        },
        @{
            Name = "shr-$FunctionName-scaleup-milestone"
            DisplayName = "SessionHostReplacer - Progressive Scale-Up Milestone"
            Description = "Progressive scale-up percentage reached milestone (60% or 100%)"
            Severity = 4
            Query = @"
traces
| where cloud_RoleName == "$FunctionName"
| where timestamp > ago(1h)
| where message has "Progressive scale-up: Using" and message has "ConsecutiveSuccesses:"
| extend current_pct = toint(extract(@"Using (\d+)%", 1, message))
| extend successes = toint(extract(@"ConsecutiveSuccesses: (\d+)", 1, message))
| where successes > 0 and (current_pct == 60 or current_pct == 100)
| summarize LastAdvancement = max(timestamp), Percentage = max(current_pct), sample_message = any(message)
"@
            Threshold = 1
            Frequency = [TimeSpan]::FromHours(1)
            TimeWindow = [TimeSpan]::FromHours(1)
            Enabled = $IncludeInformational
        }
    )
    
    # Filter by severity
    $severityMap = @{
        'Critical' = @(0, 1)
        'High' = @(0, 1, 2)
        'Medium' = @(0, 1, 2, 3)
        'All' = @(0, 1, 2, 3, 4)
    }
    
    $filtered = $alerts | Where-Object { $_.Severity -in $severityMap[$Level] }
    
    # Filter out informational if not requested
    if (-not $IncludeInformational) {
        $filtered = $filtered | Where-Object { $_.Severity -ne 4 }
    }
    
    return $filtered
}

# Main script
try {
    Write-ColorOutput "`n==================================================" -ForegroundColor Cyan
    Write-ColorOutput "SessionHostReplacer Alert Deployment" -ForegroundColor Cyan
    Write-ColorOutput "==================================================" -ForegroundColor Cyan
    
    # Validate Azure connection
    Write-ColorOutput "`nValidating Azure connection..." -ForegroundColor Yellow
    $context = Get-AzContext
    if (-not $context) {
        throw "Not connected to Azure. Run Connect-AzAccount first."
    }
    Write-ColorOutput "  ✓ Connected as: $($context.Account.Id)" -ForegroundColor Green
    Write-ColorOutput "  ✓ Subscription: $($context.Subscription.Name)" -ForegroundColor Green
    
    # Get Function App details
    Write-ColorOutput "`nValidating Function App..." -ForegroundColor Yellow
    $functionApp = Get-AzFunctionApp -Name $FunctionAppName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
    Write-ColorOutput "  ✓ Function App found: $($functionApp.Name)" -ForegroundColor Green
    Write-ColorOutput "  ✓ Location: $($functionApp.Location)" -ForegroundColor Green
    
    # Get Application Insights
    if (-not $functionApp.ApplicationInsightId) {
        throw "Function App does not have Application Insights configured. Alerts require Application Insights."
    }
    Write-ColorOutput "  ✓ Application Insights configured" -ForegroundColor Green
    
    # Validate Action Group
    Write-ColorOutput "`nValidating Action Group..." -ForegroundColor Yellow
    $actionGroupParts = $ActionGroupResourceId -split '/'
    $agResourceGroup = $actionGroupParts[4]
    $agName = $actionGroupParts[-1]
    $actionGroup = Get-AzActionGroup -ResourceGroupName $agResourceGroup -Name $agName -ErrorAction Stop
    Write-ColorOutput "  ✓ Action Group found: $($actionGroup.Name)" -ForegroundColor Green
    
    # Get alert configurations
    Write-ColorOutput "`nLoading alert configurations..." -ForegroundColor Yellow
    $alerts = Get-AlertConfigurations -FunctionName $FunctionAppName -Level $AlertLevel -IncludeInformational:$EnableInformationalAlerts
    Write-ColorOutput "  ✓ Loaded $($alerts.Count) alert configuration(s)" -ForegroundColor Green
    
    # Deploy via Bicep or direct API
    if ($UseBicepDeployment) {
        Write-ColorOutput "`nDeploying via Bicep template..." -ForegroundColor Yellow
        
        $bicepFile = Join-Path $PSScriptRoot "modules\alertRules.bicep"
        if (-not (Test-Path $bicepFile)) {
            throw "Bicep template not found: $bicepFile"
        }
        
        $deploymentName = "shr-alerts-$FunctionAppName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        $parameters = @{
            functionAppName = $FunctionAppName
            applicationInsightsResourceId = $functionApp.ApplicationInsightId
            actionGroupResourceId = $ActionGroupResourceId
            location = $functionApp.Location
            alertLevel = $AlertLevel
            enableAlerts = -not $DisableAlerts.IsPresent
        }
        
        if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Deploy Bicep template with $($alerts.Count) alerts")) {
            $deployment = New-AzResourceGroupDeployment `
                -Name $deploymentName `
                -ResourceGroupName $ResourceGroupName `
                -TemplateFile $bicepFile `
                -TemplateParameterObject $parameters `
                -ErrorAction Stop
            
            Write-ColorOutput "`n  ✓ Bicep deployment successful" -ForegroundColor Green
            Write-ColorOutput "    Deployment name: $deploymentName" -ForegroundColor Gray
            Write-ColorOutput "    Alerts deployed: $($deployment.Outputs.deployedAlertCount.Value)" -ForegroundColor Gray
        }
    }
    else {
        # Deploy directly via PowerShell
        Write-ColorOutput "`nDeploying alerts..." -ForegroundColor Yellow
        
        $successCount = 0
        $failureCount = 0
        
        foreach ($alert in $alerts) {
            $alertName = $alert.Name
            
            if ($PSCmdlet.ShouldProcess($alertName, "Create alert rule")) {
                try {
                    Write-ColorOutput "  Creating: $($alert.DisplayName)..." -ForegroundColor Gray
                    
                    # Create condition
                    $condition = New-AzScheduledQueryRuleCondition `
                        -Query $alert.Query `
                        -TimeAggregation 'Count' `
                        -Operator 'GreaterThanOrEqual' `
                        -Threshold $alert.Threshold `
                        -ErrorAction Stop
                    
                    # Create alert rule
                    $null = New-AzScheduledQueryRule `
                        -Name $alertName `
                        -ResourceGroupName $ResourceGroupName `
                        -Location $functionApp.Location `
                        -DisplayName $alert.DisplayName `
                        -Description $alert.Description `
                        -Scope $functionApp.ApplicationInsightId `
                        -Severity $alert.Severity `
                        -WindowSize $alert.TimeWindow `
                        -EvaluationFrequency $alert.Frequency `
                        -Condition $condition `
                        -ActionGroup $ActionGroupResourceId `
                        -Enabled:($alert.Enabled -and -not $DisableAlerts.IsPresent) `
                        -AutoMitigate `
                        -Tag @{
                            'monitoring-category' = 'SessionHostReplacer'
                            'alert-severity' = $alert.Severity.ToString()
                            'deployed-by' = 'Deploy-SessionHostReplacerAlerts.ps1'
                        } `
                        -ErrorAction Stop
                    
                    Write-ColorOutput "    ✓ Deployed" -ForegroundColor Green
                    $successCount++
                }
                catch {
                    Write-ColorOutput "    ✗ Failed: $_" -ForegroundColor Red
                    $failureCount++
                }
            }
        }
        
        # Summary
        Write-ColorOutput "`n==================================================" -ForegroundColor Cyan
        Write-ColorOutput "Deployment Summary" -ForegroundColor Cyan
        Write-ColorOutput "==================================================" -ForegroundColor Cyan
        Write-ColorOutput "  Successfully deployed: $successCount" -ForegroundColor Green
        if ($failureCount -gt 0) {
            Write-ColorOutput "  Failed: $failureCount" -ForegroundColor Red
        }
        Write-ColorOutput "  Total alerts: $($alerts.Count)" -ForegroundColor White
    }
    
    # Display next steps
    Write-ColorOutput "`n==================================================" -ForegroundColor Cyan
    Write-ColorOutput "Next Steps" -ForegroundColor Cyan
    Write-ColorOutput "==================================================" -ForegroundColor Cyan
    Write-ColorOutput "1. Verify alerts in Azure Portal:" -ForegroundColor White
    Write-ColorOutput "   Monitor > Alerts > Alert rules" -ForegroundColor Gray
    Write-ColorOutput "`n2. Test alert notifications:" -ForegroundColor White
    Write-ColorOutput "   Trigger a test condition and verify Action Group receives notification" -ForegroundColor Gray
    Write-ColorOutput "`n3. Review and tune thresholds after 1 week of operation" -ForegroundColor White
    Write-ColorOutput "`n4. Consider creating a Log Analytics dashboard for trending" -ForegroundColor White
    Write-ColorOutput "   See ALERTS.md for recommended queries" -ForegroundColor Gray
    Write-ColorOutput "`n==================================================" -ForegroundColor Cyan
    
}
catch {
    Write-ColorOutput "`n✗ Deployment failed: $_" -ForegroundColor Red
    Write-ColorOutput $_.ScriptStackTrace -ForegroundColor Red
    throw
}
