variable "vsphere_server" {
  description = "vCenter server hostname or IP"
  type        = string
}

variable "vsphere_user" {
  description = "vCenter user"
  type        = string
}

variable "vsphere_password" {
  description = "vCenter password"
  type        = string
  sensitive   = true
}

variable "allow_unverified_ssl" {
  description = "Allow unverified SSL for vSphere provider (self-signed certs)"
  type        = bool
  default     = true
}

variable "datacenter" { type = string }
variable "cluster"    { type = string }
variable "resource_pool" {
  type    = string
  default = ""
}

variable "datastore" {
  type = string
}

variable "network" {
  type = string
}

variable "template_name" {
  type = string
}

variable "domain" {
  type    = string
  default = "vsphere.local"
}

variable "vm_name_prefix" {
  type    = string
  default = "test-vm"
}

variable "vm_cpus" {
  type    = number
  default = 1
}

variable "vm_memory_mb" {
  type    = number
  default = 1024
}
