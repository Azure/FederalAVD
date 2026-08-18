# Artifact Review Checklist

- The artifact folder has a README and at least one PowerShell script.
- PowerShell files contain ASCII characters only.
- Download definitions use a source type supported by `Update-ImageArtifacts.ps1`.
- `DestinationFileName` matches the name expected by the installer.
- `DestinationFolders` uses the exact artifact folder name.
- The README gives a command that writes the payload into the folder containing the README.
- Public endpoints have an air-gapped pre-staging path.
- No downloaded binary, customer parameter file, credential, or secret is committed.
- Documentation links and Markdown validation pass.
