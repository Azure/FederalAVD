param($Timer)

$ErrorActionPreference = 'Stop'
Invoke-ShrTimer -Trigger Initiation -Timer $Timer
