param($Timer)

$ErrorActionPreference = 'Stop'
Invoke-ShrTimer -Trigger Reconciliation -Timer $Timer -CyclePath (Join-Path $PSScriptRoot '..\shr-cycle.ps1')
