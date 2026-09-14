// Sample Packer template: apply DoD STIGs to a Windows image using the standard Packer pattern --
// a "file" provisioner uploads the local customer-examples/artifacts/DoD-STIGs folder, then
// "powershell" provisioners run Apply-STIGsAVD.ps1 and its Packer finalizer inside it. No blob
// storage or managed identity is used; Apply-STIGsAVD.ps1 downloads the STIG GPO package itself.
//
// Read ../README.md first, and customer-examples/artifacts/DoD-STIGs/packer/README.md for the
// full build-order rationale this template follows. See ../software-install/ for FSLogix/M365/
// OneDrive/Teams/7-Zip/Chrome examples.

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = ">= 2.0.0"
    }
  }
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
  location                            = var.location
  build_resource_group_name           = var.build_resource_group_name != "" ? var.build_resource_group_name : null
  virtual_network_name                = var.virtual_network_name
  virtual_network_subnet_name         = var.virtual_network_subnet_name
  virtual_network_resource_group_name = var.virtual_network_resource_group_name
  # private_virtual_network_with_public_ip defaults to false: no public IP is created.

  # --- VM sizing and security (mirrors imageBuild.bicep's VM security defaults) ---
  vm_size                = var.vm_size
  os_disk_size_gb        = var.os_disk_size_gb > 0 ? var.os_disk_size_gb : null
  security_type          = var.security_type
  secure_boot_enabled    = var.security_type != "Standard"
  vtpm_enabled           = var.security_type != "Standard"
  encryption_at_host     = var.encryption_at_host
  disk_encryption_set_id = var.disk_encryption_set_id != "" ? var.disk_encryption_set_id : null

  # --- Source image (marketplace) ---
  image_publisher = var.image_publisher
  image_offer     = var.image_offer
  image_sku       = var.image_sku

  # --- Windows communicator: NTLM over HTTPS, per the DoD-STIGs Packer profile requirement ---
  os_type        = "Windows"
  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_use_ntlm = true
  winrm_insecure = true
  winrm_timeout  = "45m"
  winrm_username = var.admin_username
  winrm_password = var.admin_password

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

  # --- Windows Update, before STIGs are applied (see the DoD-STIGs Packer README build order) ---
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

  # --- Upload the whole DoD-STIGs folder once; this also brings along its packer/ subfolder,
  # which contains the finalizer used below. ---
  provisioner "file" {
    source      = "${var.artifacts_local_path}/DoD-STIGs/"
    destination = "C:/Windows/Temp/DoD-STIGs"
  }

  # --- Apply STIGs. -ExecutionProfile Packer keeps the temporary WinRM/firewall exceptions
  # Packer's communicator needs until Finalize-STIGsForPacker.ps1 restores them. ---
  provisioner "powershell" {
    inline  = ["& 'C:/Windows/Temp/DoD-STIGs/Apply-STIGsAVD.ps1' ${var.stigs_arguments}"]
    timeout = "30m"
  }

  # --- Finalize: restores the temporary exceptions and runs Sysprep itself. Must be the last
  # provisioner -- do not add anything after it; Packer should proceed straight to capture. ---
  provisioner "powershell" {
    inline = ["& 'C:/Windows/Temp/DoD-STIGs/packer/Finalize-STIGsForPacker.ps1'${var.stigs_intended_domain_joined ? " -IntendedDomainJoined" : ""}"]
  }
}
