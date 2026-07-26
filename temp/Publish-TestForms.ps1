# Publish-TestForms.ps1
# Publishes one or all test forms to Azure as template specs so they can be tested in the Portal.
#
# Usage:
#   .\Publish-TestForms.ps1 -TestNumber 1              # publish test-1 only
#   .\Publish-TestForms.ps1 -TestNumber 2
#   .\Publish-TestForms.ps1 -TestNumber 3
#   .\Publish-TestForms.ps1 -All                       # publish all three
#
# After publishing, open the Portal URL printed at the end to test.

param(
    [Parameter(ParameterSetName = 'Single', Mandatory)]
    [ValidateRange(1, 3)]
    [int]$TestNumber,

    [Parameter(ParameterSetName = 'All', Mandatory)]
    [switch]$All,

    [string]$ResourceGroupName = 'rg-avd-operations-use2',
    [string]$Location          = 'eastus2'
)

$ErrorActionPreference = 'Stop'
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateFile = Join-Path $scriptDir 'simple-template.json'

$tests = @(
    @{ Number = 1; Name = 'ts-avd-test-form-1-basics-only';            UIFile = 'test-1-basics-only.json' },
    @{ Number = 2; Name = 'ts-avd-test-form-2-step-level-checkbox';    UIFile = 'test-2-advanced-step-level-checkbox.json' },
    @{ Number = 3; Name = 'ts-avd-test-form-3-broken-sibling-visible'; UIFile = 'test-3-broken-sibling-visible-reference.json' }
)

$toPublish = if ($All) { $tests } else { $tests | Where-Object { $_.Number -eq $TestNumber } }

foreach ($t in $toPublish) {
    $uiFile = Join-Path $scriptDir $t.UIFile
    Write-Host "`nPublishing Test $($t.Number): $($t.Name) ..." -ForegroundColor Cyan

    $params = @{
        Name              = $t.Name
        ResourceGroupName = $ResourceGroupName
        Location          = $Location
        TemplateFile      = $templateFile
        UIFormDefinitionFile = $uiFile
        Version           = '1.0.0'
        Force             = $true
    }

    New-AzTemplateSpec @params

    $sub = (Get-AzContext).Subscription.Id
    $rg  = [System.Web.HttpUtility]::UrlEncode($ResourceGroupName)
    $url = "https://portal.azure.com/#create/Microsoft.Template/uri/" +
           [System.Web.HttpUtility]::UrlEncode(
               "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroupName" +
               "/providers/Microsoft.Resources/templateSpecs/$($t.Name)/versions/1.0.0?api-version=2022-02-01"
           )

    Write-Host "Test $($t.Number) published. Portal link:" -ForegroundColor Green
    Write-Host $url -ForegroundColor Yellow
}

Write-Host "`nDone. Test 2 should reach Review+Create without error (step-level checkbox)." -ForegroundColor Green
Write-Host "Test 3 should reproduce the 'location' error (sibling reference in visible)." -ForegroundColor Red
