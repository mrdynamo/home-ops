variable "vsphere_server" {
  type = string
}

variable "vsphere_user" {
  type = string
}

variable "vsphere_password" {
  type      = string
  sensitive = true
}

variable "datacenter" {
  type = string
}

variable "cluster" {
  type    = string
  default = ""
}

# Optional: resource pool name. If empty the cluster default pool will be used.
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
  type = string
}

variable "vm_name_prefix" {
  type    = string
  default = "vm"
}

variable "vm_count" {
  type    = number
  default = 1
}

variable "vm_cpus" {
  type    = number
  default = 2
}

variable "vm_memory_mb" {
  type    = number
  default = 2048
}
