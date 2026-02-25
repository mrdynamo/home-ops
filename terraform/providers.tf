provider "vsphere" {
  user           = var.vsphere_user
  password       = var.vsphere_password
  vsphere_server = var.vsphere_server

  # Optional: set to true if your vCenter uses a self-signed cert.
  allow_unverified_ssl = var.allow_unverified_ssl

  # If you prefer env vars, omit these variables and set
  # TF_VAR_vsphere_user/TF_VAR_vsphere_password or use provider-specific envs.
}
