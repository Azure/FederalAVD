---
mode: ask
description: Help me diagnose and fix a FederalAVD deployment error or unexpected behavior.
---

I am troubleshooting an issue with a FederalAVD deployment.

To help me diagnose the problem, please ask me:

1. Which deployment step failed or is behaving unexpectedly? (Networking / Key Vaults / Image Management / Image Build / Host Pool / Session Host Replacer / Update-ImageArtifacts)
2. Which Azure cloud am I in? (Commercial / Government / Secret / Top Secret)
3. What deployment method am I using? (Blue Button / Template Spec / PowerShell)
4. What is the exact error message, error code, or symptom I am seeing?
5. Is this a first-time deployment or a re-deployment / update?

Based on my answers:
- Check `docs/troubleshooting.md` for matching errors and apply any documented fix
- If the error is not in the troubleshooting doc, reason through the most likely cause based on the deployment step and error details
- Identify the specific parameter, resource, or permission most likely responsible
- Tell me the exact remediation steps — commands to run, parameters to change, or Azure portal actions to take
- Flag if the issue might be air-gapped-specific (missing endpoints, no Blue Button, etc.) and point me to `docs/air-gapped-clouds.md` if relevant

Be specific. Avoid generic "check your permissions" advice — tell me which role is needed and on which resource.
