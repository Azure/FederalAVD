"""Analyze purpose->sec/enc patterns in UI form files."""
import pathlib

PATTERN_SEC = ",'purpose'),'sec',"
PATTERN_ENC = ",'purpose'),'enc',"

for f in ['deployments/keyVaults/uiFormDefinition.json', 'deployments/hostpools/uiFormDefinition.json']:
    c = pathlib.Path(f).read_text(encoding='utf-8')
    sec_count = c.count(PATTERN_SEC)
    enc_count = c.count(PATTERN_ENC)
    print(f'{f}: sec={sec_count}, enc={enc_count}')
    lines = c.splitlines()
    for i, line in enumerate(lines, 1):
        has_sec = PATTERN_SEC in line
        has_enc = PATTERN_ENC in line
        if has_sec or has_enc:
            tag = ('sec' if has_sec else '') + ('+enc' if has_enc else '')
            print(f'  line {i} [{tag}]: {line.strip()[:100]}')
