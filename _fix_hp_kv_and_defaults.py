"""
Fix hostpool uiFormDefinition.json KV warning section (same as applied to keyVaults):
  1. sec-{unique} placeholder -> sec-xxxxxx in length-calc expressions
  2. kvNameTooLongError: style Error -> Warning, rename, update text
  3. Remove kvShortUniqueWarning block

Also revert component5/component6 defaultValue from label "None (stop here)"
back to value "none" in all three forms — portal was returning the label string
literally rather than looking up the corresponding value, breaking
equals(componentN, 'none') checks in all expressions.
"""
import json, pathlib

# ── Part 1: Fix hostpool KV warning section ─────────────────────────────────

hp_path = pathlib.Path('deployments/hostpools/uiFormDefinition.json')
text = hp_path.read_text(encoding='utf-8')

# 1a. Rename kvNameTooLongError -> kvNameTruncationWarning
text = text.replace('"name": "kvNameTooLongError"', '"name": "kvNameTruncationWarning"')

# 1b. In the truncation block, change sec-{unique} -> sec-xxxxxx in length calcs
#     (only in the kvNameTruncationWarning block visible/text expressions,
#      NOT in the previewKvSecrets/previewKvEncryption display lines)
#     The truncation block appears before the rtCode fields.
#     Strategy: process the block between kvNameTruncationWarning and kvShortUniqueWarning.
start_marker = '"name": "kvNameTruncationWarning"'
end_marker   = '"name": "kvShortUniqueWarning"'
start_idx = text.index(start_marker)
end_idx   = text.index(end_marker)
trunc_block = text[start_idx:end_idx]
trunc_block = trunc_block.replace(",'purpose'),'sec-{unique}',", ",'purpose'),'sec-xxxxxx',")
# Change style Error -> Warning inside this block
trunc_block = trunc_block.replace('"style": "Error"', '"style": "Warning"')
# Update the text message
trunc_block = trunc_block.replace(
    'characters \u2014 Azure Key Vault names cannot exceed 24 characters. Shorten your naming convention before deploying Key Vaults.',
    'characters \u2014 the name will be automatically truncated to 24 characters at deployment. Consider shortening your naming convention to preserve uniqueness.'
)
text = text[:start_idx] + trunc_block + text[end_idx:]

# 1c. Remove kvShortUniqueWarning block entirely
#     Find from the opening { of kvShortUniqueWarning to its closing },
kw_start = text.index('"name": "kvShortUniqueWarning"')
# Walk back to the opening { of this element
brace_start = text.rindex('{', 0, kw_start)
# Walk forward to find the matching closing }
depth = 0
pos = brace_start
while pos < len(text):
    if text[pos] == '{':
        depth += 1
    elif text[pos] == '}':
        depth -= 1
        if depth == 0:
            brace_end = pos
            break
    pos += 1
# Also consume the trailing comma + newline if present
end_consume = brace_end + 1
while end_consume < len(text) and text[end_consume] in (',', '\n', '\r', ' '):
    if text[end_consume] == ',':
        end_consume += 1
        break
    end_consume += 1

text = text[:brace_start] + text[end_consume:]
hp_path.write_text(text, encoding='utf-8')
# Verify JSON still valid
json.loads(text)
print('hostpools: KV section fixed, JSON valid')

# ── Part 2: Revert component5/6 defaultValue to "none" in all 3 forms ────────

FILES = [
    'deployments/keyVaults/uiFormDefinition.json',
    'deployments/hostpools/uiFormDefinition.json',
    'deployments/imageManagement/uiFormDefinition.json',
]

REVERT = {
    'component5': 'none',
    'component6': 'none',
}

def revert_defaults(elements):
    changed = 0
    for el in elements:
        name = el.get('name', '')
        if name in REVERT and el.get('type') == 'Microsoft.Common.DropDown':
            target = REVERT[name]
            if el.get('defaultValue') != target:
                old = el.get('defaultValue', 'MISSING')
                el['defaultValue'] = target
                print(f'    {name}: {old!r} -> {target!r}')
                changed += 1
        if 'elements' in el:
            changed += revert_defaults(el['elements'])
    return changed

for fpath in FILES:
    p = pathlib.Path(fpath)
    ui = json.loads(p.read_text(encoding='utf-8'))
    steps = ui['view']['properties']['steps']
    total = 0
    print(f'\n{fpath}')
    for step in steps:
        total += revert_defaults(step.get('elements', []))
    if total == 0:
        print('  (no changes needed)')
    else:
        p.write_text(json.dumps(ui, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        json.loads(p.read_text(encoding='utf-8'))  # validate
        print(f'  Wrote {total} change(s), JSON valid')

print('\nDone.')
