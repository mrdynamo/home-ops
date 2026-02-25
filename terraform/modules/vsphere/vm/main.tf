/*
  Simple VM module for cloning a template and creating one or more VMs.
  Customize as needed for your environment.
*/

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_datastore" "ds" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

# resource pool: optional. If `var.resource_pool` is provided we'll look it up,
# otherwise we'll use the cluster's default resource pool below.
data "vsphere_resource_pool" "pool" {
  count         = var.resource_pool != "" ? 1 : 0
  name          = var.resource_pool
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_compute_cluster" "cluster" {
  count         = var.cluster != "" ? 1 : 0
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "net" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_virtual_machine" "vm" {
  count            = var.vm_count
  name             = format("%s-%02d", var.vm_name_prefix, count.index + 1)
  resource_pool_id = var.resource_pool != "" ? data.vsphere_resource_pool.pool[0].id : (var.cluster != "" ? data.vsphere_compute_cluster.cluster[0].resource_pool_id : "")
  datastore_id     = data.vsphere_datastore.ds.id

  num_cpus = var.vm_cpus
  memory   = var.vm_memory_mb
  guest_id = data.vsphere_virtual_machine.template.guest_id

  scsi_type = data.vsphere_virtual_machine.template.scsi_type

  network_interface {
    network_id   = data.vsphere_network.net.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  # Recreate disks from the template so the provider always has at least
  # one disk block defined. This mirrors the template's disk configuration.
  dynamic "disk" {
    for_each = data.vsphere_virtual_machine.template.disks
    content {
      label            = disk.value.label
      unit_number      = disk.value.unit_number
      size             = disk.value.size
      thin_provisioned = lookup(disk.value, "thin_provisioned", true)
    }
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id

    # Optional customization (only works if VMware customization is supported by template)
    # customize {
    #   linux_options {
    #     host_name = "${var.vm_name_prefix}-${count.index + 1}"
    #     domain    = var.domain
    #   }
    # }
  }
}

# Ensure at least one of `resource_pool` or `cluster` was provided so we can
# determine a resource pool id. If neither was supplied, fail with a clear
# message during apply (null_resource provisioner will run and exit non-zero).
locals {
  selected_resource_pool_id = var.resource_pool != "" ? data.vsphere_resource_pool.pool[0].id : (var.cluster != "" ? data.vsphere_compute_cluster.cluster[0].resource_pool_id : null)
}

resource "null_resource" "require_pool" {
  count = local.selected_resource_pool_id == null ? 1 : 0

  provisioner "local-exec" {
    command = "echo 'error: module requires either var.cluster or var.resource_pool to be set' 1>&2; exit 1"
  }
}
