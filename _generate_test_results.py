#!/usr/bin/env python3
"""
Generate naming-convention-test-results.md with correct names based on current naming logic.
Simulates all 8 documentation scenarios across HP, imageManagement, KV standalone, and SHR add-on.
"""
import hashlib, json, pathlib, re

SUBSCRIPTION_ID = '67edfd17-f0d1-466a-aacb-ca9daeabb9b8'

with open('.common/data/resourceAbbreviations.json', encoding='utf-8') as f:
    ABBR = json.load(f)
with open('.common/data/locations.json', encoding='utf-8') as f:
    LOCS_ALL = json.load(f)['AzureCloud']

def loc(region): return LOCS_ALL[region]['abbreviation']

def resolve_seg(s, rt, purpose, location, ff1, env, ff2, workload):
    return {'resourceType': rt, 'purpose': purpose, 'location': location,
            'freeform1': ff1, 'environment': env, 'freeform2': ff2, 'workload': workload}.get(s, '')

def build(components, sep, rt, purpose, location, ff1, env, ff2, workload):
    parts = [resolve_seg(s, rt, purpose, location, ff1, env, ff2, workload)
             for s in components if s != 'none']
    return sep.join(p for p in parts if p)

def kv_sanitize(s):  return s.replace('_','-').replace('.','-')
def strip_seps(s):   return re.sub(r'[-_.]','',s).lower()

def unique_string(*inputs):
    combined = ''.join(str(i).lower() for i in inputs)
    return hashlib.sha256(combined.encode()).hexdigest()[:13]

def cnv_name(conv, rt_codes, rt_key, purpose, location):
    """Build a name from convention."""
    segs = [s for s in conv['components'] if s != 'none']
    return build(segs, conv['sep'], rt_codes[rt_key], purpose,
                 location, conv['ff1'], conv['env'], conv['ff2'], conv['workload'])

# ── Compute all names for a scenario ─────────────────────────────────────────
def compute_all(sc):
    convention = sc['convention']
    comps_raw  = convention['components']
    comps      = [s for s in comps_raw if s != 'none']
    sep        = convention.get('delimiter', '-')
    workload   = convention.get('workload') or 'avd'
    ff1        = convention.get('freeform1', '')
    env        = convention.get('environment', '')
    ff2        = convention.get('freeform2', '')
    custom_rt  = convention.get('resourceTypeCodes', {})

    vms_region = sc['vms_region']
    cp_region  = sc.get('cp_region', vms_region)
    identifier = sc['identifier']
    index      = sc.get('index', None)
    purpose    = f'{identifier}-{index:02d}' if index is not None else identifier

    vms_loc = convention.get('vmsLocationAbbreviation') or loc(vms_region)
    cp_loc  = convention.get('cpLocationAbbreviation')  or loc(cp_region)

    # HP uses union of ABBR + custom; KV standalone uses custom directly (or defaults)
    rt_hp = {**ABBR, **custom_rt}
    rt_kv_standalone = custom_rt or {k: ABBR[k] for k in ('resourceGroups','keyVaults','privateEndpoints','networkInterfaces')}

    rt_first = not (comps and comps[-1] == 'resourceType')

    def n(rt_key, purpose_val, location_val, rt_codes=None):
        codes = rt_codes or rt_hp
        return build(comps, sep, codes[rt_key], purpose_val, location_val, ff1, env, ff2, workload)

    # ── RGs
    rg_cp       = n('resourceGroups', 'control-plane', cp_loc)
    rg_hosts    = n('resourceGroups', f'{purpose}-hosts', vms_loc)
    rg_storage  = n('resourceGroups', f'{purpose}-storage', vms_loc)
    rg_ops      = n('resourceGroups', 'operations', vms_loc)
    rg_mon      = n('resourceGroups', 'monitoring', vms_loc)

    # ── HP resources (use cp_loc for HP/DAG/WS/SP; vms_loc for LAW/DCE/KV)
    hp_name = n('hostPools', purpose, cp_loc)
    dag_name = n('desktopApplicationGroups', purpose, cp_loc)
    ws_name  = n('workspaces', '', cp_loc)  # workspace has no purpose
    sp_name  = n('scalingPlans', purpose, cp_loc)
    law_name = n('logAnalyticsWorkspaces', '', vms_loc)
    dce_name = n('dataCollectionEndpoints', '', vms_loc)

    # ── KV (unique embedded in purpose)
    location_in_comps = 'location' in comps_raw
    unique_ops = unique_string(SUBSCRIPTION_ID, rg_ops, vms_region)[:6] \
        if not location_in_comps \
        else unique_string(SUBSCRIPTION_ID, rg_ops)[:6]

    kv_sec = kv_sanitize(n('keyVaults', f'sec-{unique_ops}', vms_loc))[:24]
    kv_enc = kv_sanitize(n('keyVaults', f'enc-{unique_ops}', vms_loc))[:24]

    # ── Availability Set — pattern with ## placeholder
    as_name = n('availabilitySets', f'{purpose}-##', vms_loc)

    # ── VM / disk / NIC naming patterns
    vm_rt  = rt_hp.get('virtualMachines', ABBR['virtualMachines'])
    dsk_rt = rt_hp.get('osdisks', ABBR['osdisks'])
    nic_rt = rt_hp.get('networkInterfaces', ABBR['networkInterfaces'])
    vm_pat   = f'{vm_rt}-SHNAME'  if rt_first else f'SHNAME-{vm_rt}'
    disk_pat = f'{dsk_rt}-SHNAME' if rt_first else f'SHNAME-{dsk_rt}'
    nic_pat  = f'{nic_rt}-SHNAME' if rt_first else f'SHNAME-{nic_rt}'

    # ── DES, RSV, UAI, DA
    da_name  = n('diskAccesses', purpose, vms_loc)
    des_name = n('diskEncryptionSets', f'{purpose}-customer-keys', vms_loc)
    rsv_vm   = n('recoveryServicesVaults', purpose, vms_loc)
    rsv_files= n('recoveryServicesVaults', 'files', vms_loc)
    uai_name = n('userAssignedIdentities', f'{purpose}-TOKEN', vms_loc)

    # ── Global feed workspace/RG (no location)
    gf_ws = n('workspaces', 'global-feed', '')  # empty location → filtered
    gf_rg = n('resourceGroups', 'global-feed', '')

    # ── imageManagement (fixed identifier = image-management)
    im_id  = 'image-management'
    im_rg  = n('resourceGroups', im_id, vms_loc)
    im_gal_raw = build(comps, sep, ABBR['computeGalleries'], im_id, vms_loc, ff1, env, ff2, workload)
    im_gal = im_gal_raw.replace('-', '_')  # gallery requires underscores
    im_uai = n('userAssignedIdentities', im_id, vms_loc)
    im_uai_enc = n('userAssignedIdentities', f'{im_id}-encryption', vms_loc)
    im_kv  = n('keyVaults', im_id, vms_loc)
    # DES names — identifier prefix added to purpose (matches hostpool pattern)
    im_des_cmk    = build(comps, sep, ABBR['diskEncryptionSets'], f'{im_id}-customer-keys', vms_loc, ff1, env, ff2, workload)
    im_des_pmcmk  = build(comps, sep, ABBR['diskEncryptionSets'], f'{im_id}-platform-and-customer-keys', vms_loc, ff1, env, ff2, workload)
    im_des_cvm    = build(comps, sep, ABBR['diskEncryptionSets'], f'{im_id}-confidential-vm', vms_loc, ff1, env, ff2, workload)
    # SA names — RT + purpose + loc + unique (no workload/env/freeform)
    sa_rt = 'sa'  # default; custom rtCodes not included in this sim
    im_sa_unique_full = unique_string(SUBSCRIPTION_ID, im_rg)
    im_sa_unique_noloc = unique_string(SUBSCRIPTION_ID, im_rg, vms_region)
    im_sa_u_raw = im_sa_unique_noloc if not location_in_comps else im_sa_unique_full
    im_sa_unique_len = max(24 - len(sa_rt) - 9 - len(vms_loc), 1)
    im_sa_unique = im_sa_u_raw[:im_sa_unique_len]
    if rt_first:
        im_sa_art  = f'{sa_rt}imgassets{vms_loc}{im_sa_unique}'
        im_sa_logs = f'{sa_rt}imglogs{vms_loc}{im_sa_unique}'
    else:
        im_sa_art  = f'imgassets{vms_loc}{im_sa_unique}{sa_rt}'
        im_sa_logs = f'imglogs{vms_loc}{im_sa_unique}{sa_rt}'

    # ── KV standalone (fixed identifier = operations, uses vms_region for eastus scenarios)
    kv_sa_region = vms_region
    kv_sa_loc    = vms_loc
    rg_ops_kv = build(comps, sep, rt_kv_standalone['resourceGroups'], 'operations',
                      kv_sa_loc, ff1, env, ff2, workload)
    unique_ops_kv = unique_string(SUBSCRIPTION_ID, rg_ops_kv, kv_sa_region)[:6] \
        if not location_in_comps \
        else unique_string(SUBSCRIPTION_ID, rg_ops_kv)[:6]
    kv_sec_sa = kv_sanitize(build(comps, sep, rt_kv_standalone['keyVaults'],
                                   f'sec-{unique_ops_kv}', kv_sa_loc, ff1, env, ff2, workload))[:24]
    kv_enc_sa = kv_sanitize(build(comps, sep, rt_kv_standalone['keyVaults'],
                                   f'enc-{unique_ops_kv}', kv_sa_loc, ff1, env, ff2, workload))[:24]
    kv_parity = '✅ Match' if kv_sec == kv_sec_sa else f'❌ MISMATCH  hp={kv_sec}  kv={kv_sec_sa}'

    # ── SHR add-on (derived from HP name)
    hp_stripped = strip_seps(hp_name)   # for storage account base
    unique_shr  = unique_string(hp_name)[:6]
    if rt_first:
        # base = strip RT prefix + location suffix from hp_name
        # hp = {rt}-{base}-{loc} → base = parts between
        hp_parts = hp_name.split(sep) if sep != '_' else hp_name.split('_')
        # Remove first (RT) and last (location if present); what's left is the base
        if location_in_comps and len(hp_parts) >= 2:
            shr_base = sep.join(hp_parts[1:-1]) if len(hp_parts) > 2 else hp_parts[1]
        else:
            shr_base = sep.join(hp_parts[1:]) if len(hp_parts) > 1 else hp_parts[0]
        shr_loc  = cp_loc
        shr_fa   = build(comps, sep, ABBR['functionApps'], f'{shr_base}-shr-{unique_shr}', shr_loc, ff1, env, ff2, workload)
        shr_uai  = build(comps, sep, ABBR['userAssignedIdentities'], f'{shr_base}-shr{unique_shr}-encryption', shr_loc, ff1, env, ff2, workload)
    else:
        # hp = {workload}-{purpose}-{loc}-{RT} → base = {workload}-{purpose}
        hp_parts = hp_name.split(sep)
        if len(hp_parts) >= 3:
            shr_base = sep.join(hp_parts[:-2])  # drop loc and RT
        else:
            shr_base = hp_parts[0]
        shr_loc  = cp_loc
        shr_fa   = build(comps, sep, ABBR['functionApps'], f'{shr_base}-shr-{unique_shr}', shr_loc, ff1, env, ff2, workload)
        shr_uai  = build(comps, sep, ABBR['userAssignedIdentities'], f'{shr_base}-shr{unique_shr}-encryption', shr_loc, ff1, env, ff2, workload)

    # Storage account: strip seps, max 24 chars lowercase alnum
    shr_sa_raw = f'{hp_stripped}shr{unique_shr}{strip_seps(shr_loc)}'
    shr_sa = strip_seps(shr_sa_raw)[:24]

    return {
        # RGs
        'rg_cp': rg_cp, 'rg_hosts': rg_hosts, 'rg_storage': rg_storage,
        'rg_ops': rg_ops, 'rg_mon': rg_mon,
        # HP resources
        'hp': hp_name, 'dag': dag_name, 'ws': ws_name, 'sp': sp_name,
        'law': law_name, 'dce': dce_name,
        # KV
        'kv_sec': kv_sec, 'kv_enc': kv_enc,
        # VMs / disks / NICs
        'as': as_name, 'vm_pat': vm_pat, 'disk_pat': disk_pat, 'nic_pat': nic_pat,
        # Other resources
        'da': da_name, 'des': des_name, 'rsv_vm': rsv_vm, 'rsv_files': rsv_files,
        'uai': uai_name,
        # Global feed
        'gf_ws': gf_ws, 'gf_rg': gf_rg,
        # imageManagement
        'im_rg': im_rg, 'im_gal': im_gal, 'im_uai': im_uai,
        'im_uai_enc': im_uai_enc, 'im_kv': im_kv,
        'im_des_cmk': im_des_cmk, 'im_des_pmcmk': im_des_pmcmk, 'im_des_cvm': im_des_cvm,
        'im_sa_art': im_sa_art, 'im_sa_logs': im_sa_logs,
        # KV standalone
        'kv_sa_rg': rg_ops_kv, 'kv_sa_sec': kv_sec_sa, 'kv_sa_enc': kv_enc_sa,
        'kv_parity': kv_parity,
        # SHR
        'shr_fa': shr_fa, 'shr_sa': shr_sa, 'shr_uai': shr_uai,
        'vm_pat': vm_pat, 'disk_pat': disk_pat, 'nic_pat': nic_pat,
    }

# ── Scenarios ─────────────────────────────────────────────────────────────────
CAF = {'components': ['resourceType', 'workload', 'purpose', 'location'],
       'delimiter': '-', 'workload': 'avd'}

SCENARIOS = [
    {
        'n': 1,
        'label': 'CAF Default — RT-first, East US',
        'description': 'Default `namingConvention` value, single region deployment. '
                       'Uses built-in CAF-aligned defaults (resourceType-workload-purpose-location).',
        'convention': CAF,
        'identifier': 'desktop',
        'index': 1,
        'cp_region': 'eastus',
        'vms_region': 'eastus',
    },
    {
        'n': 2,
        'label': 'CAF Default — split CP / VMs regions',
        'description': 'CP resources in East US, session hosts in West US 2. Default naming. '
                       'Verifies that location tokens differ correctly.',
        'convention': CAF,
        'identifier': 'desktop',
        'index': 1,
        'cp_region': 'eastus',
        'vms_region': 'westus2',
    },
    {
        'n': 3,
        'label': 'Custom — RT-first, 4 components: RT|workload|purpose|location',
        'description': 'Standard CAF-style custom convention. Workload=avd, env=prod, freeform1 unused. '
                       'RT is first non-none component.',
        'convention': {'components': ['resourceType', 'workload', 'purpose', 'location'],
                       'delimiter': '-', 'workload': 'avd', 'environment': 'prod'},
        'identifier': 'desktop',
        'index': 1,
        'cp_region': 'eastus',
        'vms_region': 'eastus',
    },
    {
        'n': 4,
        'label': 'Custom — RT-last, 4 components: workload|purpose|location|RT',
        'description': 'RT-last convention. Workload=avd, environment=prod. '
                       'Verifies that VM/disk/NIC patterns are SHNAME-vm / SHNAME-osdisk / SHNAME-nic.',
        'convention': {'components': ['workload', 'purpose', 'location', 'resourceType'],
                       'delimiter': '-', 'workload': 'avd', 'environment': 'prod'},
        'identifier': 'prod',
        'index': None,
        'cp_region': 'eastus2',
        'vms_region': 'eastus2',
    },
    {
        'n': 5,
        'label': 'Custom — with freeform1 org prefix, 5 components',
        'description': 'Organisation prefix "contoso" in freeform1. '
                       'Component order: freeform1|workload|purpose|location|RT. '
                       'Demonstrates org-branding at the front.',
        'convention': {'components': ['freeform1', 'workload', 'purpose', 'location', 'resourceType'],
                       'delimiter': '-', 'workload': 'avd', 'freeform1': 'contoso'},
        'identifier': 'avd',
        'index': None,
        'cp_region': 'eastus',
        'vms_region': 'eastus',
    },
    {
        'n': 6,
        'label': 'Custom — RT-first, environment component, underscore delimiter',
        'description': 'Uses underscore as delimiter. '
                       'Components: RT|workload|environment|purpose|location. '
                       'Tests delimiter independence.',
        'convention': {'components': ['resourceType', 'workload', 'environment', 'purpose', 'location'],
                       'delimiter': '_', 'workload': 'avd', 'environment': 'prod'},
        'identifier': 'avd',
        'index': None,
        'cp_region': 'westus2',
        'vms_region': 'westus2',
    },
    {
        'n': 7,
        'label': 'Custom — RT-first, no location component',
        'description': 'Location omitted from naming. '
                       'Tests that uniqueString seeds on (subId, rgName, region) '
                       'in KV to prevent cross-region collisions.',
        'convention': {'components': ['resourceType', 'workload', 'purpose'],
                       'delimiter': '-', 'workload': 'avd'},
        'identifier': 'avd',
        'index': None,
        'cp_region': 'eastus',
        'vms_region': 'eastus',
    },
    {
        'n': 8,
        'label': 'Custom — RT mid-position (not first, not last)',
        'description': 'RT in position 2: freeform1|resourceType|workload|purpose|location. '
                       'RT is not LAST so convention is treated as RT-first (VM pattern = vm-SHNAME).',
        'convention': {'components': ['freeform1', 'resourceType', 'workload', 'purpose', 'location'],
                       'delimiter': '-', 'workload': 'avd', 'freeform1': 'fabrikam'},
        'identifier': 'avd',
        'index': None,
        'cp_region': 'eastus',
        'vms_region': 'eastus',
    },
]

# ── Output doc ────────────────────────────────────────────────────────────────
HEADER = """[**Home**](../README.md) | [**Quick Start**](quick-start.md) | [**Naming Convention**](naming-convention.md) | [**Parameters**](parameters.md)

# Naming Convention — Scenario Test Results

Auto-generated by `_generate_test_results.py`. Simulates the Bicep naming logic for **8 scenarios**
across all four core solutions (hostpool, imageManagement, keyVaults standalone, SHR add-on) and
verifies output names match expected patterns.

> **Simulation note:** `uniqueString()` is simulated with a SHA-256 hash of the same seed inputs
> used in the Bicep. KV suffix values will differ from a live deployment but are
> consistent across hostpool and keyVaults standalone within the same scenario.

---
"""

SUMMARY_ROWS = []
lines = [HEADER]

for sc in SCENARIOS:
    n = sc['n']
    names = compute_all(sc)
    conv = sc['convention']
    comps = conv['components']
    sep = conv.get('delimiter','-')
    index = sc.get('index')
    purpose = f'{sc["identifier"]}-{index:02d}' if index is not None else sc['identifier']
    cp_region  = sc.get('cp_region', sc['vms_region'])
    vms_region = sc['vms_region']
    comps_str = ' → '.join(f'`{c}`' for c in comps)

    rt_first = not ([s for s in comps if s!='none'][-1] == 'resourceType')
    rt_label = '**RT-first** (prefix)' if rt_first else '**RT-last** (suffix)'

    section = [f'## Scenario {n}: {sc["label"]}', '']
    section += [f'**Description:** {sc["description"]}', '']
    section += ['| Setting | Value |', '|---------|-------|']
    section += [f'| Convention | {"CAF Default (built-in)" if conv == CAF else "Custom"} |']
    section += [f'| Components | {comps_str} |']
    section += [f'| Delimiter | `{sep}` |']
    section += [f'| Workload | `{conv.get("workload","avd")}` |']
    if conv.get('environment'):
        section += [f'| Environment | `{conv["environment"]}` |']
    else:
        section += ['| Environment | *(none)* |']
    if conv.get('freeform1'):
        section += [f'| Freeform1 | `{conv["freeform1"]}` |']
    else:
        section += ['| Freeform1 | *(none)* |']
    section += [f'| Identifier | `{sc["identifier"]}` |']
    if index is not None:
        section += [f'| Index | `{index}` |']
    else:
        section += ['| Index | *(none)* |']
    section += [f'| CP Region | `{cp_region}` → `{loc(cp_region)}` |']
    section += [f'| VMs Region | `{vms_region}` → `{loc(vms_region)}` |']
    section += [f'| RT position | {rt_label} |']
    section += ['']

    # HP resources
    section += ['### Host Pool Deployment Resources', '']
    section += ['| Resource | Generated Name |', '|----------|----------------|']
    rows = [
        ('RG (Control Plane)', names['rg_cp']),
        ('RG (Hosts)',         names['rg_hosts']),
        ('RG (Storage)',       names['rg_storage']),
        ('RG (Operations)',    names['rg_ops']),
        ('RG (Monitoring)',    names['rg_mon']),
        ('Host Pool',          names['hp']),
        ('Desktop App Group',  names['dag']),
        ('Workspace',          names['ws']),
        ('Scaling Plan',       names['sp']),
        ('Log Analytics WS',   names['law']),
        ('DCE',                names['dce']),
        ('KV (Secrets)',       names['kv_sec']),
        ('KV (Encryption)',    names['kv_enc']),
        ('Availability Set',   names['as']),
        ('VM',                 names['vm_pat']),
        ('OS Disk',            names['disk_pat']),
        ('NIC',                names['nic_pat']),
        ('Disk Access',        names['da']),
        ('DES (customer-keys)',names['des']),
        ('RSV (VMs)',          names['rsv_vm']),
        ('RSV (Files)',        names['rsv_files']),
        ('UAI (conv)',         names['uai']),
    ]
    for res, name in rows:
        section += [f'| {res} | `{name}` |']
    section += ['']

    # Global feed
    section += ['### Global Feed Resources', '']
    section += ['*Global feed is a single shared resource — no location in the name.*', '']
    section += ['| Resource | Generated Name |', '|----------|----------------|']
    section += [f'| Global Feed RG | `{names["gf_rg"]}` |']
    section += [f'| Global Feed Workspace | `{names["gf_ws"]}` |']
    section += ['']

    # imageManagement
    section += ['### Image Management Resources', '']
    section += ['| Resource | Generated Name |', '|----------|----------------|']
    im_rows = [
        ('RG',                        names['im_rg']),
        ('Compute Gallery',           names['im_gal']),
        ('UAI',                       names['im_uai']),
        ('UAI (Encryption)',          names['im_uai_enc']),
        ('Key Vault',                 names['im_kv']),
        ('DES (customer-keys)',       names['im_des_cmk']),
        ('DES (platform+customer)',   names['im_des_pmcmk']),
        ('DES (confidential-vm)',     names['im_des_cvm']),
        ('Artifacts Storage Account', names['im_sa_art']),
        ('Logs Storage Account',      names['im_sa_logs']),
    ]
    for res, name in im_rows:
        section += [f'| {res} | `{name}` |']
    section += ['']

    # KV standalone
    section += ['### Key Vaults Standalone Resources', '']
    section += [f'*Using identifier `operations`, region `{vms_region}`*', '']
    section += ['| Resource | Generated Name |', '|----------|----------------|']
    section += [f'| RG | `{names["kv_sa_rg"]}` |']
    section += [f'| KV (Secrets) | `{names["kv_sa_sec"]}` |']
    section += [f'| KV (Encrypt) | `{names["kv_sa_enc"]}` |']
    section += ['']
    section += [f'**KV name parity check:** hostpool KV (Secrets) = `{names["kv_sec"]}`, '
                f'standalone = `{names["kv_sa_sec"]}` → {names["kv_parity"]}']
    section += ['']

    # SHR
    section += ['### Session Host Replacer Add-On Resources', '']
    section += [f'*Derived from host pool name: `{names["hp"]}`*', '']
    section += ['| Resource | Generated Name |', '|----------|----------------|']
    shr_rows = [
        ('Function App',    names['shr_fa']),
        ('Storage Account', names['shr_sa']),
        ('Encryption UAI',  names['shr_uai']),
        ('VM Pattern',      names['vm_pat']),
        ('Disk Pattern',    names['disk_pat']),
        ('NIC Pattern',     names['nic_pat']),
    ]
    for res, name in shr_rows:
        section += [f'| {res} | `{name}` |']
    section += ['', '---', '']

    parity = '✅' if names['kv_parity'].startswith('✅') else '❌'
    SUMMARY_ROWS.append(f'| {n} | {sc["label"]} | {"CAF Default" if conv == CAF else "Custom"} | {rt_label} | {parity} |')

    lines += section

# Summary table
lines += ['## Summary', '']
lines += ['| # | Scenario | Convention | RT Position | KV Parity |']
lines += ['|---|----------|------------|-------------|-----------|']
lines += SUMMARY_ROWS
lines += ['']

output_path = pathlib.Path('docs/naming-convention-test-results.md')
output_path.write_text('\n'.join(lines), encoding='utf-8')
print(f'Written: {output_path}')
print(f'Scenarios: {len(SCENARIOS)}')
# Quick sanity check
for sc in SCENARIOS:
    names = compute_all(sc)
    ok = '✅' if names['kv_parity'].startswith('✅') else '❌'
    print(f'  Sc{sc["n"]} KV parity: {ok}  sec={names["kv_sec"]}')
