# Packer finalization provisioner

Use `Finalize-STIGsForPacker.ps1` as the **last Packer provisioner** when
`Apply-STIGsAVD.ps1` was run with `-ExecutionProfile Packer`.

The Azure ARM builder does not automatically run Sysprep. It powers off and captures the VM after
all user-defined provisioners finish. This helper performs the required final guest operation by:

1. Restoring `LocalAccountTokenFilterPolicy` to `0`.
2. Enforcing disabled WinRM Basic authentication while retaining NTLM over HTTPS support.
3. Restoring the local-account SIDs in `SeDenyNetworkLogonRight` while preserving all other
   principals already assigned to that right.
4. Optionally restoring domain-oriented firewall local-policy merge restrictions.
5. Waiting for installed Azure Guest Agent services.
6. Running Sysprep with `/oobe /generalize /quiet /quit /mode:vm`.
7. Waiting until Windows reports `IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE`.

Do not run another provisioner, restart the VM, or reconnect through WinRM after this helper.
Packer should proceed directly to its normal power-off and image-capture phase.

## Prerequisites

- Run `Apply-STIGsAVD.ps1 -ExecutionProfile Packer` earlier in the build.
- Configure the Packer communicator to use NTLM over HTTPS. Do not enable Basic authentication or
  unencrypted WinRM.
- Complete all software installation, Windows Update, restarts, and validation before this helper.
- Run the helper from an elevated local administrator session.

## HCL example: workgroup final state

For an image that will remain in a workgroup, reference the helper directly as the final
provisioner:

```hcl
provisioner "powershell" {
  script = "customer/artifacts/DoD-STIGs/packer/Finalize-STIGsForPacker.ps1"
}
```

The workgroup path leaves local firewall-rule merge available because workgroup systems depend on
local firewall rules.

## HCL example: image intended for domain join

Pass `-IntendedDomainJoined` when the image is guaranteed to join a domain. This must match the
intended-domain choice used when applying the STIG artifact.

```hcl
provisioner "file" {
  source      = "customer/artifacts/DoD-STIGs/packer/Finalize-STIGsForPacker.ps1"
  destination = "C:\\Windows\\Temp\\Finalize-STIGsForPacker.ps1"
}

provisioner "powershell" {
  inline = [
    "& 'C:\\Windows\\Temp\\Finalize-STIGsForPacker.ps1' -IntendedDomainJoined"
  ]
}
```

The finalizer persists the restrictive settings in local policy and applies their effective
registry values before capture. The current WinRM process is expected to finish, but the restored
network-logon and firewall restrictions can prevent any subsequent connection.

## Packer build order

A typical Windows build should end in this order:

1. Install software and updates.
2. Restart as required.
3. Run `Apply-STIGsAVD.ps1 -ExecutionProfile Packer`.
4. Run any validation that still requires WinRM.
5. Upload this helper if arguments are required.
6. Run this helper as the final PowerShell provisioner.
7. Let the Azure ARM builder power off and capture the generalized VM.

For the authoritative Azure ARM builder deprovisioning guidance, see
<https://developer.hashicorp.com/packer/integrations/hashicorp/azure/latest/components/builder/arm#deprovision>.
