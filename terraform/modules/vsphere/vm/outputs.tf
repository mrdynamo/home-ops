output "vm_ids" {
  value = [for v in vsphere_virtual_machine.vm : v.id]
}

output "vm_names" {
  value = [for v in vsphere_virtual_machine.vm : v.name]
}
