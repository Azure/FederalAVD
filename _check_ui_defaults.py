"""
Report component dropdown defaults across all UI form definition files.
"""
import json, pathlib

TARGETS = [
    'deployments/keyVaults/uiFormDefinition.json',
    'deployments/hostpools/uiFormDefinition.json',
    'deployments/imageManagement/uiFormDefinition.json',
    'deployments/imageBuild/uiFormDefinition.json',
    'deployments/networking/uiFormDefinition.json',
]

def find_el(elements, name):
    for e in elements:
        if e.get('name') == name:
            return e
        if 'elements' in e:
            r = find_el(e['elements'], name)
            if r:
                return r
    return None

for fpath in TARGETS:
    p = pathlib.Path(fpath)
    if not p.exists():
        print(f'NOT FOUND: {fpath}')
        continue
    ui = json.loads(p.read_text(encoding='utf-8'))
    steps = ui['view']['properties']['steps']
    # find any step with a 'naming' section
    naming = None
    for step in steps:
        naming = find_el(step.get('elements', []), 'naming')
        if naming:
            break
    if not naming:
        print(f'{fpath}: no naming section found')
        continue
    print(f'\n=== {fpath} ===')
    for el in naming['elements']:
        t = el.get('type', '')
        if t == 'Microsoft.Common.DropDown' and el['name'].startswith('component'):
            dv = el.get('defaultValue', 'MISSING')
            print(f"  {el['name']}: defaultValue={dv!r}")
