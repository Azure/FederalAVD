# Compliance Review Boundaries

- Repository mappings are implementation guidance, not an authorization to operate.
- Parameter files are intended-state evidence; deployed Azure resources and logs are stronger
  operating evidence.
- A missing parameter may use a secure template default. Confirm the exact Bicep version before
  assigning a gap.
- External controls such as Conditional Access, incident response, personnel controls, data
  classification, and SSP procedures cannot be validated from this repository.
- Treat partial controls and documented gaps explicitly.
- Cite the exact framework version and current official Azure service guidance.
- Do not expose password, secret, token, or credential parameter values in reports.
