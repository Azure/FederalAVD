using none

import { buildCustomName, cnv, stripSeps, kvSanitize } from '../../deployments/shared/modules/orchestration/naming/naming.bicep'

param defaultName = cnv(['resourceType', 'workload', 'purpose', 'location'], '-', 'rg', 'desktop', 'eus', '', '', '', 'avd')
param reversedName = cnv(['workload', 'purpose', 'location', 'resourceType'], '-', 'kv', 'sec-abc123', 'va', '', '', '', 'avd')
param omittedComponents = cnv(['none', 'unknown', 'resourceType', 'purpose', 'location'], '-', 'rg', '', 'eus', '', '', '', 'avd')
param emptyComponents = cnv([], '-', 'rg', 'desktop', 'eus', '', '', '', 'avd')
param emptyValues = buildCustomName(['resourceType', 'purpose', 'location'], '-', '', '', '', '', '', '', '')
param repeatedComponents = cnv(['resourceType', 'resourceType', 'purpose'], '-', 'rg', 'desktop', '', '', '', '', '')
param emptyDelimiter = cnv(['resourceType', 'workload', 'purpose'], '', 'st', 'images', '', '', '', '', 'avd')
param customComponents = cnv(['freeform1', 'environment', 'workload', 'purpose', 'location', 'freeform2', 'resourceType'], '_', 'rg', 'desktop', 'eus', 'org', 'prod', '01', 'avd')
param preservedWhitespace = buildCustomName(['purpose'], '-', '', ' desktop ', '', '', '', '', '')
param strippedSeparators = stripSeps('Ab-c_d.e')
param sanitizedVault = kvSanitize('Ab_c.d-e')
