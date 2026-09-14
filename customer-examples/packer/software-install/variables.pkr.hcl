// Mirrors deployments/imageBuild/imageBuild.bicep parameters where a Packer equivalent exists.
// See ../README.md for the full parity mapping and known gaps versus the Bicep zero-trust build.

// * Packer control-plane authentication (calls ARM to create/capture the build VM) * //
// Prefer use_azure_cli_auth or OIDC/federated credentials over client_secret to avoid a stored secret.

variable "use_azure_cli_auth" {
  type        = bool
  default     = true
  description = "Use the active `az login` session instead of a stored client secret."
}

variable "subscription_id" {
  type        = string
  default     = ""
  description = "Required only when use_azure_cli_auth is false."
}

variable "tenant_id" {
  type        = string
  default     = ""
  description = "Required only when use_azure_cli_auth is false."
}

variable "client_id" {
  type        = string
  default     = ""
  description = "AAD application (service principal) ID. Required only when use_azure_cli_auth is false."
}

variable "client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Avoid where possible; prefer use_azure_cli_auth, client_cert_path, or OIDC federated credentials instead."
}

variable "cloud_environment_name" {
  type        = string
  default     = "Public"
  description = "Public, USGovernment, or a custom environment name for air-gapped clouds."
}

// * Build VM placement (no public IP; matches imageBuild.bicep's subnetResourceId model) * //

variable "location" {
  type        = string
  description = "Azure region for the build VM. Must match the region of virtual_network_name."
}

variable "build_resource_group_name" {
  type        = string
  default     = ""
  description = "Optional. Existing resource group to build in. Leave blank to let Packer create and delete a temporary resource group."
}

variable "virtual_network_name" {
  type        = string
  description = "Existing VNet name. Required to avoid a public IP (mirrors imageBuild.bicep's subnetResourceId)."
}

variable "virtual_network_subnet_name" {
  type = string
}

variable "virtual_network_resource_group_name" {
  type = string
}

// * Build VM identity (optional here) * //
// Only needed if you point fslogix_uri/onedrive_uri/teams_uris/office365 downloads at your own
// private blob storage instead of the public Microsoft download URLs used by default below.

variable "user_assigned_identity_resource_ids" {
  type        = list(string)
  default     = []
  description = "Resource ID(s) of a user-assigned managed identity to attach to the build VM. Leave empty unless a *_uri variable below points at your own blob storage."
}

variable "user_assigned_identity_client_id" {
  type        = string
  default     = ""
  description = "Client ID (GUID) of the identity above. az identity show --ids <resourceId> --query clientId -o tsv"
}

// * Build VM sizing and security (matches imageBuild.bicep's VM security defaults) * //

variable "vm_size" {
  type    = string
  default = "Standard_D4ads_v6"
}

variable "os_disk_size_gb" {
  type        = number
  default     = 0
  description = "0 leaves the OS disk at the source image's default size (matches imageBuild.bicep's diskSizeGB=0 behavior)."
}

variable "security_type" {
  type        = string
  default     = "TrustedLaunch"
  description = "TrustedLaunch or ConfidentialVM. Matches imageDefinitionSecurityType."
}

variable "encryption_at_host" {
  type    = bool
  default = true
}

variable "disk_encryption_set_id" {
  type        = string
  default     = ""
  description = "Optional CMK Disk Encryption Set for the build VM's OS disk. Only used when publishing to a Shared Image Gallery (no managed image target)."
}

// * Source image (marketplace) * //

variable "image_publisher" {
  type = string
}

variable "image_offer" {
  type = string
}

variable "image_sku" {
  type = string
}

// * Key Vault used by Packer to inject the temporary WinRM certificate * //

variable "build_key_vault_name" {
  type        = string
  default     = ""
  description = "Optional. Name of an existing private Key Vault to use instead of Packer's ephemeral one."
}

variable "build_key_vault_resource_group_name" {
  type    = string
  default = ""
}

// * WinRM communicator * //
// Invoke-Sysprep.ps1's LogonUser pre-flight check needs a real, known local admin password, which
// the azure-arm builder's auto-generated password can't provide -- see ../README.md "Sysprep
// AdminPassword". Do not commit a real value; use PKR_VAR_admin_password or a secrets manager.

variable "admin_username" {
  type    = string
  default = ""
}

variable "admin_password" {
  type      = string
  default   = ""
  sensitive = true
}

// * Blob-storage authentication, only used if a *_uri variable below points at your own storage * //

variable "blob_storage_suffix" {
  type        = string
  default     = "core.windows.net"
  description = "core.windows.net (Commercial/GCC/GCCH), core.usgovcloudapi.net (Azure Government), or the equivalent for Secret/Top Secret clouds."
}

variable "api_version" {
  type    = string
  default = "2018-02-01"
}

// * Built-in software (matches the corresponding imageBuild.bicep parameters) * //
// Each Install-*.ps1 script downloads its own payload directly from *_uri (a public Microsoft URL
// by default, or your own blob storage if you override it and set the identity variables above).

variable "install_fslogix" {
  type    = bool
  default = false
}

variable "fslogix_uri" {
  type    = string
  default = "https://aka.ms/fslogix_download"
}

variable "office365_apps_to_install" {
  type        = list(string)
  default     = []
  description = "e.g. [\"Excel\", \"Outlook\", \"PowerPoint\", \"Word\"]. Empty list skips Microsoft 365 Apps."
}

variable "install_onedrive" {
  type    = bool
  default = false
}

variable "onedrive_uri" {
  type    = string
  default = "https://go.microsoft.com/fwlink/?linkid=844652"
}

variable "install_teams" {
  type    = bool
  default = false
}

variable "teams_cloud_type" {
  type    = string
  default = "Commercial"
}

variable "teams_uris" {
  type        = list(string)
  default     = []
  description = "Download URLs for the Teams bootstrapper and MSIX (order must match teams_dest_file_names). Required when install_teams is true; see Install-Teams.ps1 for the expected pair."
}

variable "teams_dest_file_names" {
  type        = list(string)
  default     = []
  description = "Destination file names matching teams_uris, e.g. [\"teamsbootstrapper.exe\", \"MSTeams-x64.msix\"]."
}

// * Generic customizers: local artifact folders uploaded with a "file" provisioner and run with a
// "powershell" provisioner -- the most common Packer pattern, and the same one used for the
// built-in scripts above via Packer's script = "..." shorthand (which is upload-then-execute in a
// single block). See ../README.md "Software-Install Example" for why this differs from the STIGs
// example, which needs the same pattern but is kept in its own example folder. * //

variable "artifacts_local_path" {
  type        = string
  default     = "../../../customer/artifacts"
  description = "Local folder containing customizer subfolders (script + installer together), relative to this template or an absolute path. Copy customer-examples/artifacts/<name> here and stage the installer with deployments/Update-ImageArtifacts.ps1 or manually before running packer build."
}

variable "install_7zip" {
  type    = bool
  default = false
}

variable "install_chrome" {
  type    = bool
  default = false
}

variable "chrome_arguments" {
  type    = string
  default = "-DeploymentType Install"
}

// * Maintenance (matches the corresponding imageBuild.bicep parameters) * //

variable "install_updates" {
  type    = bool
  default = false
}

variable "update_service" {
  type    = string
  default = "MU"
}

variable "wsus_server" {
  type    = string
  default = ""
}

variable "cleanup_desktop" {
  type    = bool
  default = false
}

// * Shared Image Gallery destination (matches imageBuild.bicep's Compute Gallery capture) * //

variable "gallery_subscription_id" {
  type    = string
  default = ""
}

variable "gallery_resource_group_name" {
  type = string
}

variable "gallery_name" {
  type = string
}

variable "gallery_image_name" {
  type = string
}

variable "gallery_image_version" {
  type        = string
  default     = ""
  description = "Leave blank to let Packer assign one; otherwise use YYYY.MM.DD or major.minor.patch."
}

variable "gallery_target_regions" {
  type = list(object({
    name                   = string
    replicas               = optional(number, 1)
    storage_account_type   = optional(string, "Standard_LRS")
    disk_encryption_set_id = optional(string, "")
  }))
  description = "Mirrors imageVersionTargetRegions. Must include an entry for the build region."
}

variable "gallery_image_exclude_from_latest" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
