output "vm_ids" {
  description = "IDs of created VMs"
  value       = module.vsphere_vms.vm_ids
}

output "vm_names" {
  description = "Names of created VMs"
  value       = module.vsphere_vms.vm_names
}
