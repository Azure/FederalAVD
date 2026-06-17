import json, os, pathlib

abbr_path = os.path.normpath(str(pathlib.Path('deployments/hostpools').resolve() / '../../.common/data/resourceAbbreviations.json'))
print('abbr file:', abbr_path)
print('abbr file size:', os.path.getsize(abbr_path), 'bytes')
abbr = json.load(open(abbr_path))
print('abbr key count:', len(abbr))

arm_text = open('deployments/hostpools/hostpool.json', encoding='utf-8').read()
arm_j = json.loads(arm_text)

# Variables section
vars_j = arm_j.get('variables', {})
print('\nARM variable count:', len(vars_j))
for k, v in vars_j.items():
    s = len(json.dumps(v))
    if s > 1000:
        print(f'  Large var "{k}": {s:,} chars')

# Functions section
funcs = arm_j.get('functions', [])
func_text = json.dumps(funcs)
print('\nfunctions section:', f'{len(func_text):,}', 'chars')

# Resources (nested deployments)
resources = arm_j.get('resources', [])
resource_sizes = [(r.get('name','?'), len(json.dumps(r))) for r in resources]
resource_sizes.sort(key=lambda x: -x[1])
print('\nTop 5 largest resources:')
for name, sz in resource_sizes[:5]:
    print(f'  {name}: {sz:,} chars')

total = len(arm_text)
print(f'\nTotal ARM: {total:,} chars = {total/1024:.1f} KB')
print(f'  functions: {len(func_text):,} ({100*len(func_text)/total:.1f}%)')
print(f'  variables: {len(json.dumps(vars_j)):,} ({100*len(json.dumps(vars_j))/total:.1f}%)')
print(f'  resources: {sum(s for _,s in resource_sizes):,} ({100*sum(s for _,s in resource_sizes)/total:.1f}%)')
