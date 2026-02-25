# Simple VM example

This is a tiny example that uses the `modules/vsphere/vm` module to create a
single test VM. It's intended for quick validation only — do not use in
production without review.

Quick steps

1. Sign in to 1Password (or export TF_VARs manually):

   ```bash
   eval $(op signin)
   # or use the helper (if you populated the 1Password item):
   # source ../../terraform/ops_export.sh
   ```

2. From this directory run:

   ```bash
   cp terraform.tfvars.example terraform.tfvars
   # edit terraform.tfvars to fill real password and any values
   terraform init
   terraform plan
   terraform apply
   ```

Notes

- The example defaults `allow_unverified_ssl = true` for convenience in a
  home lab with self-signed certificates. Prefer importing the vCenter CA or
  set `allow_unverified_ssl = false` once a trusted CA is configured.
- Use the short inventory names (e.g. `DOMAIN`, `DATASTORE`,
  `NIC`) — the script `scripts/govc_collect.sh` prints full
  inventory paths; strip the leading path components and store the final
  component as the Terraform value.

Running with 1Password

If you'd like Terraform to read values directly from 1Password, populate the
`terraform` item in the `Kubernetes-Connect` vault with the `TERRAFORM_VSPHERE_*`
labels (see repo docs). Then sign in and source the helper before running the
example:

```bash
eval $(op signin)
# this will export TF_VAR_* variables into the current shell
source ../../terraform/ops_export.sh
terraform init
terraform plan
terraform apply
```

Or run the provided wrapper which sources the helper in a subprocess and runs
Terraform for you:

```bash
./run.sh plan    # shows plan
./run.sh apply   # apply changes
```
