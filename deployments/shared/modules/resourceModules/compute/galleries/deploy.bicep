@sys.description('Required. Name of the Azure Compute Gallery.')
@minLength(1)
param name string

@sys.description('Optional. Location for all resources.')
param location string = resourceGroup().location

@sys.description('Optional. Tags to apply to the gallery.')
param tags object = {}

@sys.description('Optional. Description of the Azure Compute Gallery.')
param description string = ''

resource gallery 'Microsoft.Compute/galleries@2022-03-03' = {
  name: name
  location: location
  tags: tags
  properties: {
    description: description
  }
}

output resourceId string = gallery.id
output name string = gallery.name
