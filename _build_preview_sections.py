"""
Move naming previews to a new always-visible "Name Preview" Section just before tags.
Each element shows CAF default names when custom naming is off, custom names when on.
Applied to: hostpools, keyVaults, imageManagement uiFormDefinitions.

Fixes:
- previewHostPool: RT fallback was truncated to '{i' -> correct to 'vdpool'
- previewKvSecrets: RT fallback was 'se' -> correct to 'kv'; add to keyVaults UI
- Conditional unique suffix (base<=20) applied to all KV preview elements
- previewNotes: update KV suffix language for keyVaults & imageManagement
"""
import json, os, re

# ── Shared slot-resolution builder ────────────────────────────────────────────
def slot(N, comp_ref, rt_code, rt_default, purpose_expr, loc_field, loc_ph,
         ff1_field='freeform1Value', env_field='environmentValue',
         ff2_field='freeform2Value', wl_field='workloadValue', wl_default='avd'):
    rt  = f"if(empty({N}.{rt_code}),'{rt_default}',{N}.{rt_code})"
    loc = f"if(not(empty({N}.{loc_field})),{N}.{loc_field},'{loc_ph}')"
    ff1 = f"if(empty({N}.{ff1_field}),'(ff1)',{N}.{ff1_field})"
    env = f"if(empty({N}.{env_field}),'(env)',{N}.{env_field})"
    ff2 = f"if(empty({N}.{ff2_field}),'(ff2)',{N}.{ff2_field})"
    wl  = f"if(empty({N}.{wl_field}),'{wl_default}',{N}.{wl_field})"
    return (
        f"if(equals({comp_ref},'resourceType'),{rt},"
        f"if(equals({comp_ref},'purpose'),{purpose_expr},"
        f"if(equals({comp_ref},'location'),{loc},"
        f"if(equals({comp_ref},'freeform1'),{ff1},"
        f"if(equals({comp_ref},'environment'),{env},"
        f"if(equals({comp_ref},'freeform2'),{ff2},"
        f"{wl}))))))"
    )

def build_name(N, SEP, rt_code, rt_default, purpose_expr, loc_field, loc_ph, **kw):
    parts = []
    for i, cn in enumerate(['component1','component2','component3','component4',
                             'component5','component6'], 1):
        comp_ref = f"{N}.{cn}"
        seg = slot(N, comp_ref, rt_code, rt_default, purpose_expr, loc_field, loc_ph, **kw)
        if i == 1:
            parts.append(seg)
        else:
            parts.append(f"if(not(equals({comp_ref},'none')),concat({SEP},{seg}),'')")
    return f"concat({','.join(parts)})"

def kv_name_expr(N, SEP, loc_field):
    """Full KV (Secrets) custom name expression with conditional unique suffix."""
    base = build_name(N, SEP, 'rtCodeKv', 'kv', "'sec'", loc_field, '{loc}')
    kv_len = f"length({base})"
    return f"if(greater({kv_len},20),{base},concat({base},'-{{unique}}'))"

def last_non_none(N):
    return (
        f"if(not(equals({N}.component6,'none')),{N}.component6,"
        f"if(not(equals({N}.component5,'none')),{N}.component5,"
        f"if(not(equals({N}.component4,'none')),{N}.component4,"
        f"if(not(equals({N}.component3,'none')),{N}.component3,"
        f"if(not(equals({N}.component2,'none')),{N}.component2,"
        f"{N}.component1)))))"
    )

def convention_expr(N):
    SEP = f"{N}.delimiter"
    rt_last = f"equals({last_non_none(N)},'resourceType')"
    return (
        f"concat({N}.component1,"
        f"if(not(equals({N}.component2,'none')),concat(' ',{SEP},' ',{N}.component2),''),"
        f"if(not(equals({N}.component3,'none')),concat(' ',{SEP},' ',{N}.component3),''),"
        f"if(not(equals({N}.component4,'none')),concat(' ',{SEP},' ',{N}.component4),''),"
        f"if(not(equals({N}.component5,'none')),concat(' ',{SEP},' ',{N}.component5),''),"
        f"if(not(equals({N}.component6,'none')),concat(' ',{SEP},' ',{N}.component6),''),"
        f"if({rt_last},' (RT-last)',' (RT-first)'))"
    )

def wrap_caf_custom(EN, label, caf_inner, custom_inner):
    """[if(enableCustomNaming, concat('Label: ', custom), concat('Label: ', caf))]"""
    return f"[if({EN},concat('{label}',{custom_inner}),concat('{label}',{caf_inner}))]"

def wrap_full(EN, custom_full_inner, caf_full_inner):
    """[if(enableCustomNaming, custom, caf)] where both already include labels."""
    return f"[if({EN},{custom_full_inner},{caf_full_inner})]"

# ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ──
# Build the namingPreview section for each solution
# ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ──

def build_hostpool_preview_section(N, EN, SEP, B, H):
    """Build the namingPreview section elements for the hostpool UI."""
    # ── Identifier + index (for purpose slot) ────────────────────────────
    ident = f"{B}.identifier"
    idx   = f"{B}.index"
    padded_idx = f"if(equals(length({idx}),1),concat('0',{idx}),{idx})"
    hp_purpose = f"concat({ident},if(not(empty({idx})),concat('-',{padded_idx}),''))"

    # ── VM prefix + padding ───────────────────────────────────────────────
    pfx  = f"{H}.virtualMachineNamePrefix"
    pads = f"if(equals({H}.indexPadding,1),'#',if(equals({H}.indexPadding,2),'##','###'))"
    sh   = f"concat({pfx},{pads})"

    # ── RT-last detection ─────────────────────────────────────────────────
    lnn     = last_non_none(N)
    rt_last = f"equals({lnn},'resourceType')"

    # ── Custom expressions ────────────────────────────────────────────────
    custom_conv = convention_expr(N)
    custom_hp   = build_name(N, SEP, 'rtCodeHp', 'vdpool', hp_purpose, 'cpLocationAbbreviationOverride', '{cp-loc}')
    custom_kv   = kv_name_expr(N, SEP, 'vmsLocationAbbreviationOverride')

    def vm_pat(rt_field, rt_def, lbl):
        rt_code = f"if(empty({N}.{rt_field}),'{rt_def}',{N}.{rt_field})"
        return (
            f"'{lbl}: ',"
            f"if({rt_last},concat({sh},'-',{rt_code}),concat({rt_code},'-',{sh}))"
        )

    custom_vm = (
        f"concat({vm_pat('rtCodeVm','vm','VM')},"
        f"'  |  ',{vm_pat('rtCodeDisk','osdisk','Disk')},"
        f"'  |  ',{vm_pat('rtCodeNic','nic','NIC')})"
    )

    # ── CAF expressions ───────────────────────────────────────────────────
    caf_conv = "'CAF default \u2014 resource type first'"
    caf_hp   = f"concat('vdpool-',{ident},if(not(empty({idx})),concat('-',{padded_idx}),''),'-{{cp-loc}}')"
    caf_kv   = "'kv-avd-sec-{vms-loc}-{unique}'"
    caf_vm   = f"concat('VM: vm-',{sh},'  |  Disk: osdisk-',{sh},'  |  NIC: nic-',{sh})"

    # ── Elements ──────────────────────────────────────────────────────────
    return [
        {
            "name": "previewConvention",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_caf_custom(EN, "Naming convention: ", caf_conv, custom_conv)}
        },
        {
            "name": "previewHostPool",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_caf_custom(EN, "Host Pool: ", caf_hp, custom_hp)}
        },
        {
            "name": "previewKvSecrets",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_caf_custom(EN, "KV (Secrets): ", caf_kv, custom_kv)}
        },
        {
            "name": "previewVmPatterns",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_full(EN, custom_vm, caf_vm)}
        },
        {
            "name": "previewNote",
            "type": "Microsoft.Common.InfoBox",
            "options": {
                "style": "Info",
                "text": (
                    "{cp-loc} and {vms-loc} are resolved from the selected region at deployment time. "
                    "{unique} is a 6-character subscription-scoped suffix; omitted when the Key Vault "
                    "base name exceeds 20 characters to stay within the 24-character Azure limit."
                )
            }
        }
    ]


def build_kv_preview_section(N, EN, SEP):
    """Build the namingPreview section elements for the keyVaults UI."""
    custom_conv = convention_expr(N)
    custom_rg   = build_name(N, SEP, 'rtCodeRg', 'rg', "'operations'", 'locationAbbreviationOverride', '{loc}')
    custom_kv_s = kv_name_expr(N, SEP, 'locationAbbreviationOverride')
    # KV Encryption: same but purpose='enc'
    kv_enc_base = build_name(N, SEP, 'rtCodeKv', 'kv', "'enc'", 'locationAbbreviationOverride', '{loc}')
    kv_enc_len  = f"length({kv_enc_base})"
    custom_kv_e = f"if(greater({kv_enc_len},20),{kv_enc_base},concat({kv_enc_base},'-{{unique}}'))"

    caf_conv  = "'CAF default \u2014 resource type first'"
    caf_rg    = "'rg-avd-operations-{loc}'"
    caf_kv_s  = "'kv-avd-sec-{loc}-{unique}'"
    caf_kv_e  = "'kv-avd-enc-{loc}-{unique}'"

    return [
        {
            "name": "previewConvention",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_caf_custom(EN, "Naming convention: ", caf_conv, custom_conv)}
        },
        {
            "name": "previewRg",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_caf_custom(EN, "Resource Group: ", caf_rg, custom_rg)}
        },
        {
            "name": "previewKvSecrets",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_caf_custom(EN, "KV (Secrets): ", caf_kv_s, custom_kv_s)}
        },
        {
            "name": "previewKvEncryption",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_caf_custom(EN, "KV (Encryption): ", caf_kv_e, custom_kv_e)}
        },
        {
            "name": "previewNote",
            "type": "Microsoft.Common.InfoBox",
            "options": {
                "style": "Info",
                "text": (
                    "{loc} is resolved from the selected region at deployment time. "
                    "{unique} is a 6-character subscription-scoped suffix; omitted when the Key Vault "
                    "base name exceeds 20 characters to stay within the 24-character Azure limit. "
                    "Underscores and dots in the delimiter are replaced with hyphens in Key Vault names."
                )
            }
        }
    ]


def build_imgmgmt_preview_section(N, EN, SEP):
    """Build the namingPreview section elements for the imageManagement UI."""
    custom_conv = convention_expr(N)
    custom_rg   = build_name(N, SEP, 'rtCodeRg', 'rg', "'image-management'", 'locationAbbreviationOverride', '{loc}')
    # Gallery: same slots but underscore-replace done by Bicep; RT code uses rtCodeGal
    custom_gal  = build_name(N, SEP, 'rtCodeGal', 'gal', "'image-management'", 'locationAbbreviationOverride', '{loc}')

    caf_conv = "'CAF default \u2014 resource type first'"
    caf_rg   = "'rg-avd-image-management-{loc}'"
    caf_gal  = "'gal_avd_image-management_{loc}  (hyphens \u2192 underscores)'"

    return [
        {
            "name": "previewConvention",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_caf_custom(EN, "Naming convention: ", caf_conv, custom_conv)}
        },
        {
            "name": "previewRg",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_caf_custom(EN, "Resource Group: ", caf_rg, custom_rg)}
        },
        {
            "name": "previewGallery",
            "type": "Microsoft.Common.TextBlock",
            "options": {"text": wrap_caf_custom(EN, "Compute Gallery: ", caf_gal, custom_gal)}
        },
        {
            "name": "previewNote",
            "type": "Microsoft.Common.InfoBox",
            "options": {
                "style": "Info",
                "text": (
                    "{loc} is resolved from the selected region at deployment time. "
                    "Gallery names replace all hyphens with underscores. "
                    "Storage account names strip all delimiters (alphanumeric only) and always include "
                    "a uniqueString suffix truncated to 24 characters."
                )
            }
        }
    ]

# ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ──
# Process each UI file
# ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ── ──
PREVIEW_NAMES = {
    'previewHeading', 'previewConvention', 'previewHostPool', 'previewKvSecrets',
    'previewVmPatterns', 'previewRg', 'previewNotes', 'previewNotes2', 'previewNote',
    'previewGallery', 'previewKvEncryption'
}

def process(path, build_preview_fn, verbose=True):
    d = json.load(open(path, encoding='utf-8-sig'))
    steps_list = d['view']['properties']['steps']
    tn = next(s for s in steps_list if s['name'] == 'tagsAndNaming')

    naming_section = next(e for e in tn['elements'] if e.get('name') == 'naming')
    tags_section   = next(e for e in tn['elements'] if e.get('name') == 'tags')

    # Remove old preview elements from naming section
    naming_section['elements'] = [
        e for e in naming_section['elements']
        if e.get('name') not in PREVIEW_NAMES
    ]

    # Build new preview section
    preview_elements = build_preview_fn()
    preview_section = {
        "name": "namingPreview",
        "type": "Microsoft.Common.Section",
        "label": "Name Preview",
        "elements": preview_elements
    }

    # Rebuild tagsAndNaming elements: naming, namingPreview, tags
    tn['elements'] = [naming_section, preview_section, tags_section]

    with open(path, 'w', encoding='utf-8-sig') as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write('\n')

    # Verify JSON validity
    d2 = json.load(open(path, encoding='utf-8-sig'))
    size = os.path.getsize(path)
    if verbose:
        print(f'{path}: {size:,} bytes')
    return size


N_HP   = "steps('tagsAndNaming').naming"
EN_HP  = f"{N_HP}.enableCustomNaming"
SEP_HP = f"{N_HP}.delimiter"
B_HP   = "steps('basics')"
H_HP   = "steps('hosts').naming"

N_KV   = "steps('tagsAndNaming').naming"
EN_KV  = f"{N_KV}.enableCustomNaming"
SEP_KV = f"{N_KV}.delimiter"

N_IM   = "steps('tagsAndNaming').naming"
EN_IM  = f"{N_IM}.enableCustomNaming"
SEP_IM = f"{N_IM}.delimiter"

hp_size = process(
    'deployments/hostpools/uiFormDefinition.json',
    lambda: build_hostpool_preview_section(N_HP, EN_HP, SEP_HP, B_HP, H_HP)
)
kv_size = process(
    'deployments/keyVaults/uiFormDefinition.json',
    lambda: build_kv_preview_section(N_KV, EN_KV, SEP_KV)
)
im_size = process(
    'deployments/imageManagement/uiFormDefinition.json',
    lambda: build_imgmgmt_preview_section(N_IM, EN_IM, SEP_IM)
)

arm_size = os.path.getsize('deployments/hostpools/hostpool.json')
combined = hp_size + arm_size
print()
print(f'Hostpool combined: {combined:,} bytes ({combined/1e6:.3f} MB)', 'PASS' if combined < 2_000_000 else 'FAIL')

# Spot check structure
for path, label in [
    ('deployments/hostpools/uiFormDefinition.json', 'HOSTPOOL'),
    ('deployments/keyVaults/uiFormDefinition.json', 'KEYVAULTS'),
    ('deployments/imageManagement/uiFormDefinition.json', 'IMAGEMANAGEMENT'),
]:
    d = json.load(open(path, encoding='utf-8-sig'))
    steps_list = d['view']['properties']['steps']
    tn = next(s for s in steps_list if s['name'] == 'tagsAndNaming')
    sections = [e.get('name') for e in tn['elements']]
    print(f'\n{label} tagsAndNaming sections: {sections}')
    ps = next((e for e in tn['elements'] if e.get('name') == 'namingPreview'), None)
    if ps:
        print('  namingPreview elements:')
        for e in ps['elements']:
            nm = e.get('name'); sz = len(json.dumps(e).encode())
            vis = e.get('visible', '(none)')
            print(f'    {sz:>8,}  {nm}  visible={str(vis)[:40]}')
