import json

def find_all(elements, name, results=None):
    if results is None:
        results = []
    for e in elements:
        if e.get('name') == name:
            results.append(e)
        if 'elements' in e:
            find_all(e['elements'], name, results)
    return results

FILES = [
    'deployments/keyVaults/uiFormDefinition.json',
    'deployments/hostpools/uiFormDefinition.json',
    'deployments/imageManagement/uiFormDefinition.json',
    'deployments/imageBuild/uiFormDefinition.json',
]

for fname in FILES:
    ui = json.loads(open(fname, encoding='utf-8').read())
    steps = ui['view']['properties']['steps']
    all_els = []
    for s in steps:
        all_els.extend(s.get('elements', []))
    label = fname.split('/')[1]
    print(f'\n=== {label} ===')
    for comp in ['component1','component2','component3','component4','component5','component6']:
        found = find_all(all_els, comp)
        if found:
            dv = found[0].get('defaultValue', 'MISSING')
            print(f'  {comp}: {dv!r}')
        else:
            print(f'  {comp}: NOT FOUND')
