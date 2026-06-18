"""Verify new sec/enc-{unique} patterns in UI forms."""
import pathlib

for f in ['deployments/keyVaults/uiFormDefinition.json', 'deployments/hostpools/uiFormDefinition.json']:
    c = pathlib.Path(f).read_text(encoding='utf-8')
    n_sec = c.count("sec-{unique}'")
    n_enc = c.count("enc-{unique}'")
    print(f'{f}: sec-{{unique}}={n_sec}, enc-{{unique}}={n_enc}')
    for i, line in enumerate(c.splitlines(), 1):
        if 'KV (Secrets)' in line:
            idx = line.find('sec-')
            print(f'  previewKvSecrets line {i}: ...{line[idx:idx+35]}...')
            break
    for i, line in enumerate(c.splitlines(), 1):
        if 'KV (Encryption)' in line:
            idx = line.find('enc-')
            print(f'  previewKvEncryption line {i}: ...{line[idx:idx+35]}...')
            break
    # verify warning threshold change
    for i, line in enumerate(c.splitlines(), 1):
        if ')),24),not(' in line and ('keyVault' in line.lower() or 'kvName' in line.lower() or 'Key Vault base' in line):
            print(f'  warning threshold (line {i}): fixed to 24 ✓')
            break
