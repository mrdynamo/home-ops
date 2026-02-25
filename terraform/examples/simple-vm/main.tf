terraform {
  required_providers {
    vsphere = {
      source  = "hashicorp/vsphere"
      version = ">= 2.4.0"
    }
  }
}

provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = var.allow_unverified_ssl
}

module "test_vm" {
  source = "../../modules/vsphere/vm"

  vsphere_server   = var.vsphere_server
  vsphere_user     = var.vsphere_user
  vsphere_password = var.vsphere_password

  datacenter    = var.datacenter
  cluster       = var.cluster
  resource_pool = var.resource_pool
  datastore     = var.datastore
  network       = var.network
  template_name = var.template_name
  domain        = var.domain

  vm_name_prefix = var.vm_name_prefix
  vm_count       = 1
  vm_cpus        = var.vm_cpus
  vm_memory_mb   = var.vm_memory_mb
}

output "vm_names" {
  value = module.test_vm.vm_names
}
