module "vsphere_vms" {
  source = "./modules/vsphere/vm"

  vsphere_server       = var.vsphere_server
  vsphere_user         = var.vsphere_user
  vsphere_password     = var.vsphere_password
  datacenter           = var.datacenter
  cluster              = var.cluster
  resource_pool        = var.resource_pool
  datastore            = var.datastore
  network              = var.network
  template_name        = var.template_name
  domain               = var.domain

  # Module-specific VM parameters (example)
  vm_name_prefix = "bootstrap"
  vm_count       = 1
  vm_cpus        = 2
  vm_memory_mb   = 4096
}
