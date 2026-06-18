import io, sys, importlib, types
sys.stdout.reconfigure(encoding='utf-8')

src = open('_generate_test_results.py', encoding='utf-8').read()
# Only exec the non-output part (up to the markdown generation)
src_defs = src.split('# ─── Markdown')[0]
ns = {}
exec(src_defs, ns)

SCENARIOS = ns['SCENARIOS']
compute_all = ns['compute_all']

sc7 = next(s for s in SCENARIOS if s['n'] == 7)
print(f"Scenario 7: {sc7['label']}")
print(f"Convention: {sc7['convention']}")
print(f"Region: {sc7['vms_region']}")
print()
r = compute_all(sc7)
for k, v in sorted(r.items()):
    print(f"  {k:45} = {v}")
