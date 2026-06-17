import json
lines = open('deployments/keyVaults/uiFormDefinition.json', encoding='utf-8').readlines()

# Check placeholder changes on length-calc lines
for ln in [895, 896, 898, 899]:
    c = lines[ln-1]
    has_old = 'sec-{unique}' in c or 'enc-{unique}' in c
    has_new = 'sec-xxxxxx' in c or 'enc-xxxxxx' in c
    print(f'L{ln}: new_placeholder={has_new}, old_placeholder={has_old}')

# Verify style change
style_lines = [(i+1, l.strip()) for i,l in enumerate(lines)
               if '"style": "Warning"' in l and 895 < i+1 < 910]
print('Warning-style lines in error block:', style_lines)

# Verify kvShortUniqueWarning gone
present = any('kvShortUniqueWarning' in l for l in lines)
print('kvShortUniqueWarning present:', present)

# Verify previewNote
note_lines = [(i+1) for i,l in enumerate(lines) if 'truncated to 24 by the deployment' in l]
print('previewNote updated lines:', note_lines)

# Display preview text lines (should still have {unique})
display_lines = [(i+1) for i,l in enumerate(lines) if 'sec-{unique}' in l or 'enc-{unique}' in l]
print('Display lines still using {unique}:', display_lines)
