import json, re

arm_text = open('deployments/hostpools/hostpool.json', encoding='utf-8').read()

# Find all __bicep.cnv( call occurrences and measure their lengths
pattern = re.compile(r'__bicep\.cnv\(')
matches = list(pattern.finditer(arm_text))
print('Total __bicep.cnv( occurrences:', len(matches))

# For each match, find the matching closing paren to get full call length
def find_call_end(text, start):
    depth = 0
    i = start
    while i < len(text):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1

call_lengths = []
for m in matches:
    end = find_call_end(arm_text, m.start())
    if end > 0:
        call_text = arm_text[m.start():end]
        call_lengths.append(len(call_text))

call_lengths.sort(reverse=True)
print('Call lengths (chars): min=%d max=%d avg=%d' % (min(call_lengths), max(call_lengths), sum(call_lengths)//len(call_lengths)))
print('Total chars in all __bicep.cnv() calls:', sum(call_lengths))
print()

# What would these look like if they were ARM variables instead?
# Each call would be replaced by variables('xxxName') = ~20 chars avg
# Savings = total_call_chars - (num_calls * 20) - (num_unique_vars * avg_call_len)
# But we need to know how many are unique vs repeated
# Approximate: the 26 unique Bicep naming vars each become one ARM variable definition
# All references become variables('xxx') = ~20 chars

# Count how many unique __bicep calls there are (unique by content)
all_calls = []
for m in matches:
    end = find_call_end(arm_text, m.start())
    if end > 0:
        all_calls.append(arm_text[m.start():end])

unique_calls = set(all_calls)
print('Unique __bicep.cnv() call expressions:', len(unique_calls))
print('Repeated calls (same expression used multiple times):')
from collections import Counter
counts = Counter(all_calls)
for call, count in sorted(counts.items(), key=lambda x: -x[1]):
    if count > 1:
        print(f'  x{count} ({len(call)} chars): {call[:120]}...')

print()
# Total waste from repetition
savings_from_dedup = sum((count-1) * len(call) for call, count in counts.items())
print('Chars that could be saved by deduplicating (ARM var per unique expr):', savings_from_dedup)

# Also count __bicep. refs that are NOT cnv (buildCustomName etc)
other_refs = arm_text.count('__bicep.') - len(matches)
print('Other __bicep. UDF refs (not cnv):', other_refs)
