// Mirrors deployments/imageBuild/imageBuild.bicep parameters where a Packer equivalent exists.
// See ../README.md for the full parity mapping and known gaps versus the Bicep zero-trust build.
// This example applies DoD STIGs only; see ../software-install/ for a software-install example.

// * Packer control-plane authentication (calls ARM to create/capture the build VM) * //

variable "use_azure_cli_auth" {
  type        = bool
  default     = true
  description = "Use the active `az login` session instead of a stored client secret."
}

variable "subscription_id" {
  type    = string
  default = ""
}

variable "tenant_id" {
  type    = string
  default = ""
}

variable "client_id" {
  type    = string
  default = ""
}

variable "client_secret" {
  type      = string
  default   = ""
  sensitive = true
}

variable "cloud_environment_name" {
  type    = string
  default = "Public"
}

// * Build VM placement (no public IP; matches imageBuild.bicep's subnetResourceId model) * //

variable "location" {
  type = string
}

variable "build_resource_group_name" {
  type    = string
  default = ""
}

variable "virtual_network_name" {
  type = string
}

variable "virtual_network_subnet_name" {
  type = string
}

variable "virtual_network_resource_group_name" {
  type = string
}

// * Build VM sizing and security (matches imageBuild.bicep's VM security defaults) * //

variable "vm_size" {
  type    = string
  default = "Standard_D4ads_v6"
}

variable "os_disk_size_gb" {
  type    = number
  default = 0
}

variable "security_type" {
  type    = string
  default = "TrustedLaunch"
}

variable "encryption_at_host" {
  type    = bool
  default = true
}

variable "disk_encryption_set_id" {
  type    = string
  default = ""
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
  type    = string
  default = ""
}

variable "build_key_vault_resource_group_name" {
  type    = string
  default = ""
}

// * WinRM communicator * //
// The DoD-STIGs Packer profile requires NTLM over HTTPS (set below in the source block) and needs
// a real admin_username/admin_password -- Apply-STIGsAVD.ps1 temporarily preserves this account's
// network logon during provisioning, and Finalize-STIGsForPacker.ps1 restores policy afterward.

variable "admin_username" {
  type = string
}

variable "admin_password" {
  type      = string
  sensitive = true
}

// * DoD STIGs artifact (local folder uploaded with a "file" provisioner, run with "powershell") * //

variable "artifacts_local_path" {
  type        = string
  default     = "../../../customer/artifacts"
  description = "Local folder containing the DoD-STIGs subfolder, relative to this template or an absolute path. Copy customer-examples/artifacts/DoD-STIGs here first."
}

variable "stigs_arguments" {
  type        = string
  default     = "-ExecutionProfile Packer"
  description = "Passed to Apply-STIGsAVD.ps1. Must include -ExecutionProfile Packer so the temporary WinRM/firewall exceptions Packer's communicator needs stay in place until Finalize-STIGsForPacker.ps1 restores them."
}

variable "stigs_intended_domain_joined" {
  type        = bool
  default     = false
  description = "Passed to Finalize-STIGsForPacker.ps1 as -IntendedDomainJoined. Only set true when the captured image is guaranteed to join a domain."
}

// * Windows Update, run before STIGs are applied (see customer-examples/artifacts/DoD-STIGs/packer/README.md build order) * //

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
  type    = string
  default = ""
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
