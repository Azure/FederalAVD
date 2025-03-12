param name string
param location string = resourceGroup().location
param galleryName string
param architecture string = 'x64'
param osType string
param osState string
param publisher string
param offer string
param sku string
param minRecommendedvCPUs int = 1
param maxRecommendedvCPUs int = 4
param minRecommendedMemory int = 4
param maxRecommendedMemory int = 16
param hyperVGeneration string = 'V2'
param features array = []
param description string = ''
param eula string = ''
param privacyStatementUri string = ''
param releaseNoteUri string = ''
param endOfLife string = ''
param tags object = {}

resource gallery 'Microsoft.Compute/galleries@2022-03-03' existing = {
  name: galleryName
}

resource image 'Microsoft.Compute/galleries/images@2022-03-03' = {
  location: location
  name: name
  parent: gallery
  properties: {
    architecture: architecture == 'x64' && hyperVGeneration == 'V2' ? architecture : null
    osType: osType
    osState: osState
    identifier: {
      publisher: publisher
      offer: offer
      sku: sku
    }
    recommended: {
      vCPUs: {
        min: minRecommendedvCPUs
        max: maxRecommendedvCPUs
      }
      memory: {
        min: minRecommendedMemory
        max: maxRecommendedMemory
      }
    }
    hyperVGeneration: hyperVGeneration
    features: features
    description: description
    eula: !empty(eula) ? eula : null
    privacyStatementUri: privacyStatementUri
    releaseNoteUri: releaseNoteUri
    endOfLifeDate: endOfLife
  }
  tags: tags
}

@sys.description('The resource ID of the image.')
output resourceId string = image.id

@sys.description('The name of the image.')
output name string = image.name

@sys.description('The location the resource was deployed into.')
output location string = image.location
