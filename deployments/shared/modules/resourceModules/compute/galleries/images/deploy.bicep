param galleryName string
param name string
param location string = resourceGroup().location
param tags object = {}

@description('Architecture of the image definition. Required if HyperVGeneration is V2.')
@allowed(['x64', 'Arm64'])
param architecture string = 'x64'

@description('OS type of the image definition.')
@allowed(['Windows', 'Linux'])
param osType string = 'Windows'

@description('OS state.')
@allowed(['Generalized', 'Specialized'])
param osState string = 'Generalized'

@description('Image publisher name.')
param publisher string

@description('Image offer name.')
param offer string

@description('Image SKU name.')
param sku string

@description('Hyper-V generation.')
@allowed(['V1', 'V2'])
param hyperVGeneration string = 'V2'

@description('Optional. Image definition features (e.g., SecurityType, IsHibernateSupported).')
param features array = []

@description('Optional. End of life date for the image definition.')
param endOfLifeDate string = ''

resource gallery 'Microsoft.Compute/galleries@2022-03-03' existing = {
  name: galleryName
}

resource imageDefinition 'Microsoft.Compute/galleries/images@2022-03-03' = {
  parent: gallery
  name: name
  location: location
  tags: tags
  properties: {
    architecture: architecture == 'x64' && hyperVGeneration == 'V2' ? architecture: null
    osType: osType
    osState: osState
    identifier: {
      publisher: publisher
      offer: offer
      sku: sku
    }
    hyperVGeneration: hyperVGeneration
    features: !empty(features) ? features : null
    endOfLifeDate: !empty(endOfLifeDate) ? endOfLifeDate : null
  }
}

output resourceId string = imageDefinition.id
output name string = imageDefinition.name
