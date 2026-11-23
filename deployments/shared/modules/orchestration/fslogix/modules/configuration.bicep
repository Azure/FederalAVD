metadata name = 'Azure Files provisioning configuration'
metadata description = 'Resolves legacy or provisioned-v2 SMB storage settings without changing existing-account resources.'

type filesConfiguration = {
  kind: string
  skuName: string
  accessTier: string
  largeFileSharesState: string
  provisionedIops: int
  provisionedThroughputMiBps: int
}

// Keep billing separate from media: Standard provisioned v2 uses FileStorage, not StorageV2.
// Recommendations follow https://learn.microsoft.com/azure/storage/files/understanding-billing.
// A zero performance input requests the recommendation for this role's own capacity.
@export()
func resolveFilesConfiguration(tier string, redundancy string, billingModel string, capacityGiB int, iops int, throughputMiBps int) filesConfiguration => contains(['Standard', 'Premium'], tier) && contains(['LocallyRedundant', 'ZoneRedundant'], redundancy) && contains(['Legacy', 'ProvisionedV2'], billingModel)
  ? billingModel == 'ProvisionedV2'
    ? (capacityGiB >= 32 && capacityGiB <= 262144 && (iops == 0 || (iops >= (tier == 'Premium' ? 3000 : 500) && iops <= (tier == 'Premium' ? 102400 : 50000))) && (throughputMiBps == 0 || (throughputMiBps >= (tier == 'Premium' ? 100 : 60) && throughputMiBps <= (tier == 'Premium' ? 10340 : 5120))))
        ? {
            kind: 'FileStorage'
            skuName: '${tier}V2${redundancy == 'ZoneRedundant' ? '_ZRS' : '_LRS'}'
            accessTier: ''
            largeFileSharesState: ''
            provisionedIops: iops != 0 ? iops : min(tier == 'Premium' ? 3000 + capacityGiB : 1000 + (capacityGiB + 4) / 5, tier == 'Premium' ? 102400 : 50000)
            provisionedThroughputMiBps: throughputMiBps != 0 ? throughputMiBps : min(tier == 'Premium' ? 100 + (capacityGiB + 9) / 10 : 60 + (capacityGiB + 49) / 50, tier == 'Premium' ? 10340 : 5120)
          }
        : fail('Invalid provisioned-v2 Azure Files sizing. Capacity must be 32-262144 GiB; SSD IOPS 3000-102400 and MiB/s 100-10340; HDD IOPS 500-50000 and MiB/s 60-5120. Zero performance values select recommendations.')
    : capacityGiB >= (tier == 'Premium' ? 100 : 1) && capacityGiB <= 102400 && iops == 0 && throughputMiBps == 0
      ? {
          kind: tier == 'Standard' ? 'StorageV2' : 'FileStorage'
          skuName: '${tier}${redundancy == 'ZoneRedundant' ? '_ZRS' : '_LRS'}'
          accessTier: tier == 'Premium' ? 'Premium' : 'TransactionOptimized'
          largeFileSharesState: tier == 'Standard' ? 'Enabled' : ''
          provisionedIops: 0
          provisionedThroughputMiBps: 0
        }
      : fail('Legacy Azure Files capacity must be 1-102400 GiB (SSD minimum 100 GiB). Explicit IOPS and throughput require ProvisionedV2 billing.')
  : fail('Unsupported Azure Files tier, redundancy, or billing model.')
