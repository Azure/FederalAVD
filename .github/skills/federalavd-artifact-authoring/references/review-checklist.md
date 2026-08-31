# Artifact Review Checklist

- The artifact folder has a README and exactly one PowerShell script in its root.
- Helper scripts, including separate uninstall helpers, are stored in a subdirectory so they cannot
  be selected as the artifact entry point.
- Application artifacts used as VM Applications expose `-DeploymentType Install|Uninstall` from
  the root script instead of adding a second root uninstall script.
- PowerShell files contain ASCII characters only.
- Download definitions use a source type supported by `Update-ImageArtifacts.ps1`.
- `DestinationFileName` matches the name expected by the installer.
- `DestinationFolders` uses the exact artifact folder name.
- The README gives a command that writes the payload into the folder containing the README.
- Public endpoints have an air-gapped pre-staging path.
- No downloaded binary, customer parameter file, credential, or secret is committed.
- Documentation links and Markdown validation pass.
