# Azure VM Image Builder deprovisioning override

Microsoft Azure VM Image Builder (AIB) uses a managed Packer process to customize Windows build
VMs over WinRM HTTPS port 5986. Applying the DISA STIG policy before the build finishes can block
that transport by denying network logon to local accounts, filtering the local administrator
token, disabling WinRM authentication, or suppressing locally registered firewall rules.

Run the main artifact with:

```powershell
.\Apply-STIGsAVD.ps1 -ExecutionProfile AzureVMImageBuilder
```

The main script automatically:

1. Applies temporary AIB WinRM compatibility exceptions.
2. Records whether the image's effective final state is domain joined.
3. Copies `DeprovisioningScript.ps1` to `C:\DeprovisioningScript.ps1`.

AIB adds a hidden final PowerShell customizer and executes that exact path after all declared
customizers. The supplied override then:

1. Restores `LocalAccountTokenFilterPolicy` to `0`.
2. Restores WinRM service `AllowBasic` to `0`.
3. Restores the local-account SIDs in `SeDenyNetworkLogonRight` while preserving other principals.
4. Restores domain-oriented firewall local-policy merge restrictions when applicable.
5. Waits for installed Azure Guest Agent services.
6. Runs Sysprep with `/oobe /generalize /quiet /quit /mode:vm`.
7. Waits for `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE` before returning control to AIB.

Do not add another Sysprep customizer. Do not overwrite or delete `C:\DeprovisioningScript.ps1`
after the STIG customizer. Customizers that run afterward still depend on WinRM, so final policy is
restored only inside AIB's hidden deprovisioning step.

For images guaranteed to join a domain, pass `-OverrideDomainJoin` with the execution profile. The
deprovisioning override restores the domain-oriented firewall merge restrictions before capture.

Microsoft documents the WinRM connection, hidden customizer, deprovisioning path, and override
contract in the Azure VM Image Builder troubleshooting guidance:
<https://learn.microsoft.com/azure/virtual-machines/linux/image-builder-troubleshoot>.