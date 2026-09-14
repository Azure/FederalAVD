// Sample Packer template: FSLogix, Microsoft 365 Apps, OneDrive, and Teams (built-in software,
// same scripts imageBuild.bicep uses) plus two generic customizers -- 7-Zip and Google Chrome
// Enterprise -- using the most common Packer pattern: a "file" provisioner uploads a local
// artifact folder, then a "powershell" provisioner runs the script inside it.
//
// Read ../README.md first: it documents the security-model differences (WinRM vs. Azure Run
// Command), the AdminPassword caveat for sysprep, and required RBAC. See ../stigs/ for the
// separate DoD STIGs example.

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = ">= 2.0.0"
    }
  }
}

locals {
  office365_apps_json   = jsonencode(var.office365_apps_to_install)
  teams_uris_json       = jsonencode(var.teams_uris)
  teams_dest_files_json = jsonencode(var.teams_dest_file_names)

  install_any_software = var.install_fslogix || length(var.office365_apps_to_install) > 0 || var.install_onedrive || var.install_teams || var.install_7zip || var.install_chrome
}

source "azure-arm" "image_build" {
  # --- Packer control-plane authentication (calls ARM; separate from the build VM's identity) ---
  use_azure_cli_auth     = var.use_azure_cli_auth
  subscription_id        = var.use_azure_cli_auth ? null : var.subscription_id
  tenant_id              = var.use_azure_cli_auth ? null : var.tenant_id
  client_id              = var.use_azure_cli_auth ? null : var.client_id
  client_secret          = var.use_azure_cli_auth ? null : var.client_secret
  cloud_environment_name = var.cloud_environment_name

  # --- Placement: existing VNet/subnet, no public IP (mirrors subnetResourceId) ---
  location                             = var.location
  build_resource_group_name            = var.build_resource_group_name != "" ? var.build_resource_group_name : null
  virtual_network_name                 = var.virtual_network_name
  virtual_network_subnet_name          = var.virtual_network_subnet_name
  virtual_network_resource_group_name  = var.virtual_network_resource_group_name
  # private_virtual_network_with_public_ip defaults to false: no public IP is created.

  # --- Build VM identity (only needed if a *_uri variable points at your own blob storage) ---
  user_assigned_managed_identities = var.user_assigned_identity_resource_ids

  # --- VM sizing and security (mirrors imageBuild.bicep's VM security defaults) ---
  vm_size                 = var.vm_size
  os_disk_size_gb         = var.os_disk_size_gb > 0 ? var.os_disk_size_gb : null
  security_type           = var.security_type
  secure_boot_enabled     = var.security_type != "Standard"
  vtpm_enabled            = var.security_type != "Standard"
  encryption_at_host      = var.encryption_at_host
  disk_encryption_set_id  = var.disk_encryption_set_id != "" ? var.disk_encryption_set_id : null

  # --- Source image (marketplace) ---
  image_publisher = var.image_publisher
  image_offer     = var.image_offer
  image_sku       = var.image_sku

  # --- Windows communicator ---
  os_type        = "Windows"
  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_use_ntlm = true
  winrm_insecure = true
  winrm_timeout  = "45m"
  winrm_username = var.admin_username != "" ? var.admin_username : null
  winrm_password = var.admin_password != "" ? var.admin_password : null

  build_key_vault_name                = var.build_key_vault_name != "" ? var.build_key_vault_name : null
  build_key_vault_resource_group_name = var.build_key_vault_resource_group_name != "" ? var.build_key_vault_resource_group_name : null

  # --- Destination: Shared Image Gallery (mirrors the Compute Gallery capture step) ---
  shared_image_gallery_destination {
    subscription   = var.gallery_subscription_id != "" ? var.gallery_subscription_id : null
    resource_group = var.gallery_resource_group_name
    gallery_name   = var.gallery_name
    image_name     = var.gallery_image_name
    image_version  = var.gallery_image_version != "" ? var.gallery_image_version : formatdate("YYYY.MM.DD", timestamp())

    dynamic "target_region" {
      for_each = var.gallery_target_regions
      content {
        name                   = target_region.value.name
        replicas               = target_region.value.replicas
        storage_account_type   = target_region.value.storage_account_type
        disk_encryption_set_id = target_region.value.disk_encryption_set_id != "" ? target_region.value.disk_encryption_set_id : null
      }
    }
  }
  shared_gallery_image_version_exclude_from_latest = var.gallery_image_exclude_from_latest

  azure_tags = var.tags
}

build {
  sources = ["source.azure-arm.image_build"]

  # --- Built-in software: Packer's script = "..." attribute uploads the script and runs it in one
  # block -- upload-then-execute, the same underlying mechanism as the explicit file+powershell
  # pattern below, just condensed for a single self-contained script. Each script downloads its own
  # payload from *_uri (a public Microsoft URL by default). ---
  provisioner "powershell" {
    only            = var.install_fslogix ? ["azure-arm.image_build"] : []
    script          = "${path.root}/../../../deployments/imageBuild/scripts/Install-FSLogix.ps1"
    execute_command = "powershell -ExecutionPolicy Bypass -File \"{{.Path}}\" -APIVersion '${var.api_version}' -BlobStorageSuffix '${var.blob_storage_suffix}' -UserAssignedIdentityClientId '${var.user_assigned_identity_client_id}' -Uri '${var.fslogix_uri}'"
  }

  provisioner "powershell" {
    only            = length(var.office365_apps_to_install) > 0 ? ["azure-arm.image_build"] : []
    script          = "${path.root}/../../../deployments/imageBuild/scripts/Install-M365Applications.ps1"
    execute_command = "powershell -ExecutionPolicy Bypass -File \"{{.Path}}\" -APIVersion '${var.api_version}' -AppsToInstall '${local.office365_apps_json}' -BlobStorageSuffix '${var.blob_storage_suffix}' -Environment '${var.cloud_environment_name}' -UserAssignedIdentityClientId '${var.user_assigned_identity_client_id}'"
  }

  provisioner "powershell" {
    only            = var.install_onedrive ? ["azure-arm.image_build"] : []
    script          = "${path.root}/../../../deployments/imageBuild/scripts/Install-OneDrive.ps1"
    execute_command = "powershell -ExecutionPolicy Bypass -File \"{{.Path}}\" -APIVersion '${var.api_version}' -BlobStorageSuffix '${var.blob_storage_suffix}' -UserAssignedIdentityClientId '${var.user_assigned_identity_client_id}' -Uri '${var.onedrive_uri}'"
  }

  provisioner "powershell" {
    only            = var.install_teams ? ["azure-arm.image_build"] : []
    script          = "${path.root}/../../../deployments/imageBuild/scripts/Install-Teams.ps1"
    execute_command = "powershell -ExecutionPolicy Bypass -File \"{{.Path}}\" -APIVersion '${var.api_version}' -BlobStorageSuffix '${var.blob_storage_suffix}' -UserAssignedIdentityClientId '${var.user_assigned_identity_client_id}' -TeamsCloudType '${var.teams_cloud_type}' -Uris '${local.teams_uris_json}' -DestFileNames '${local.teams_dest_files_json}'"
  }

  # --- Generic customizers: file provisioner uploads the local artifact folder (script + payload
  # together, e.g. Deploy-7-Zip.ps1 next to its .msi), then a powershell provisioner runs the
  # uploaded script. This is the standard Packer idiom for custom software. ---
  provisioner "file" {
    only        = var.install_7zip ? ["azure-arm.image_build"] : []
    source      = "${var.artifacts_local_path}/7-Zip/"
    destination = "C:/Windows/Temp/7-Zip"
  }

  provisioner "powershell" {
    only   = var.install_7zip ? ["azure-arm.image_build"] : []
    inline = ["& 'C:/Windows/Temp/7-Zip/Deploy-7-Zip.ps1'"]
  }

  provisioner "file" {
    only        = var.install_chrome ? ["azure-arm.image_build"] : []
    source      = "${var.artifacts_local_path}/Google-Chrome-Enterprise/"
    destination = "C:/Windows/Temp/Google-Chrome-Enterprise"
  }

  provisioner "powershell" {
    only   = var.install_chrome ? ["azure-arm.image_build"] : []
    inline = ["& 'C:/Windows/Temp/Google-Chrome-Enterprise/Deploy-GoogleChromeEnterprise.ps1' ${var.chrome_arguments}"]
  }

  provisioner "windows-restart" {
    only            = local.install_any_software ? ["azure-arm.image_build"] : []
    pause_before    = "30s"
    restart_timeout = "15m"
  }

  # --- Windows Update ---
  provisioner "powershell" {
    only            = var.install_updates ? ["azure-arm.image_build"] : []
    script          = "${path.root}/../../../deployments/imageBuild/scripts/Invoke-WindowsUpdate.ps1"
    execute_command = "powershell -ExecutionPolicy Bypass -File \"{{.Path}}\" -Service '${var.update_service}' -WSUSServer '${var.wsus_server}'"
    timeout         = "60m"
  }

  provisioner "windows-restart" {
    only            = var.install_updates ? ["azure-arm.image_build"] : []
    pause_before    = "30s"
    restart_timeout = "30m"
  }

  # --- Cleanup desktop shortcuts ---
  provisioner "powershell" {
    only   = var.cleanup_desktop ? ["azure-arm.image_build"] : []
    inline = ["Remove-Item \"$Env:Public\\Desktop\\*\" -Force -ErrorAction SilentlyContinue"]
  }

  # --- Disk cleanup ---
  provisioner "powershell" {
    script = "${path.root}/../../../deployments/imageBuild/scripts/Invoke-DiskCleanup.ps1"
  }

  # --- Sysprep (must be the last provisioner; Packer captures the VM immediately after) ---
  provisioner "powershell" {
    script          = "${path.root}/../../../deployments/imageBuild/scripts/Invoke-Sysprep.ps1"
    execute_command = "powershell -ExecutionPolicy Bypass -File \"{{.Path}}\" -AdminPassword '${var.admin_password}'"
  }
}
