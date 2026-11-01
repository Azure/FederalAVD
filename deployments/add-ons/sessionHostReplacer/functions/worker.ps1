param($WorkItem)

$ErrorActionPreference = 'Stop'
Invoke-ShrContinuation -WorkItem $WorkItem -CyclePath (Join-Path $PSScriptRoot '..\shr-cycle.ps1')
