"""
Fix KV name preview and validation expressions in both UI form definition files.

Changes on KV-specific lines only:
1. purpose->'sec'  becomes  purpose->'sec-{unique}'
2. purpose->'enc'  becomes  purpose->'enc-{unique}'
3. Warning threshold )),20),not(  ->  )),24),not(  (disables false warning for default CAF name)
"""
import pathlib

PATTERN_SEC = ",'purpose'),'sec',"
PATTERN_ENC = ",'purpose'),'enc',"
NEW_SEC     = ",'purpose'),'sec-{unique}',"
NEW_ENC     = ",'purpose'),'enc-{unique}',"

TARGETS = {
    'deployments/keyVaults/uiFormDefinition.json': {
        'sec_lines':  {896, 899, 905, 908, 997, 1004},
        'enc_lines':  {1004},
        'warn_lines': {905},
    },
    'deployments/hostpools/uiFormDefinition.json': {
        'sec_lines':  {4849, 4852, 4858, 4861, 5158},
        'enc_lines':  set(),
        'warn_lines': {4858},
    },
}

for fpath, cfg in TARGETS.items():
    p = pathlib.Path(fpath)
    lines = p.read_text(encoding='utf-8').splitlines(keepends=True)
    changed = 0

    for idx, line in enumerate(lines):
        lineno = idx + 1  # 1-based

        if lineno in cfg['sec_lines']:
            new_line = line.replace(PATTERN_SEC, NEW_SEC)
            if new_line != line:
                changed += line.count(PATTERN_SEC)
                lines[idx] = new_line
                line = new_line

        if lineno in cfg['enc_lines']:
            new_line = line.replace(PATTERN_ENC, NEW_ENC)
            if new_line != line:
                changed += line.count(PATTERN_ENC)
                lines[idx] = new_line
                line = new_line

        # Fix warning lower-bound threshold: )),20),not( -> )),24),not(
        if lineno in cfg['warn_lines']:
            new_line = line.replace(')),20),not(', ')),24),not(')
            if new_line != line:
                changed += 1
                lines[idx] = new_line

    new_content = ''.join(lines)
    p.write_text(new_content, encoding='utf-8')
    print(f'OK: {fpath}  ({changed} substitutions)')

print('Done.')
