// Test-RunCommandOutput.bicep
//
// Demonstrates two patterns for getting Run Command output back into ARM:
//
//   Pattern A — outputBlobUri
//     The run command writes stdout to a storage blob. Good for large output /
//     persistent logs. Requires a storage account and managed identity.
//
//   Pattern B — instanceView via deploymentScript
//     After the run command completes, a deploymentScript calls the ARM REST
//     API to read instanceView.output (~4 KB limit) and surfaces it as a
//     typed deployment output. No storage account required.
//
// Deploy:
//   az deployment group create \
//     --resource-group <rg> \
//     --template-file Test-RunCommandOutput.bicep \
//     --parameters vmName=<vmName> userAssignedIdentityResourceId=<id>

targetScope = 'resourceGroup'

@description('Name of an existing VM in this resource group to run the command against.')
param vmName string

@description('Resource ID of a user-assigned managed identity with "Virtual Machine Contributor" on the VM and "Storage Blob Data Contributor" on the storage account (Pattern A only).')
param userAssignedIdentityResourceId string

param location string = resourceGroup().location

// ── shared ──────────────────────────────────────────────────────────────────


var armEndpoint = environment().resourceManager

resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' existing = {
  name: vmName
}

// The run command completes, then a deploymentScript reads instanceView.output
// from the ARM REST API and returns it as a deployment output.
// instanceView.output is capped at ~4 KB — suitable for structured JSON results,
// not large logs.

resource runCommandPatternB 'Microsoft.Compute/virtualMachines/runCommands@2023-03-01' = {
  name: 'test-output-patternB'
  location: location
  parent: vm
  properties: {
    asyncExecution: false
    source: {
      script: '''
        $os   = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion')
        $disk = Get-PSDrive C | Select-Object Used, Free
        # Write structured JSON to stdout — this lands in instanceView.output
        [PSCustomObject]@{
          Hostname    = $env:COMPUTERNAME
          OSBuild     = "$($os.CurrentBuild).$($os.UBR)"
          OSVersion   = $os.DisplayVersion
          DiskUsedGB  = [math]::Round($disk.Used / 1GB, 1)
          DiskFreeGB  = [math]::Round($disk.Free / 1GB, 1)
          Timestamp   = (Get-Date -Format 'o')
        } | ConvertTo-Json -Compress
      '''
    }
    treatFailureAsDeploymentFailure: true
  }
}

// After runCommandPatternB completes, this deploymentScript reads the
// instanceView via the ARM REST API and surfaces the output field.
resource readInstanceView 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'read-runCommand-instanceView'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    azPowerShellVersion: '12.0'
    retentionInterval: 'PT1H'
    timeout: 'PT5M'
    arguments: '-SubscriptionId ${subscription().subscriptionId} -ResourceGroup ${resourceGroup().name} -VmName ${vmName} -RunCommandName ${runCommandPatternB.name} -ArmEndpoint ${armEndpoint}'
    scriptContent: '''
      param(
        [string]$SubscriptionId,
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$RunCommandName,
        [string]$ArmEndpoint
      )

      $token = (Get-AzAccessToken -ResourceUrl $ArmEndpoint).Token
      $base  = $ArmEndpoint.TrimEnd('/')
      $uri   = "$base/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
               "/providers/Microsoft.Compute/virtualMachines/$VmName/runCommands/$RunCommandName" +
               '?$expand=instanceView&api-version=2023-03-01'

      $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" } -Method Get

      $iv = $response.properties.instanceView
      Write-Output "ExecutionState : $($iv.executionState)"
      Write-Output "ExitCode       : $($iv.exitCode)"
      Write-Output "Output         : $($iv.output)"

      # Surface as a typed deployment output via $DeploymentScriptOutputs
      $DeploymentScriptOutputs = @{}
      $DeploymentScriptOutputs['executionState'] = $iv.executionState
      $DeploymentScriptOutputs['exitCode']       = $iv.exitCode
      $DeploymentScriptOutputs['output']         = $iv.output
    '''
  }
  dependsOn: []
}

// ── Deployment outputs ────────────────────────────────────────────────────────
// These are visible in the portal under Deployments > Outputs, and returned
// by: az deployment group show --query properties.outputs

output patternB_executionState string = readInstanceView.properties.outputs.executionState
output patternB_exitCode int = readInstanceView.properties.outputs.exitCode
// The raw JSON string written to stdout by the run command
output patternB_rawOutput string = readInstanceView.properties.outputs.output
