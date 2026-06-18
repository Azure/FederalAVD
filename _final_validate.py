import json

files = [
    ('keyVaults',       'deployments/keyVaults/uiFormDefinition.json'),
    ('hostpools',       'deployments/hostpools/uiFormDefinition.json'),
    ('imageManagement', 'deployments/imageManagement/uiFormDefinition.json'),
]

for label, f in files:
    txt = open(f, encoding='utf-8').read()
    json.loads(txt)  # validates
    checks = ['JSON OK']
    if label == 'keyVaults':
        checks.append('sec-xxxxxx=' + str('sec-xxxxxx' in txt))
        checks.append('old-placeholder=' + str('sec-{unique}' in txt and 'display' not in txt))
        checks.append('warn-gone=' + str('kvShortUniqueWarning' not in txt))
        checks.append('truncation-note=' + str('truncated to 24 by the deployment' in txt))
    print(label + ': ' + ', '.join(checks))
