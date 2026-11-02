import { osDiskNamePattern } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'

@description('Default OS disk pattern loaded without unrelated naming policy data.')
output pattern string = osDiskNamePattern
