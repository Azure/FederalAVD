// Sample Azure VM Image Builder (AIB) template: apply DoD STIGs using
// customer-examples/artifacts/DoD-STIGs/Apply-STIGsAVD.ps1 with -ExecutionProfile AzureVMImageBuilder.
//
// Unlike the Packer stigs/ sample, there is no separate "finalizer" customizer to add: AIB always
// invokes C:\DeprovisioningScript.ps1 as a hidden final customizer after everything below, and
// Apply-STIGsAVD.ps1 -ExecutionProfile AzureVMImageBuilder already copies
// azure-vm-image-builder/DeprovisioningScript.ps1 to that exact path itself (and records the
// effective domain-joined state to a state file DeprovisioningScript.ps1 reads automatically -- no
// separate -IntendedDomainJoined flag to keep in sync, unlike the Packer finalizer). See
// customer-examples/artifacts/DoD-STIGs/azure-vm-image-builder/README.md and ../README.md.
//
// Both Apply-STIGsAVD.ps1 and its azure-vm-image-builder/DeprovisioningScript.ps1 sibling are
// embedded directly into this template (loadTextContent) and written to the build VM preserving
// their relative folder structure, because Apply-STIGsAVD.ps1 looks for
// '$PSScriptRoot/azure-vm-image-builder/DeprovisioningScript.ps1' next to itself.

@description('Azure region for the image template and build VM. Must support Azure VM Image Builder.')
param location string

@description('Name of the Microsoft.VirtualMachineImages/imageTemplates resource.')
param imageTemplateName string

@description('Resource ID of the user-assigned identity AIB uses to manage the image template itself (read/write the gallery image). Needs Contributor on this resource group and the gallery.')
param imageTemplateIdentityResourceId string

@description('Resource ID of the user-assigned identity attached to the build VM. Not required for STIGs specifically (Apply-STIGsAVD.ps1 downloads the STIG GPO package over plain HTTPS), but still needed for AIB image template/gallery access and kept for parity with the software-install sample.')
param buildVmIdentityResourceId string = ''

@description('Resource ID of an existing subnet for the build VM. No public IP is created when this is set.')
param subnetResourceId string

param vmSize string = 'Standard_D4ads_v6'
param osDiskSizeGB int = 0

@description('Marketplace source image.')
param imagePublisher string
param imageOffer string
param imageSku string

@description('Resource ID of the destination Compute Gallery image definition, e.g. .../galleries/<gallery>/images/<definition>.')
param galleryImageDefinitionResourceId string

@description('Image version to publish. Leave blank to let AIB auto-generate one.')
param imageVersion string = ''

param targetRegions array = [
  {
    name: location
    replicaCount: 1
    storageAccountType: 'Standard_LRS'
  }
]

param excludeFromLatest bool = false

param installUpdates bool = false

@description('Optional override of the default third-party applications STIG-hardened by Apply-STIGsAVD.ps1. Leave empty to use the script default list.')
param applicationsToStig array = []

@description('Passed to Apply-STIGsAVD.ps1 as -OverrideDomainJoin. Only set true when the captured image is guaranteed to join a domain.')
param overrideDomainJoin bool = false

param buildTimeoutInMinutes int = 180

@description('Optional. Resource ID of an existing, empty resource group for AIB to use as its staging resource group instead of creating an ephemeral "IT_*" one. Must be empty, in the same region as this template, and already granted Contributor (or Owner) on imageTemplateIdentityResourceId before this deploys. See ../README.md "Staging Resource Group".')
param stagingResourceGroupResourceId string = ''

@description('Optional. Tags applied to the resources AIB creates inside the staging resource group (its own storage account, VNet/NSG, container instance, etc.), useful for satisfying tag-based Azure Policy requirements without a custom stagingResourceGroupResourceId.')
param managedResourceTags object = {}

param tags object = {}

// Builds a PowerShell customizer's inline command array: writes scriptContent to destinationPath
// via a single-quoted here-string (no $variable expansion of the pasted script's own content),
// then runs invocation.
func buildEmbeddedScriptInline(scriptContent string, destinationPath string, invocation string) string[] => concat(
  [
    'New-Item -Path (Split-Path -Path \'${destinationPath}\' -Parent) -ItemType Directory -Force | Out-Null'
    '$ScriptContent = @\''
  ],
  split(scriptContent, ['\r\n', '\n']),
  [
    '\'@'
    'Set-Content -LiteralPath \'${destinationPath}\' -Value $ScriptContent -Encoding UTF8'
    invocation
  ]
)

var applyStigsRemotePath = 'C:\\Windows\\Temp\\aibScripts\\Apply-STIGsAVD.ps1'
var deprovisioningScriptRemotePath = 'C:\\Windows\\Temp\\aibScripts\\azure-vm-image-builder\\DeprovisioningScript.ps1'

var applicationsToStigArgument = empty(applicationsToStig) ? '' : ' -ApplicationsToSTIG ${string(applicationsToStig)}'
var overrideDomainJoinArgument = overrideDomainJoin ? ' -OverrideDomainJoin' : ''
var applyStigsInvocation = '& \'${applyStigsRemotePath}\' -ExecutionProfile AzureVMImageBuilder${applicationsToStigArgument}${overrideDomainJoinArgument}'

var windowsUpdateCustomizers = installUpdates ? [
  {
    type: 'WindowsUpdate'
    searchCriteria: 'IsInstalled=0'
    filters: [
      'exclude:$_.Title -like \'*Preview*\''
      'include:$true'
    ]
    updateLimit: 40
  }
  {
    type: 'WindowsRestart'
    restartTimeout: '30m'
  }
] : []

// Stage azure-vm-image-builder/DeprovisioningScript.ps1 in the same relative folder as
// Apply-STIGsAVD.ps1 BEFORE Apply-STIGsAVD.ps1 runs, since it copies that file from
// $PSScriptRoot\azure-vm-image-builder\DeprovisioningScript.ps1 to C:\DeprovisioningScript.ps1
// itself and throws if it isn't found there.
var stageDeprovisioningScriptCustomizer = {
  type: 'PowerShell'
  name: 'StageAibDeprovisioningScript'
  runElevated: true
  runAsSystem: true
  inline: buildEmbeddedScriptInline(
    loadTextContent('../../artifacts/DoD-STIGs/azure-vm-image-builder/DeprovisioningScript.ps1'),
    deprovisioningScriptRemotePath,
    'Write-Output \'DeprovisioningScript.ps1 staged.\''
  )
}

var applyStigsCustomizer = {
  type: 'PowerShell'
  name: 'ApplySTIGs'
  runElevated: true
  runAsSystem: true
  inline: buildEmbeddedScriptInline(
    loadTextContent('../../artifacts/DoD-STIGs/Apply-STIGsAVD.ps1'),
    applyStigsRemotePath,
    applyStigsInvocation
  )
}

resource imageTemplate 'Microsoft.VirtualMachineImages/imageTemplates@2024-02-01' = {
  name: imageTemplateName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${imageTemplateIdentityResourceId}': {}
    }
  }
  properties: {
    buildTimeoutInMinutes: buildTimeoutInMinutes
    stagingResourceGroup: empty(stagingResourceGroupResourceId) ? null : stagingResourceGroupResourceId
    managedResourceTags: managedResourceTags
    source: {
      type: 'PlatformImage'
      publisher: imagePublisher
      offer: imageOffer
      sku: imageSku
      version: 'latest'
    }
    vmProfile: {
      vmSize: vmSize
      osDiskSizeGB: osDiskSizeGB
      userAssignedIdentities: empty(buildVmIdentityResourceId) ? [] : [
        buildVmIdentityResourceId
      ]
      vnetConfig: {
        subnetId: subnetResourceId
      }
    }
    // Apply STIGs last, after all software/updates/restarts (see the DoD-STIGs Packer/AIB README
    // build-order rationale). Do not add customizers after ApplySTIGs -- AIB's hidden final
    // customizer (C:\DeprovisioningScript.ps1) runs automatically once this array finishes.
    customize: concat(
      windowsUpdateCustomizers,
      [
        stageDeprovisioningScriptCustomizer
        applyStigsCustomizer
      ]
    )
    distribute: [
      {
        type: 'SharedImage'
        galleryImageId: empty(imageVersion) ? galleryImageDefinitionResourceId : '${galleryImageDefinitionResourceId}/versions/${imageVersion}'
        runOutputName: '${imageTemplateName}-output'
        excludeFromLatest: excludeFromLatest
        targetRegions: targetRegions
      }
    ]
    autoRun: {
      state: 'Enabled'
    }
  }
}

output imageTemplateResourceId string = imageTemplate.id
