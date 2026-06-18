#!/usr/bin/env python3
"""
Refactor keyVaults/uiFormDefinition.json: remove enableCustomNaming toggle, set CAF defaults.
"""
import json, sys

UI = 'deployments/keyVaults/uiFormDefinition.json'
d = json.load(open(UI, encoding='utf-8-sig'))

# ─── Helpers ──────────────────────────────────────────────────────────────────

def extract_if_true(expr, cond_prefix):
    """Given "[if(COND, TRUE, FALSE)]" return "[TRUE]"."""
    inner = expr.strip()[1:-1]
    full = f'if({cond_prefix},'
    if not inner.startswith(full):
        raise ValueError(f'Prefix not found.\n  Expected: {full[:80]}\n  Got: {inner[:80]}')
    rest = inner[len(full):].lstrip(' ')
    depth = 0
    for i, c in enumerate(rest):
        if c == '(': depth += 1
        elif c == ')':
            if depth == 0: break
            depth -= 1
        elif c == ',' and depth == 0:
            return f'[{rest[:i].rstrip()}]'
    raise ValueError(f'Comma not found in: {rest[:120]}')

def strip_first_and_arg(expr, arg):
    """
    Remove ARG from the first position in and(...).
    Handles both 2-arg: [and(ARG, X)] → [X]
    and multi-arg: [and(ARG, X, Y, ...)] → [and(X, Y, ...)]
    Also handles no-space after comma: [and(ARG,X)].
    """
    inner = expr.strip()[1:-1]
    # Try both with and without space after comma
    for full in (f'and({arg}, ', f'and({arg},'):
        if inner.startswith(full):
            rest = inner[len(full):]
            break
    else:
        raise ValueError(f'and() prefix not found.\n  Expected: and({arg[:40]}, ...\n  Got: {inner[:80]}')
    # Walk to find where X ends (first outer-level comma or closing paren)
    depth = 0
    for i, c in enumerate(rest):
        if c == '(': depth += 1
        elif c == ')':
            if depth == 0:
                # 2-arg: [and(ARG, X)] → [X]
                x = rest[:i]
                after = rest[i+1:]
                if after == '':
                    return f'[{x}]'
                raise ValueError(f'Unexpected after paren: {after[:60]}')
            depth -= 1
        elif c == ',' and depth == 0:
            # Multi-arg: rest[:i] is X, rest[i+1:] (stripped) is "Y, ...)"
            x = rest[:i]
            remaining = rest[i+1:].lstrip(' ')  # "Y, ...)"
            if remaining.endswith(')'):
                inner_args = remaining[:-1]
                return f'[and({x},{inner_args})]'
            raise ValueError(f'Expected ) at end: {remaining[:60]}')
    raise ValueError(f'Parse failed: {rest[:120]}')

EN = "steps('tagsAndNaming').naming.enableCustomNaming"

# ─── Find naming section ──────────────────────────────────────────────────────
steps = d['view']['properties']['steps']
tn = next(s for s in steps if s['name'] == 'tagsAndNaming')
naming_section = next(e for e in tn['elements'] if e.get('name') == 'naming')
naming_elems = naming_section['elements']

# ─── 1. Update description ────────────────────────────────────────────────────
desc = next((e for e in naming_elems if e.get('name') == 'namingDescription'), None)
if desc:
    desc['options']['text'] = (
        "Define your naming convention using the components below. "
        "The defaults follow the Cloud Adoption Framework (CAF) naming convention: "
        "{resource-type}-avd-{identifier}-{region}. "
        "Adjust the component order, separator, workload value, or abbreviations to match your organization's standard."
    )
    print('  OK: updated namingDescription')

# ─── 2. Remove enableCustomNaming ────────────────────────────────────────────
before = len(naming_elems)
naming_elems[:] = [e for e in naming_elems if e.get('name') != 'enableCustomNaming']
print(f'  OK: removed enableCustomNaming ({before} → {len(naming_elems)} elements)')

# ─── 3. Remove visible from simple enableCustomNaming-gated elements ──────────
for name in ('builderInfo', 'componentGuidanceInfo', 'delimiter',
             'component1', 'component2', 'fslogixStoragePrefixValue'):
    elem = next((e for e in naming_elems if e.get('name') == name), None)
    if elem and 'visible' in elem:
        del elem['visible']
        print(f'  OK: removed visible from {name}')

# ─── 4. Set defaults on component dropdowns ──────────────────────────────────
for name, default in [('component1','resourceType'), ('component2','workload'),
                      ('component3','purpose'), ('component4','location'),
                      ('component5','none'), ('component6','none')]:
    elem = next((e for e in naming_elems if e.get('name') == name), None)
    if elem:
        elem['defaultValue'] = default
        print(f'  OK: set defaultValue={default!r} on {name}')

# ─── 5. Fix component3-6 visible conditions ───────────────────────────────────
for name in ('component3', 'component4', 'component5', 'component6'):
    elem = next((e for e in naming_elems if e.get('name') == name), None)
    if elem and 'visible' in elem:
        old = elem['visible']
        try:
            new = strip_first_and_arg(old, EN)
            elem['visible'] = new
            print(f'  OK: stripped EN from {name} visible')
        except ValueError as ex:
            print(f'  ERROR: {name}: {ex}')

# ─── 6. workloadValue default ────────────────────────────────────────────────
wv = next((e for e in naming_elems if e.get('name') == 'workloadValue'), None)
if wv:
    wv['defaultValue'] = 'avd'
    print('  OK: set defaultValue=avd on workloadValue')

# ─── 7. Strip EN from validation infobox visible conditions ──────────────────
for name in ('noResourceTypeError', 'noPurposeError', 'noWorkloadWarning', 'noLocationWarning',
             'duplicateComponentError', 'kvNameTooLongError', 'kvShortUniqueWarning', 'kvNoLocationInfo'):
    elem = next((e for e in naming_elems if e.get('name') == name), None)
    if elem and 'visible' in elem:
        old = elem['visible']
        try:
            new = strip_first_and_arg(old, EN)
            elem['visible'] = new
            print(f'  OK: stripped EN from {name} visible')
        except ValueError as ex:
            print(f'  ERROR: {name}: {ex}')

# ─── 8. Update namingPreview section ─────────────────────────────────────────
preview_section = next((e for e in tn['elements'] if e.get('name') == 'namingPreview'), None)
if not preview_section:
    print('  ERROR: namingPreview not found')
    sys.exit(1)

for elem in preview_section['elements']:
    nm = elem.get('name', '')
    opts = elem.get('options', {})
    if 'text' in opts and opts['text'].startswith('[if('):
        old = opts['text']
        try:
            new = extract_if_true(old, EN)
            opts['text'] = new
            print(f'  OK: stripped if(EN,...) from preview.{nm} ({len(old)} → {len(new)} chars)')
        except ValueError as ex:
            print(f'  ERROR: preview.{nm}: {ex}')

# ─── 9. Update customNamingConvention output ─────────────────────────────────
outputs = d['view']['outputs']['parameters']
cnv_key = 'customNamingConvention'
if cnv_key in outputs:
    old = outputs[cnv_key]
    try:
        new = extract_if_true(old, EN)
        outputs[cnv_key] = new
        print(f'  OK: stripped if(EN,...) from output.{cnv_key} ({len(old)} → {len(new)} chars)')
    except ValueError as ex:
        print(f'  ERROR: output.{cnv_key}: {ex}')

# ─── Save ─────────────────────────────────────────────────────────────────────
out = json.dumps(d, indent=2, ensure_ascii=False)
with open(UI, 'w', encoding='utf-8-sig', newline='\n') as f:
    f.write(out)
    f.write('\n')

import os
size = os.path.getsize(UI)
print(f'\nSaved {UI}: {size:,} bytes')

full = json.dumps(d)
print(f'enableCustomNaming count: {full.count("enableCustomNaming")}')
