variable "vsphere_server" {
  description = "vSphere server (vCenter) hostname or IP"
  type        = string
}

variable "vsphere_user" {
  description = "vSphere user"
  type        = string
  sensitive   = true
}

variable "vsphere_password" {
  description = "vSphere password"
  type        = string
  sensitive   = true
}

variable "allow_unverified_ssl" {
  description = "Allow unverified SSL for vSphere provider (use only for self-signed certs)"
  type        = bool
  default     = false
}

variable "datacenter" {
  type = string
}

variable "cluster" {
  type = string
}

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
  default = "local"
}
