metadata name = 'Session host batch output adapter'
metadata description = 'Flattens per-batch VM name arrays into one ordered VM name array without deploying resources.'

@description('Required. Array of per-batch VM name arrays, in deployment batch order.')
param virtualMachineNamesPerBatch array

@description('Flattened VM name strings preserving batch order and name order within each batch.')
output virtualMachineNames array = flatten(virtualMachineNamesPerBatch)
