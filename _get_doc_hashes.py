import hashlib, json

with open('.common/data/resourceAbbreviations.json') as f: ABBR = json.load(f)
with open('.common/data/locations.json') as f: ALL_LOCS = json.load(f)
LOCS = ALL_LOCS['AzureCloud']
SUB = '67edfd17-f0d1-466a-aacb-ca9daeabb9b8'

def arm_unique(*inputs):
    combined = ''.join(str(i).lower() for i in inputs)
    return hashlib.sha256(combined.encode()).hexdigest()[:13]

def loc(r): return LOCS[r]['abbreviation']

# Scenario 1 & 3 & 5 & 6: eastus, default CAF (includes 'location')
r1 = f'rg-avd-operations-{loc("eastus")}'
u1 = arm_unique(SUB, r1)[:6]
print(f'eastus  rg={r1}  unique={u1}  kv-sec=kv-avd-sec-{loc("eastus")}-{u1}')

# Scenario 2: westus2
r2 = f'rg-avd-operations-{loc("westus2")}'
u2 = arm_unique(SUB, r2)[:6]
print(f'westus2 rg={r2}  unique={u2}  kv-sec=kv-avd-sec-{loc("westus2")}-{u2}')

# Scenario 4: RT-last, eastus — rg changes
r4 = f'avd-operations-{loc("eastus")}-rg'
u4 = arm_unique(SUB, r4)[:6]
print(f'RT-last eastus rg={r4}  unique={u4}  kv-sec=avd-sec-{loc("eastus")}-kv-{u4}')

# Scenario 7: no location segment — uses location in seed
r7 = 'avd-operations-rg'
u7 = arm_unique(SUB, r7, 'eastus')[:6]
print(f'no-loc  rg={r7}  unique={u7}  kv-sec=avd-sec-kv-{u7}')

# Scenario 8: freeform1 = 'contoso', RT-first, eastus
r8 = f'rg-contoso-avd-operations-{loc("eastus")}'
u8 = arm_unique(SUB, r8)[:6]
print(f'freeform1 rg={r8}  unique={u8}  kv-sec=kv-contoso-avd-sec-{loc("eastus")}-{u8}')
