#!/usr/bin/env python3
"""
Naming parity check: hostpool naming module vs keyVaults inline naming.
Simulates both Bicep implementations in Python and compares shared-resource names
across multiple scenarios.

Shared resources compared:
  - operationsResourceGroupName  (rg-avd-operations-...)
  - secretsKeyVaultName          (kv-avd-sec-...)
  - encryptionKeyVaultName       (kv-avd-enc-...)
  - privateEndpointNameConv
  - privateEndpointNICNameConv
"""
import hashlib, json, re

# ── Fake subscription ID (matches real hash behavior) ────────────────────────
SUBSCRIPTION_ID = '67edfd17-f0d1-466a-aacb-ca9daeabb9b8'

# Load real abbreviation data
with open('.common/data/resourceAbbreviations.json', encoding='utf-8') as f:
    ABBR = json.load(f)
with open('.common/data/locations.json', encoding='utf-8') as f:
    ALL_LOCS = json.load(f)

LOCS = ALL_LOCS['AzureCloud']   # simulate non-air-gapped

def get_loc_abbr(location: str) -> str:
    return LOCS[location]['abbreviation']

def resolve_segment(seg, rt_code, component, loc, ff1, env, ff2, workload):
    return {
        'resourceType': rt_code,
        'purpose':      component,
        'location':     loc,
        'freeform1':    ff1,
        'environment':  env,
        'freeform2':    ff2,
        'workload':     workload,
    }.get(seg, '')

def build_custom_name(segments, sep, rt_code, component, loc, ff1, env, ff2, workload):
    parts = [resolve_segment(s, rt_code, component, loc, ff1, env, ff2, workload)
             for s in segments if s != 'none']
    return sep.join(p for p in parts if p)

def kv_sanitize(s):
    return s.replace('_', '-').replace('.', '-')

def strip_seps(s):
    return s.replace('-', '').replace('_', '').replace('.', '')

def arm_unique_string(*inputs):
    """Approximate ARM uniqueString() — deterministic 13-char hex hash."""
    combined = ''.join(str(i).lower() for i in inputs)
    h = hashlib.sha256(combined.encode()).hexdigest()
    return h[:13]

# ── Hostpool naming logic (mirrors modules/naming.bicep) ────────────────────
def compute_hostpool_names(convention: dict, location_vms: str, location_cp: str, identifier: str):
    vms_loc_abbr = get_loc_abbr(location_vms)
    cp_loc_abbr  = get_loc_abbr(location_cp)

    sep      = convention.get('delimiter', '-')
    segments = convention.get('components', ['resourceType', 'workload', 'purpose', 'location'])
    cnv_vmsloc = convention.get('vmsLocationAbbreviation') or vms_loc_abbr
    cnv_cploc  = convention.get('cpLocationAbbreviation')  or cp_loc_abbr
    workload   = convention.get('workload') or 'avd'
    ff1        = convention.get('freeform1', '')
    env        = convention.get('environment', '')
    ff2        = convention.get('freeform2', '')
    custom_rt  = convention.get('resourceTypeCodes', {})
    rt_codes   = {**ABBR, **custom_rt}   # union(abbr, customCodes)

    segs_no_none = [s for s in segments if s != 'none']
    rt_last = segs_no_none and segs_no_none[-1] == 'resourceType'
    rt_first = not rt_last

    def cnv(rt, component, loc):
        return build_custom_name(segs_no_none, sep, rt, component, loc, ff1, env, ff2, workload)

    rg_ops = cnv(rt_codes['resourceGroups'], 'operations', cnv_vmsloc)

    unique_ops = arm_unique_string(SUBSCRIPTION_ID, rg_ops, location_vms)[:6] \
        if 'location' not in segments \
        else arm_unique_string(SUBSCRIPTION_ID, rg_ops)[:6]

    kv_sec = kv_sanitize(cnv(rt_codes['keyVaults'], f'sec-{unique_ops}', cnv_vmsloc))[:24]
    kv_enc = kv_sanitize(cnv(rt_codes['keyVaults'], f'enc-{unique_ops}', cnv_vmsloc))[:24]

    pe = f'{rt_codes["privateEndpoints"]}-RESOURCE-SUBRESOURCE-VNETID' if rt_first \
         else f'RESOURCE-SUBRESOURCE-VNETID-{rt_codes["privateEndpoints"]}'
    nic_rt = rt_codes['networkInterfaces']
    pe_nic = f'{nic_rt}-{pe}' if rt_first else f'{pe}-{nic_rt}'

    return {
        'operationsRG':      rg_ops,
        'secretsKV':         kv_sec,
        'encryptionKV':      kv_enc,
        'peNameConv':        pe,
        'peNicNameConv':     pe_nic,
        '_uniqueOps':        unique_ops,
    }

# ── KeyVaults naming logic (mirrors keyVaults.bicep inline) ─────────────────
def compute_keyvaults_names(convention: dict, location: str):
    loc_abbr = get_loc_abbr(location)

    sep      = convention.get('delimiter', '-')
    segments = convention.get('components', ['resourceType', 'workload', 'purpose', 'location'])
    cnv_loc  = convention.get('locationAbbreviation') or loc_abbr
    workload = convention.get('workload', 'avd')   # KV workload for rgName
    ff1      = convention.get('freeform1', '')
    env      = convention.get('environment', '')
    ff2      = convention.get('freeform2', '')
    custom_rt = convention.get('resourceTypeCodes', {})
    # KeyVaults uses custom codes DIRECTLY — no union fallback
    if custom_rt:
        rt_codes = custom_rt
    else:
        rt_codes = {
            'resourceGroups':   ABBR['resourceGroups'],
            'keyVaults':        ABBR['keyVaults'],
            'privateEndpoints': ABBR['privateEndpoints'],
            'networkInterfaces':ABBR['networkInterfaces'],
        }

    segs_no_none = [s for s in segments if s != 'none']
    rt_last  = segs_no_none and segs_no_none[-1] == 'resourceType'
    rt_first = not rt_last

    kv_workload = convention.get('workload', '')   # raw — '' if missing

    rg_ops = build_custom_name(
        segs_no_none, sep, rt_codes['resourceGroups'], 'operations',
        cnv_loc, ff1, env, ff2,
        convention.get('workload', 'avd') if convention.get('workload') else 'avd'
    )

    unique_ops = arm_unique_string(SUBSCRIPTION_ID, rg_ops, location)[:6] \
        if 'location' not in segments \
        else arm_unique_string(SUBSCRIPTION_ID, rg_ops)[:6]

    kv_sec = kv_sanitize(build_custom_name(segs_no_none, sep, rt_codes['keyVaults'], f'sec-{unique_ops}',
        cnv_loc, ff1, env, ff2, convention.get('workload') or 'avd'))[:24]
    kv_enc = kv_sanitize(build_custom_name(segs_no_none, sep, rt_codes['keyVaults'], f'enc-{unique_ops}',
        cnv_loc, ff1, env, ff2, convention.get('workload') or 'avd'))[:24]

    pe = f'{rt_codes["privateEndpoints"]}-RESOURCE-SUBRESOURCE-VNETID' if rt_first \
         else f'RESOURCE-SUBRESOURCE-VNETID-{rt_codes["privateEndpoints"]}'
    nic_rt = rt_codes.get('networkInterfaces', ABBR['networkInterfaces'])
    pe_nic = f'{nic_rt}-{pe}' if rt_first else f'{pe}-{nic_rt}'

    return {
        'operationsRG':  rg_ops,
        'secretsKV':     kv_sec,
        'encryptionKV':  kv_enc,
        'peNameConv':    pe,
        'peNicNameConv': pe_nic,
        '_uniqueOps':    unique_ops,
    }

# ── Test runner ──────────────────────────────────────────────────────────────
FIELDS = ['operationsRG', 'secretsKV', 'encryptionKV', 'peNameConv', 'peNicNameConv']

def run_scenario(label: str, convention: dict, location: str):
    hp = compute_hostpool_names(convention, location, location, 'avd')
    kv = compute_keyvaults_names(convention, location)

    diffs = [(f, hp[f], kv[f]) for f in FIELDS if hp[f] != kv[f]]
    status = 'PASS' if not diffs else 'FAIL'

    print(f'\n{"="*70}')
    print(f'Scenario: {label}  [{status}]')
    print(f'{"="*70}')
    for f in FIELDS:
        match = '✓' if hp[f] == kv[f] else '✗'
        print(f'  {match} {f}')
        if hp[f] != kv[f]:
            print(f'      HP: {hp[f]}')
            print(f'      KV: {kv[f]}')
        else:
            print(f'      = {hp[f]}')
    return diffs

all_diffs = []

# 1. Default CAF
all_diffs += run_scenario(
    'Default CAF (resourceType-workload-purpose-location)',
    {'components': ['resourceType', 'workload', 'purpose', 'location'], 'delimiter': '-', 'workload': 'avd'},
    'eastus2'
)

# 2. resourceType last
all_diffs += run_scenario(
    'RT last (workload-purpose-location-resourceType)',
    {'components': ['workload', 'purpose', 'location', 'resourceType'], 'delimiter': '-', 'workload': 'avd'},
    'eastus2'
)

# 3. No location in segments (uniqueString seed changes)
all_diffs += run_scenario(
    'No location segment (workload-purpose-resourceType)',
    {'components': ['workload', 'purpose', 'resourceType'], 'delimiter': '-', 'workload': 'avd'},
    'eastus2'
)

# 4. Custom delimiter underscore (triggers kvSanitize difference)
all_diffs += run_scenario(
    'Underscore delimiter (kvSanitize divergence expected)',
    {'components': ['resourceType', 'workload', 'purpose', 'location'], 'delimiter': '_', 'workload': 'avd'},
    'eastus2'
)

# 5. Custom workload
all_diffs += run_scenario(
    'Custom workload (prod)',
    {'components': ['resourceType', 'workload', 'purpose', 'location'], 'delimiter': '-', 'workload': 'prod'},
    'eastus2'
)

# 6. Missing workload key in convention object
all_diffs += run_scenario(
    'Missing workload key in convention (default fallback divergence)',
    {'components': ['resourceType', 'workload', 'purpose', 'location'], 'delimiter': '-'},
    'eastus2'
)

# 7. Custom resourceTypeCodes (partial — hostpool unions with defaults, KV uses directly)
all_diffs += run_scenario(
    'Partial custom resourceTypeCodes (union divergence)',
    {
        'components': ['resourceType', 'workload', 'purpose', 'location'],
        'delimiter': '-',
        'workload': 'avd',
        'resourceTypeCodes': {'keyVaults': 'akv', 'resourceGroups': 'rg', 'privateEndpoints': 'pep', 'networkInterfaces': 'nic'}
    },
    'eastus2'
)

# 8. Westus3 region
all_diffs += run_scenario(
    'Different region (westus3)',
    {'components': ['resourceType', 'workload', 'purpose', 'location'], 'delimiter': '-', 'workload': 'avd'},
    'westus3'
)

print(f'\n{"="*70}')
total = len(FIELDS) * 8
fails = len(all_diffs)
print(f'Summary: {fails} field mismatch(es) across {total} field-checks in 8 scenarios')
if fails:
    print('Fields that diverged:')
    seen = set()
    for f, hp, kv in all_diffs:
        if f not in seen:
            print(f'  - {f}')
            seen.add(f)
