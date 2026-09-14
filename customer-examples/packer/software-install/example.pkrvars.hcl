// EXAMPLE variable values for the software-install Packer sample. Copy this file (do not edit in
// place), rename it, and replace placeholders before running:
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

# --- Build VM identity: leave empty unless *_uri variables below point at your own blob storage. ---
user_assigned_identity_resource_ids = []
user_assigned_identity_client_id    = ""

// --- Build VM sizing and security ---
vm_size            = "Standard_D4ads_v6"
security_type      = "TrustedLaunch"
encryption_at_host = true

// --- Source image (marketplace) ---
image_publisher = "MicrosoftWindowsDesktop"
image_offer     = "office-365"
image_sku       = "win11-23h2-avd-m365"

// --- WinRM communicator ---
// Required (non-blank) so Invoke-Sysprep.ps1's LogonUser pre-flight check has a known password.
admin_username = "packerbuild"
admin_password = "REPLACE_WITH_A_STRONG_PASSWORD"

// --- Built-in software (public Microsoft download URLs; no blob storage needed) ---
install_fslogix           = true
office365_apps_to_install = ["Excel", "OneNote", "Outlook", "PowerPoint", "Word"]
install_onedrive          = true
install_teams             = true
teams_cloud_type          = "Commercial" // Commercial | GCC | GCCH | DOD
teams_uris = [
  "https://statics.teams.cdn.office.net/production-windows-x64/enterprise/webview2/lkg/teamsbootstrapper.exe",
  "https://statics.teams.cdn.office.net/production-windows-x64/enterprise/webview2/lkg/MSTeams-x64.msix"
]
teams_dest_file_names = ["teamsbootstrapper.exe", "MSTeams-x64.msix"]

// --- Generic customizers: file provisioner + powershell provisioner ---
// Copy customer-examples/artifacts/7-Zip and customer-examples/artifacts/Google-Chrome-Enterprise
// into customer/artifacts first, and stage each installer (e.g. with
// deployments/Update-ImageArtifacts.ps1) so the .msi sits next to the Deploy-*.ps1 script.
artifacts_local_path = "../../../customer/artifacts"
install_7zip          = true
install_chrome        = true
chrome_arguments      = "-DeploymentType Install"

// --- Maintenance ---
install_updates = true
update_service  = "MU"
cleanup_desktop = true

// --- Shared Image Gallery destination ---
gallery_resource_group_name = "rg-avd-imagemgmt"
gallery_name                = "gal_avd_shared"
gallery_image_name          = "win11-avd-m365"
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
