"""
Fix: Azure CreateUI DropDown defaultValue must match the allowedValues label, not the value.
Current: defaultValue="resourceType"  (matches value field — not rendered by portal)
Fixed:   defaultValue="Resource Type" (matches label field — correctly pre-selected)

Applies to component1-6 in all naming convention sections.
"""
import json, pathlib

FILES = [
    'deployments/keyVaults/uiFormDefinition.json',
    'deployments/hostpools/uiFormDefinition.json',
    'deployments/imageManagement/uiFormDefinition.json',
    'deployments/imageBuild/uiFormDefinition.json',
]

# Target value->label mappings we want to set as defaults
DEFAULTS = {
    'component1': 'resourceType',
    'component2': 'workload',
    'component3': 'purpose',
    'component4': 'location',
    'component5': 'none',
    'component6': 'none',
}

def fix_defaults(elements):
    changed = 0
    for el in elements:
        name = el.get('name', '')
        if name in DEFAULTS and el.get('type') == 'Microsoft.Common.DropDown':
            target_value = DEFAULTS[name]
            # Find the label corresponding to the target value
            allowed = el.get('constraints', {}).get('allowedValues', [])
            target_label = None
            for opt in allowed:
                if isinstance(opt, dict) and opt.get('value') == target_value:
                    target_label = opt['label']
                    break
            if target_label and el.get('defaultValue') != target_label:
                old = el.get('defaultValue', 'MISSING')
                el['defaultValue'] = target_label
                print(f"    {name}: {old!r} -> {target_label!r}")
                changed += 1
        if 'elements' in el:
            changed += fix_defaults(el['elements'])
    return changed

for fpath in FILES:
    p = pathlib.Path(fpath)
    if not p.exists():
        print(f'SKIP (not found): {fpath}')
        continue
    ui = json.loads(p.read_text(encoding='utf-8'))
    steps = ui['view']['properties']['steps']
    total = 0
    print(f'\n{fpath}')
    for step in steps:
        total += fix_defaults(step.get('elements', []))
    if total == 0:
        print('  (no changes needed)')
    else:
        p.write_text(json.dumps(ui, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        print(f'  Wrote {total} change(s)')

print('\nDone.')
