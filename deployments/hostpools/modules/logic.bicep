targetScope = 'subscription'

param appGroupSecurityGroups array
param avdPrivateLinkPrivateRoutes string
param globalFeedPrivateEndpointSubnetResourceId string
param dedicatedHostGroupResourceId string
param dedicatedHostResourceId string
param deployFSLogixStorage bool
param deploymentType string
param deployScalingPlan bool = false
param domainName string
param drainMode bool
param fslogixContainerType string
param fslogixFileShareNames object
param fslogixOUPath string
param fslogixShardOptions string
param fslogixShardGroups array
param fslogixStorageService string
param hostPoolType string = 'Pooled DepthFirst'
param identitySolution string
param locations object
param locationVirtualMachines string
param resourceGroupControlPlane string
param resourceGroupDeployment string
param resourceGroupGlobalFeed string
param resourceGroupHosts string
param resourceGroupManagement string
param resourceGroupStorage string
param scalingPlanExclusionTag string
param scalingPlanForceLogoff bool = false
param scalingPlanMinsBeforeLogoff int = 0
param scalingPlanOffPeakSchedule object = {}
param scalingPlanPeakSchedule object = {}
param scalingPlanRampDownSchedule object = {}
param scalingPlanRampUpSchedule object = {}
param sessionHostCount int
param sessionHostIndex int
param tags object
param vmOUPath string
param workspaceResourceId string

var dedicatedHostGroupName = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[8]
  : !empty(dedicatedHostGroupResourceId) ? last(split(dedicatedHostGroupResourceId, '/')) : ''
var dedicatedHostRG = !empty(dedicatedHostResourceId)
  ? split(dedicatedHostResourceId, '/')[4]
  : !empty(dedicatedHostGroupResourceId) ? split(dedicatedHostGroupResourceId, '/')[4] : ''

resource dedicatedHostGroup 'Microsoft.Compute/HostGroups@2020-12-01' existing = if (!empty(dedicatedHostGroupName)) {
  scope: resourceGroup(dedicatedHostRG)
  name: dedicatedHostGroupName
}

var scalingPlanSchedules = deployScalingPlan
  ? [
      {
        rampUpStartTime: {
          hour: first(split(scalingPlanRampUpSchedule.startTime, ':')[0]) == '0'
            ? int(last(split(scalingPlanRampUpSchedule.startTime, ':')[0]))
            : int(split(scalingPlanRampUpSchedule.startTime, ':')[0])
          minute: first(split(scalingPlanRampUpSchedule.startTime, ':')[1]) == '0'
            ? int(last(split(scalingPlanRampUpSchedule.startTime, ':')[1]))
            : int(split(scalingPlanRampUpSchedule.startTime, ':')[1])
        }
        peakStartTime: {
          hour: first(split(scalingPlanPeakSchedule.startTime, ':')[0]) == '0'
            ? int(last(split(scalingPlanPeakSchedule.startTime, ':')[0]))
            : int(split(scalingPlanPeakSchedule.startTime, ':')[0])
          minute: first(split(scalingPlanPeakSchedule.startTime, ':')[1]) == '0'
            ? int(last(split(scalingPlanPeakSchedule.startTime, ':')[1]))
            : int(split(scalingPlanPeakSchedule.startTime, ':')[1])
        }
        rampDownStartTime: {
          hour: first(split(scalingPlanRampDownSchedule.startTime, ':')[0]) == '0'
            ? int(last(split(scalingPlanRampDownSchedule.startTime, ':')[0]))
            : int(split(scalingPlanRampDownSchedule.startTime, ':')[0])
          minute: first(split(scalingPlanRampDownSchedule.startTime, ':')[1]) == '0'
            ? int(last(split(scalingPlanRampDownSchedule.startTime, ':')[1]))
            : int(split(scalingPlanRampDownSchedule.startTime, ':')[1])
        }
        offPeakStartTime: {
          hour: first(split(scalingPlanOffPeakSchedule.startTime, ':')[0]) == '0'
            ? int(last(split(scalingPlanOffPeakSchedule.startTime, ':')[0]))
            : int(split(scalingPlanOffPeakSchedule.startTime, ':')[0])
          minute: first(split(scalingPlanOffPeakSchedule.startTime, ':')[1]) == '0'
            ? int(last(split(scalingPlanOffPeakSchedule.startTime, ':')[1]))
            : int(split(scalingPlanOffPeakSchedule.startTime, ':')[1])
        }
        name: 'weekdays_schedule'
        daysOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
        rampUpLoadBalancingAlgorithm: scalingPlanRampUpSchedule.loadBalancingAlgorithm
        rampUpMinimumHostsPct: scalingPlanRampUpSchedule.minimumHostsPct
        rampUpCapacityThresholdPct: scalingPlanRampUpSchedule.capacityThresholdPct
        peakLoadBalancingAlgorithm: scalingPlanPeakSchedule.loadBalancingAlgorithm
        rampDownLoadBalancingAlgorithm: scalingPlanRampDownSchedule.loadBalancingAlgorithm
        rampDownMinimumHostsPct: scalingPlanRampDownSchedule.minimumHostsPct
        rampDownCapacityThresholdPct: scalingPlanRampDownSchedule.capacityThresholdPct
        rampDownForceLogoffUsers: scalingPlanForceLogoff
        rampDownWaitTimeMinutes: scalingPlanMinsBeforeLogoff
        rampDownNotificationMessage: scalingPlanForceLogoff
          ? 'You will be logged off in ${scalingPlanMinsBeforeLogoff} minutes. Make sure to save your work.'
          : null
        rampDownStopHostsWhen: 'ZeroSessions'
        offPeakLoadBalancingAlgorithm: scalingPlanOffPeakSchedule.loadBalancingAlgorithm
      }
    ]
  : []

var exclusionTag = !empty(scalingPlanExclusionTag)
  ? {
      'Microsoft.Compute/virtualMachines': {
        '${scalingPlanExclusionTag}': ''
      }
    }
  : {}

var varTags = !empty(exclusionTag) ? union(tags, exclusionTag) : tags

//  BATCH SESSION HOSTS
// The following variables are used to determine the batches to deploy any number of AVD session hosts.
var maxResourcesPerTemplateDeployment = 40 // This is the max number of session hosts that can be deployed from the sessionHosts.bicep file in each batch / for loop. Math: (800 - <Number of Static Resources>) / <Number of Looped Resources> 
var divisionValue = sessionHostCount / maxResourcesPerTemplateDeployment // This determines if any full batches are required.
var divisionRemainderValue = sessionHostCount % maxResourcesPerTemplateDeployment // This determines if any partial batches are required.
var sessionHostBatchCount = divisionRemainderValue > 0 ? divisionValue + 1 : divisionValue // This determines the total number of batches needed, whether full and / or partial.

//  BATCH AVAILABILITY SETS
// The following variables are used to determine the number of availability sets.
var maxAvSetMembers = 200 // This is the max number of session hosts that can be deployed in an availability set.
var beginAvSetRange = sessionHostIndex / maxAvSetMembers // This determines the availability set to start with.
var endAvSetRange = (sessionHostCount + sessionHostIndex) / maxAvSetMembers // This determines the availability set to end with.
var availabilitySetsCount = length(range(beginAvSetRange, (endAvSetRange - beginAvSetRange) + 1))

// OTHER LOGIC & COMPUTED VALUES
var fslogixFileShares = fslogixFileShareNames[fslogixContainerType]
// ONLY DEPLOY 1 storage account when Cloud Only identity is used because Sharding is not possible.
var fslogixUserGroups = empty(fslogixShardGroups) ? appGroupSecurityGroups : fslogixShardGroups
var countStorage = identitySolution == 'EntraId' || identitySolution == 'EntraIdIntuneEnrollment' || fslogixShardOptions == 'None'
  ? 1
  : length(fslogixUserGroups)
var netbios = split(domainName, '.')[0]
var pooledHostPool = split(hostPoolType, ' ')[0] == 'Pooled' ? true : false

var resGroupDeployment = deploymentType == 'Complete' || drainMode ? [resourceGroupDeployment] : []
var resGroupHosts = [resourceGroupHosts]
var resGroupControlPlane = empty(workspaceResourceId) ? [resourceGroupControlPlane] : []
var resGroupGlobalFeed = avdPrivateLinkPrivateRoutes == 'All' && !empty(globalFeedPrivateEndpointSubnetResourceId)
  ? [resourceGroupGlobalFeed]
  : []
var resGroupManagement = [resourceGroupManagement]
var resGroupStorage = deployFSLogixStorage ? [resourceGroupStorage] : []

var resourceGroupNames = union(
  resGroupDeployment,
  resGroupHosts,
  resGroupControlPlane,
  resGroupGlobalFeed,
  resGroupManagement,
  resGroupStorage
)

var roleDefinitions = {
  Contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  DesktopVirtualizationApplicationGroupContributor: '86240b0e-9422-4c43-887b-b61143f32ba8'
  DesktopVirtualizationPowerOnContributor: '489581de-a3bd-480d-9518-53dea7416b33'
  DesktopVirtualizationPowerOnOffContributor: '40c5ff49-9181-41f8-ae61-143b0e78555e'
  DesktopVirtualizationSessionHostOperator: '2ad6aaab-ead9-4eaa-8ac5-da422f562408'
  DesktopVirtualizationUser: '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
  DesktopVirtualizationWorkspaceContributor: '21efdde3-836f-432b-bf3d-3e8e734d4b2b'
  KeyVaultCryptoOfficer: '14b46e9e-c2b7-41b4-b07b-48a6ebf60603'
  KeyVaultCryptoServiceEncryptionUser: 'e147488a-f6f5-4113-8e2d-b22465e65bf6'
  KeyVaultCryptoServiceReleaseUser: '08bbd89e-9f13-488c-ac41-acfcb10c90ab'
  KeyVaultReader: '21090545-7ca7-4776-b22c-e363652d74d2'
  Reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  RoleBasedAccessControlAdministrator: 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
  StorageAccountContributor: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
  StorageBlobDataReader: '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  VirtualMachineContributor: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
  VirtualMachineUserLogin: 'fb879df8-f326-4884-b1cf-06f3ad86be52'
}
var SecurityGroupsCount = length(appGroupSecurityGroups)
var smbServerLocation = locations[locationVirtualMachines].abbreviation
var fslogixStorageSku = fslogixStorageService == 'None' ? 'None' : split(fslogixStorageService, ' ')[1]
var fslogixStorageSolution = split(fslogixStorageService, ' ')[0]
var storageSuffix = environment().suffixes.storage

output availabilitySetsCount int = availabilitySetsCount
output beginAvSetRange int = beginAvSetRange
output dedicatedHostGroupZones array = !empty(dedicatedHostGroupName) ? dedicatedHostGroup.zones : []
output divisionRemainderValue int = divisionRemainderValue
output fslogixFileShareNames array = fslogixFileShares
output fslogixOUPath string = empty(fslogixOUPath) ? vmOUPath : fslogixOUPath
output fslogixStorageCount int = countStorage
output fslogixStorageSku string = fslogixStorageSku
output fslogixStorageSolution string = fslogixStorageSolution
output fslogixUserGroups array = fslogixUserGroups
output maxResourcesPerTemplateDeployment int = maxResourcesPerTemplateDeployment
output netbios string = netbios
output pooledHostPool bool = pooledHostPool
output resourceGroupNames array = resourceGroupNames
output roleDefinitions object = roleDefinitions
output scalingPlanSchedules array = scalingPlanSchedules
output sessionHostBatchCount int = sessionHostBatchCount
output SecurityGroupsCount int = SecurityGroupsCount
output smbServerLocation string = smbServerLocation
output storageSuffix string = storageSuffix
output tags object = varTags
