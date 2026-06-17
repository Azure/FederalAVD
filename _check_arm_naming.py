import json

arm_text = open('deployments/hostpools/hostpool.json', encoding='utf-8').read()
arm_j = json.loads(arm_text)
vars_j = arm_j.get('variables', {})

bicep_naming_vars = [
    'resourceGroupDeployment','depVirtualMachineName','depVirtualMachineDiskName','depVirtualMachineNicName',
    'resourceGroupOperations','resourceGroupMonitoring','kvBaseSecrets','kvBaseEncryption',
    'dataCollectionEndpointName','logAnalyticsWorkspaceName','globalFeedWorkspaceName',
    'desktopApplicationGroupName','hostPoolName','scalingPlanName',
    'recoveryServicesVaultNameVMs','recoveryServicesVaultNameFSLogix',
    'userAssignedIdentityNameConv','resourceGroupHosts','availabilitySetNameConv',
    'diskAccessName','diskEncryptionSetNameConv','resourceGroupStorage',
    'netAppAccountName','netAppCapacityPoolName',
]
print('=== Naming vars in ARM variables section ===')
for v in bicep_naming_vars:
    val = vars_j.get(v)
    if val is not None:
        print('PRESENT: ' + v + ' -> ' + str(json.dumps(val))[:300])
    else:
        print('MISSING: ' + v)

print()
udf_ref_count = arm_text.count('buildCustomName')
print('buildCustomName refs in ARM:', udf_ref_count)

# Search for cnv UDF by looking for namespace
user_ns_refs = arm_text.count('__bicep.')
print('__bicep. (UDF namespace) refs in ARM:', user_ns_refs)

# Find how resourceGroupDeployment is used in resources
idx = arm_text.find('resourceGroupDeployment')
if idx >= 0:
    print()
    print('First occurrence of resourceGroupDeployment in ARM:')
    print(arm_text[max(0,idx-50):idx+300])
