---
mode: ask
description: Guide me through getting started with FederalAVD — deployment path, prerequisites, and first steps.
---

I am new to this repo and want to deploy Azure Virtual Desktop using FederalAVD.

Help me figure out my deployment path by asking me a few questions:

1. Which Azure cloud am I deploying to? (Commercial, Government, Government Secret, Government Top Secret)
2. Do I already have a VNet and subnet, or do I need to deploy networking from scratch?
3. Do I need custom software baked into the session host images, or are marketplace images sufficient?
4. Am I using Customer-Managed Keys (CMK) for encryption?
5. Do I need a fully automated, recurring image refresh pipeline, or is a one-time deployment sufficient?

Based on my answers, tell me:
- Which deployment steps apply to me (Steps 0–4) and which I can skip
- Which deployment method to use (Blue Button, Template Specs, or PowerShell) given my cloud
- Which parameter example files to start from under `customer/examples/parameters/`
- Which documentation pages are most relevant for my scenario
- Any prerequisites I need to have in place before I start

Keep the guidance practical and specific to my answers. Point me to the exact files and docs I need rather than giving generic advice.
