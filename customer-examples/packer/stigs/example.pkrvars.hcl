// EXAMPLE variable values for the DoD STIGs Packer sample. Copy this file (do not edit in place),
// rename it, and replace placeholders before running:
//   packer init image-build.pkr.hcl
//   packer validate -var-file=<your>.pkrvars.hcl image-build.pkr.hcl
//   packer build    -var-file=<your>.pkrvars.hcl image-build.pkr.hcl

// --- Packer control-plane authentication ---
use_azure_cli_auth     = true
cloud_environment_name = "Public" // Public | USGovernment | (custom name for Secret/Top Secret)

// --- Build VM placement (no public IP) ---
location                            = "usgovvirginia"
build_resource_group_name           = "rg-avd-imagebuild"
virtual_network_name                = "vnet-avd-shared"
virtual_network_subnet_name         = "snet-imagebuild"
virtual_network_resource_group_name = "rg-avd-networking"

// --- Build VM sizing and security ---
vm_size            = "Standard_D4ads_v6"
security_type      = "TrustedLaunch"
encryption_at_host = true

// --- Source image (marketplace) ---
image_publisher = "MicrosoftWindowsDesktop"
image_offer     = "office-365"
image_sku       = "win11-23h2-avd-m365"

// --- WinRM communicator ---
// Apply-STIGsAVD.ps1 -ExecutionProfile Packer temporarily preserves this account's network logon
// during provisioning; Finalize-STIGsForPacker.ps1 restores policy afterward.
admin_username = "packerbuild"
admin_password = "REPLACE_WITH_A_STRONG_PASSWORD"

// --- DoD STIGs artifact ---
// Copy customer-examples/artifacts/DoD-STIGs into customer/artifacts first.
artifacts_local_path         = "../../../customer/artifacts"
stigs_arguments              = "-ExecutionProfile Packer"
stigs_intended_domain_joined = false

// --- Windows Update (runs before STIGs are applied) ---
install_updates = true
update_service  = "MU"

// --- Shared Image Gallery destination ---
gallery_resource_group_name = "rg-avd-imagemgmt"
gallery_name                = "gal_avd_shared"
gallery_image_name          = "win11-avd-m365-stig"
gallery_target_regions = [
  {
    name     = "usgovvirginia"
    replicas = 1
  }
]
gallery_image_exclude_from_latest = false

tags = {
  environment = "prod"
  workload    = "avd"
}
