#!/usr/bin/env python3
"""
Refactor hostpools/uiFormDefinition.json:
  - Remove enableCustomNaming toggle
  - Set CAF defaults on dropdowns
  - Remove if(enableCustomNaming,...) wrappers from preview + output
  - Strip enableCustomNaming from all visible conditions
  - Rename section description
"""

import json, sys, re

UI = 'deployments/hostpools/uiFormDefinition.json'

d = json.load(open(UI, encoding='utf-8-sig'))

# ─── Helpers ──────────────────────────────────────────────────────────────────

def extract_and_strip(expr, cond_prefix):
    """
    Given "[if(COND_PREFIX, EXPR_TRUE, EXPR_FALSE)]",
    return "[EXPR_TRUE]".
    cond_prefix is the literal text after "if(" and before the first outer comma.
    """
    # Strip [ ]
    inner = expr.strip()
    assert inner.startswith('[') and inner.endswith(']'), f'Not a UI expr: {inner[:80]}'
    inner = inner[1:-1]

    full_prefix = f'if({cond_prefix},'
    if not inner.startswith(full_prefix):
        raise ValueError(f'Prefix not found.\n  Expected: {full_prefix[:80]}\n  Got: {inner[:80]}')

    rest = inner[len(full_prefix):]
    if rest.startswith(' '):
        rest = rest[1:]

    # Walk to find the outer-level comma (depth 0)
    depth = 0
    for i, c in enumerate(rest):
        if c == '(':
            depth += 1
        elif c == ')':
            if depth == 0:
                break
            depth -= 1
        elif c == ',' and depth == 0:
            true_expr = rest[:i].rstrip(' ')
            return f'[{true_expr}]'

    raise ValueError(f'Could not find separator comma in: {rest[:120]}')

def strip_and_condition(expr, cond):
    """
    Given "[and(COND, INNER)]" return "[INNER]".
    COND must be the first argument of the outermost and().
    """
    inner = expr.strip()[1:-1]  # remove [ ]
    full_prefix = f'and({cond},'
    if not inner.startswith(full_prefix):
        raise ValueError(f'and() prefix not found.\n  Expected: {full_prefix[:80]}\n  Got: {inner[:80]}')
    rest = inner[len(full_prefix):]
    if rest.startswith(' '):
        rest = rest[1:]
    # rest ends with the closing ) of and() — find it at depth 0
    depth = 0
    for i, c in enumerate(rest):
        if c == '(':
            depth += 1
        elif c == ')':
            if depth == 0:
                inner_expr = rest[:i].rstrip()
                return f'[{inner_expr}]'
            depth -= 1
    raise ValueError(f'Could not find closing paren in: {rest[:120]}')

def strip_nested_en(expr, en):
    """
    Find the first occurrence of "and(EN, X)" anywhere in expr and replace it with X.
    Used when EN is the first arg of a nested and(), e.g. and(and(EN, A), B) → and(A, B).
    """
    inner = expr.strip()[1:-1]  # remove [ ]
    search = f'and({en}, '
    idx = inner.find(search)
    if idx == -1:
        raise ValueError(f'Pattern not found: and({en[:40]}, ...')
    x_start = idx + len(search)
    depth = 0
    for i in range(x_start, len(inner)):
        c = inner[i]
        if c == '(':
            depth += 1
        elif c == ')':
            if depth == 0:
                x_val = inner[x_start:i]
                replaced = inner[:idx] + x_val + inner[i+1:]
                return f'[{replaced}]'
            depth -= 1
    raise ValueError('Could not find closing paren')

EN = "steps('tagsAndNaming').naming.enableCustomNaming"

# ─── Find naming section ──────────────────────────────────────────────────────
steps = d['view']['properties']['steps']
tn = next(s for s in steps if s['name'] == 'tagsAndNaming')
naming_section = next(e for e in tn['elements'] if e.get('name') == 'naming')
naming_elems = naming_section['elements']

# ─── 1. Update section description (remove checkbox reference) ───────────────
desc = next((e for e in naming_elems if e.get('name') == 'namingDescription'), None)
if desc:
    desc['options']['text'] = (
        "Define your naming convention using the components below. "
        "The defaults follow the Cloud Adoption Framework (CAF) naming convention: "
        "{resource-type}-avd-{identifier}-{region}. "
        "Adjust the component order, separator, workload value, or abbreviations to match your organization's standard."
    )
    print('  OK: updated namingDescription')

# ─── 2. Remove enableCustomNaming checkbox ────────────────────────────────────
before = len(naming_elems)
naming_elems[:] = [e for e in naming_elems if e.get('name') != 'enableCustomNaming']
print(f'  OK: removed enableCustomNaming ({before} → {len(naming_elems)} elements)')

# ─── 3. Remove visible from elements that were gated on enableCustomNaming ────
for name in ('builderInfo', 'componentGuidanceInfo', 'delimiter', 'fslogixStoragePrefixValue',
             'component1', 'component2'):
    elem = next((e for e in naming_elems if e.get('name') == name), None)
    if elem and 'visible' in elem:
        del elem['visible']
        print(f'  OK: removed visible from {name}')

# ─── 4. Set defaultValue on component dropdowns ──────────────────────────────
defaults = {
    'component1': 'resourceType',
    'component2': 'workload',
    'component3': 'purpose',
    'component4': 'location',
    'component5': 'none',
    'component6': 'none',
}
for name, default in defaults.items():
    elem = next((e for e in naming_elems if e.get('name') == name), None)
    if elem:
        elem['defaultValue'] = default
        print(f'  OK: set defaultValue={default!r} on {name}')
    else:
        print(f'  WARNING: {name} not found')

# ─── 5. Fix component3-6 visible: remove enableCustomNaming && part ──────────
# component3: [and(EN, not(c2))]           → strip_and_condition
# component4: [and(and(EN, not(c2)), not(c3))]   → strip_nested_en (EN is leaf of inner and)
# component5: [and(and(and(EN,...),...),...)]     → strip_nested_en
# component6: [and(and(and(and(EN,...),...),...),...)] → strip_nested_en
for name in ('component3',):
    elem = next((e for e in naming_elems if e.get('name') == name), None)
    if elem and 'visible' in elem:
        old_vis = elem['visible']
        try:
            new_vis = strip_and_condition(old_vis, EN)
            elem['visible'] = new_vis
            print(f'  OK: stripped EN from {name} visible')
        except ValueError as ex:
            print(f'  ERROR: {name}: {ex}')

for name in ('component4', 'component5', 'component6'):
    elem = next((e for e in naming_elems if e.get('name') == name), None)
    if elem and 'visible' in elem:
        old_vis = elem['visible']
        try:
            new_vis = strip_nested_en(old_vis, EN)
            elem['visible'] = new_vis
            print(f'  OK: stripped EN from {name} visible')
        except ValueError as ex:
            print(f'  ERROR: {name}: {ex}')

# ─── 6. Add defaultValue "avd" to workloadValue ──────────────────────────────
wv = next((e for e in naming_elems if e.get('name') == 'workloadValue'), None)
if wv:
    wv['defaultValue'] = 'avd'
    print('  OK: set defaultValue=avd on workloadValue')

# ─── 7. Strip enableCustomNaming from validation infobox visible conditions ──
# Patterns:
#   "[and(EN, not(or(...)))]"  → "[not(or(...))]"
#   "[and(EN, greater(...))]"  → "[greater(...)]"  (kvNameTooLongError)
#   "[and(EN, and(...))]"      → "[and(...)]"       (kvShortUniqueWarning)

validation_boxes = [
    'noResourceTypeError', 'noPurposeError', 'noWorkloadWarning', 'noLocationWarning',
    'duplicateComponentError', 'kvNameTooLongError', 'kvShortUniqueWarning', 'kvNoLocationInfo',
]
for name in validation_boxes:
    elem = next((e for e in naming_elems if e.get('name') == name), None)
    if elem and 'visible' in elem:
        old_vis = elem['visible']
        try:
            new_vis = strip_and_condition(old_vis, EN)
            elem['visible'] = new_vis
            print(f'  OK: stripped EN from {name} visible')
        except ValueError as ex:
            print(f'  ERROR: {name}: {ex}')

# ─── 8. Update namingPreview section: strip if(enableCustomNaming,...) ────────
preview_section = next((e for e in tn['elements'] if e.get('name') == 'namingPreview'), None)
if not preview_section:
    print('  ERROR: namingPreview section not found')
    sys.exit(1)

for elem in preview_section['elements']:
    name = elem.get('name', '')
    opts = elem.get('options', {})
    if 'text' in opts and opts['text'].startswith('[if('):
        old_text = opts['text']
        try:
            new_text = extract_and_strip(old_text, EN)
            opts['text'] = new_text
            print(f'  OK: stripped enableCustomNaming if() from preview.{name} ({len(old_text)} → {len(new_text)} chars)')
        except ValueError as ex:
            print(f'  ERROR: preview.{name}: {ex}')

# ─── 9. Update customNamingConvention output ─────────────────────────────────
outputs = d['view']['outputs']['parameters']
cnv_key = 'customNamingConvention'
if cnv_key in outputs:
    old_expr = outputs[cnv_key]
    try:
        new_expr = extract_and_strip(old_expr, EN)
        outputs[cnv_key] = new_expr
        print(f'  OK: stripped enableCustomNaming if() from output.{cnv_key} ({len(old_expr)} → {len(new_expr)} chars)')
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

# Size check combined
hp_json_size = os.path.getsize('deployments/hostpools/hostpool.json')
combined = size + hp_json_size
print(f'Hostpool combined: {combined:,} bytes ({combined/1048576:.3f} MB) {"PASS" if combined < 2000000 else "FAIL — over 2MB"}')

# Quick sanity check
d2 = json.load(open(UI, encoding='utf-8-sig'))
steps2 = d2['view']['properties']['steps']
tn2 = next(s for s in steps2 if s['name'] == 'tagsAndNaming')
naming2 = next(e for e in tn2['elements'] if e.get('name') == 'naming')
names = [e.get('name') for e in naming2['elements']]
print(f'\nnaming section elements: {names}')
has_en = any('enableCustomNaming' in str(e) for e in naming2['elements'])
print(f'enableCustomNaming in naming section: {has_en}')
