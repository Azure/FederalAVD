"""
Fix KV UI form:
1. Change sec/enc-{unique} placeholder (8 chars) to sec/enc-xxxxxx (6 chars) in length
   calculation expressions on lines 896 and 899 (NOT the display lines 997/1004).
2. Change kvNameTooLongError style from Error -> Warning (truncation warning, not hard error).
3. Remove dead kvShortUniqueWarning block (lines 903-910, always-false condition).
4. Update previewNote to describe the actual take()-truncation behavior.
"""
import pathlib

p = pathlib.Path('deployments/keyVaults/uiFormDefinition.json')
lines = p.read_text(encoding='utf-8').splitlines(keepends=True)
changed = 0

LINES_LENGTH_CALC = {896, 899}          # length() expressions in error visible + text
LINE_ERROR_STYLE  = 901                  # "style": "Error" -> "Warning"
LINES_WARN_BLOCK  = set(range(903, 911)) # kvShortUniqueWarning block to remove
LINE_PREVIEW_NOTE = 1012                 # previewNote text

keep = []
for idx, line in enumerate(lines):
    lineno = idx + 1

    # Skip the dead kvShortUniqueWarning block
    if lineno in LINES_WARN_BLOCK:
        changed += 1
        continue

    # Fix placeholder in length-calculation lines
    if lineno in LINES_LENGTH_CALC:
        new = line.replace(",'purpose'),'sec-{unique}',", ",'purpose'),'sec-xxxxxx',")
        new = new.replace(",'purpose'),'enc-{unique}',", ",'purpose'),'enc-xxxxxx',")
        if new != line:
            changed += 1
        line = new

    # Change Error -> Warning for the truncation notice
    if lineno == LINE_ERROR_STYLE:
        new = line.replace('"style": "Error"', '"style": "Warning"')
        if new != line:
            changed += 1
        line = new

    # Update previewNote
    if lineno == LINE_PREVIEW_NOTE:
        old_txt = (
            '{unique} is a 6-character subscription-scoped suffix; '
            'omitted when the Key Vault base name exceeds 20 characters '
            'to stay within the 24-character Azure limit.'
        )
        new_txt = (
            '{unique} is a 6-character subscription-scoped suffix always '
            'embedded in the purpose slot. Names longer than 24 characters '
            'are automatically truncated to 24 by the deployment.'
        )
        new = line.replace(old_txt, new_txt)
        if new != line:
            changed += 1
        line = new

    keep.append(line)

p.write_text(''.join(keep), encoding='utf-8')
print(f'Done: {changed} changes')
