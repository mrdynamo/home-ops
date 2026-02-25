Terraform for vSphere — repository scaffold and notes

Overview
- This folder contains a minimal, production-minded Terraform scaffold to manage vSphere resources used to bootstrap your GitOps cluster VMs.
- It uses a reusable module for creating/cloning VMs and an environment-level var file pattern.

Key files
- `versions.tf`: Terraform and provider version pins.
- `providers.tf`: vSphere provider configuration (uses variables/ENV overrides).
- `backend.tf` (examples): commented backend examples for Terraform Cloud, S3, or local.
- `main.tf`: example root module invocation.
- `modules/vsphere/vm/`: VM module to clone templates and configure VMs.
- `environments/bootstrap/terraform.tfvars`: example values for a bootstrap environment.

Quickstart
1. Choose a remote backend (Terraform Cloud, S3 + Dynamo/Minio, or other). Edit `backend.tf` accordingly.
2. Place secrets securely (recommended: Vault, SOPS, or Terraform Cloud variables). Avoid committing credentials.
3. Initialize Terraform:

```bash
cd terraform
terraform init
terraform workspace new bootstrap || terraform workspace select bootstrap
terraform plan -var-file=environments/bootstrap/terraform.tfvars
terraform apply -var-file=environments/bootstrap/terraform.tfvars
```

Best practices and recommendations
- Use a remote state backend (Terraform Cloud or an S3-compatible bucket) and enable state locking.
- Keep credentials out of VCS: use environment variables, Vault, or SOPS-encrypted tfvars.
- Create one environment folder per lifecycle (e.g., `environments/bootstrap`, `environments/prod`).
- Use modules for repeatable resources (we provide `modules/vsphere/vm`).
- Pin provider and Terraform versions to avoid surprises.
- Use Terraform workspaces or separate backends per environment — do not share state between unrelated environments.

Local state concerns
--------------------

- Committing local Terraform state (`*.tfstate`) into this GitOps repo is strongly discouraged. Terraform state can contain sensitive data (provider credentials, cloud instance metadata, IPs, generated passwords, certificates, and any resource attributes marked `sensitive`), so storing it in plaintext in a VCS exposes those values to anyone with repo access.
- Even if you redact tfvars or avoid putting secrets in input variables, resource attributes returned by providers often include things you'd rather not keep in git.

If you must keep state in a file for quick experiments, ensure:

- The file is excluded from commits (we already ignore `*.tfvars` and `.terraform/`), and do not commit `terraform.tfstate`.
- Use an encrypted store (SOPS) if you really need to keep a snapshot in the repo — but avoid this for regular state.

Recommended remote backends and tradeoffs
----------------------------------------

- Terraform Cloud (or a commercial Terraform state solution): provides secure storage, state locking, history, team access controls, and minimal operational burden. Recommended for teams or where locking is required.
- S3-compatible backends (Cloudflare R2, Backblaze B2, AWS S3): inexpensive object storage for state. Pros: low cost and simple. Cons: many S3-compatible providers do NOT supply state locking (DynamoDB). Without locking you risk state corruption from concurrent runs. To mitigate:
 	- Use Terraform Cloud for locking only, or
 	- Run Terraform from a single coordination point (CI/CD) and avoid concurrent human runs, or
 	- Use a locking service like Consul or a simple coordination semaphore in CI.

Cloudflare R2 vs Backblaze B2 (summary)
--------------------------------------

- Expected costs: for Terraform state the absolute storage and request volume is tiny (the state file is typically tens to hundreds of KB). Storage and request costs for either provider will therefore be negligible — often fractions of a cent per month. The main cost consideration is egress if you transfer large volumes of data from the bucket.
- Feature differences:
 	- Locking: neither R2 nor B2 provides DynamoDB-style Terraform state locking; AWS S3 + DynamoDB remains the common pattern for automatic locking.
 	- Pricing: Backblaze B2 is generally very low-cost for storage. Cloudflare R2 focuses on low egress-costs within the Cloudflare network. Pricing changes frequently; check the providers' pricing pages for up-to-date numbers.

Practical recommendation
------------------------

- For a single-admin home lab where concurrent runs are rare: Cloudflare R2 or Backblaze B2 is fine. Use CI to perform Terraform apply if you want structured runs.
- For teams or automation with multiple runners: use Terraform Cloud (free tier available) or AWS S3 + DynamoDB for locking.

Using SOPS to store state in VCS (home-lab, single admin)
------------------------------------------------------

You can store encrypted Terraform state in the repo using `sops`, but you must be aware of the tradeoffs and follow a safe workflow.

Why this is risky if done carelessly:

- Terraform writes state as plaintext to disk when running. If you decrypt state directly into the repo file, you risk leaving secrets in plaintext if a command fails or you forget to re-encrypt.

Recommended safe workflow (provided helper)

1. Keep an encrypted state file in the repo (example: `state.sops.json` in the `terraform` folder). Do NOT store an unencrypted `terraform.tfstate` in the repo.
2. Use the helper `sops_state.sh` (added in this repo) which:
 - Decrypts the committed encrypted state into a temporary `terraform.tfstate` file.
 - Runs `terraform init` and `terraform plan|apply|destroy` using `-state=terraform.tfstate` to ensure Terraform uses the decrypted file.
 - Re-encrypts the state and stages the encrypted file with `git add` so you can commit the encrypted state back to the repo.
3. The helper deletes the decrypted file on exit. Always inspect and trust scripts before running.

How to use the helper (interactive)

```bash
cd terraform
export SOPS_STATE_FILE=state.sops.json   # tracked encrypted file in repo
export TF_STATE_PATH=terraform.tfstate   # temporary plaintext state path
eval $(op signin)
export OP_VAULT=Kubernetes-Connect
export OP_ITEM=terraform
source ./ops_export.sh                    # inject TF_VARs and backend creds
source ./sops_state.sh plan               # runs terraform plan using decrypted state
# After apply, commit the updated encrypted state:
git commit -m "Update encrypted terraform state" state.sops.json
```

Notes and caveats

- The helper stages the updated encrypted state but does not auto-commit — review before committing.
- Use `sops` with a key you control (age or GPG key) and ensure the private key is not on other machines you do not trust.
- This approach is acceptable for a single-admin home lab. For teams or CI with multiple runners, prefer a remote backend with locking.
- Ensure your `.sops.yaml` (or equivalent SOPS config) is configured to use the key type you prefer (we didn't add one automatically).

Integration with 1Password for backend credentials
--------------------------------------------------

Continue using the `terraform` item in `Kubernetes-Connect` to store backend credentials (bucket, access key, secret, endpoint). The `ops_export.sh` script now exports `TERRAFORM_STATE_<NAME>` fields as both `TF_VAR_state_<name>` and sets `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` when appropriate, so S3-compatible backends will pick them up.

Backend examples for R2/B2
-------------------------

See `backend.tf` for concrete S3-compatible backend examples for Cloudflare R2 and Backblaze B2. Important:

- Set credentials via environment variables (e.g., `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`) or in your CI secrets manager.
- Remember that without a separate locking mechanism concurrent runs may corrupt state.

Notes

- The module and root configs provided here are a starting point — adjust to match your vSphere inventory (clusters, resource pools, datastores, and networks).
- If you use SOPS in this repo, store sensitive tfvars encrypted with SOPS.

Support

- After trying the scaffold, tell me which vSphere objects you have (datacenter, cluster name, resource pool, datastore, template name, network name) and I can tailor the module to your environment.

- Using 1Password CLI for secrets

--------------------------------

Recommended: keep secrets out of the repo and load them at runtime with the 1Password CLI (`op`). Below are two safe approaches.

1) Quick export (recommended for interactive use)

- Store a single 1Password item in the `Kubernetes-Connect` vault with the name `terraform` (or set `OP_VAULT` and `OP_ITEM` to your preferred values).
- The item should contain fields named using the pattern `TERRAFORM_VSPHERE_<FUNCTION>` (see the field list below).
- Run the helper script to export `TF_VAR_*` environment variables used by Terraform. Example:

```bash
cd terraform
eval $(op signin)                      # sign in to 1Password
export OP_VAULT=Kubernetes-Connect
export OP_ITEM=terraform
source ./ops_export.sh
terraform init
terraform plan -var-file=environments/bootstrap/terraform.tfvars
```

1) CI / non-interactive

- For CI, use the 1Password CLI in your runner to fetch secrets and set environment variables for the Terraform run. Do NOT commit plaintext secrets.

Security notes

- Avoid committing `*.tfvars` containing plaintext secrets. The repo `.gitignore` already excludes `*.tfvars`.
- The helper script uses the `op` CLI and `jq` to parse values; ensure your environment provides a valid 1Password session (e.g., `eval $(op signin)`).
- If you prefer, use the official 1Password Terraform provider for secret retrieval, but be aware that provider-based secret retrieval may still end up in state or logs if outputs are captured — environment variables are generally simpler and safer for provider credentials.

Required 1Password fields
-------------------------

Create a single 1Password item (vault: `Kubernetes-Connect`, item name: `terraform`) and add fields using these exact labels. The helper script maps each `TERRAFORM_VSPHERE_<SUFFIX>` field to `TF_VAR_<suffix_lowercase>`.

- TERRAFORM_VSPHERE_SERVER           -> `TF_VAR_vsphere_server`
- TERRAFORM_VSPHERE_USER             -> `TF_VAR_vsphere_user`
- TERRAFORM_VSPHERE_PASSWORD         -> `TF_VAR_vsphere_password`
- TERRAFORM_VSPHERE_DATACENTER       -> `TF_VAR_datacenter`
- TERRAFORM_VSPHERE_CLUSTER          -> `TF_VAR_cluster`
- TERRAFORM_VSPHERE_RESOURCE_POOL    -> `TF_VAR_resource_pool`
- TERRAFORM_VSPHERE_DATASTORE        -> `TF_VAR_datastore`
- TERRAFORM_VSPHERE_NETWORK          -> `TF_VAR_network`
- TERRAFORM_VSPHERE_TEMPLATE_NAME    -> `TF_VAR_template_name`
- TERRAFORM_VSPHERE_DOMAIN           -> `TF_VAR_domain`

Optional VM tuning fields (also supported):

- TERRAFORM_VSPHERE_VM_NAME_PREFIX   -> `TF_VAR_vm_name_prefix`
- TERRAFORM_VSPHERE_VM_COUNT         -> `TF_VAR_vm_count`
- TERRAFORM_VSPHERE_VM_CPUS          -> `TF_VAR_vm_cpus`
- TERRAFORM_VSPHERE_VM_MEMORY_MB     -> `TF_VAR_vm_memory_mb`

You can add other `TERRAFORM_VSPHERE_*` fields and they will be exported as `TF_VAR_*` automatically.

- Example minimal item:

- Vault: `Kubernetes-Connect`
- Item name: `terraform`
- Fields:
  - Label: `TERRAFORM_VSPHERE_SERVER`      Value: `vcenter.example.local`
  - Label: `TERRAFORM_VSPHERE_USER`        Value: `terraform-user`
  - Label: `TERRAFORM_VSPHERE_PASSWORD`    Value: `supersecret`

Collecting vSphere values (how to find names)
---------------------------------------------

Below are quick, repeatable ways to collect the vSphere names/values you need to populate your `terraform` 1Password item.

vCenter Web UI (quick)

- Datacenter: Inventory → Datacenters — copy the datacenter name exactly.
- Cluster: Hosts and Clusters → expand datacenter → cluster name.
- Datastore: Storage → Datastores — copy the datastore name.
- Network/Portgroup: Networking → Port Groups (or view a VM's network) — copy the Port Group name.
- Template name: VMs and Templates → find the VM template and copy its name.
- Resource pool: Hosts and Clusters → cluster → Resource Pools (optional; leave blank to use cluster default).

govc (CLI, recommended for scripting)

1. Set connection env vars:

```bash
export GOVC_URL='vcenter.example.local'
export GOVC_USERNAME='your-user'
export GOVC_PASSWORD='your-password'
export GOVC_INSECURE=true    # if you use self-signed certs
```

2. Useful commands:

```bash
govc find / -type d        # datacenters
govc find / -type c        # clusters
govc find / -type s        # datastores
govc find / -type n        # networks/portgroups
govc find / -type r        # resource pools
govc find / -type m | grep -i template   # templates (virtual machines)
# inspect a template
govc vm.info -json '/Datacenter/vm/your-template' | jq .
```

PowerCLI (PowerShell)

- Connect: `Connect-VIServer -Server vcenter.example.local -User user -Password pass`
- Commands: `Get-Datacenter`, `Get-Cluster`, `Get-ResourcePool`, `Get-Datastore`, `Get-Template`, `Get-VirtualPortGroup`.

What to verify before adding to 1Password

- Use exact names (no extra spaces). Data sources in the Terraform module match by name and datacenter.
- Confirm template supports your chosen customization method (cloud-init or VMware customization) and has VMware tools if needed.
- For networks, confirm the portgroup is available on the hosts where the VM will be placed.

Mapping to 1Password fields (exact labels)

- TERRAFORM_VSPHERE_SERVER        -> vCenter hostname/IP
- TERRAFORM_VSPHERE_USER          -> API user
- TERRAFORM_VSPHERE_PASSWORD      -> API password
- TERRAFORM_VSPHERE_DATACENTER    -> Datacenter name (exact)
- TERRAFORM_VSPHERE_CLUSTER       -> Cluster name (exact)
- TERRAFORM_VSPHERE_RESOURCE_POOL -> Resource pool name/path (optional; leave empty to use cluster default)
- TERRAFORM_VSPHERE_DATASTORE     -> Datastore name (exact)
- TERRAFORM_VSPHERE_NETWORK       -> Portgroup name (exact)
- TERRAFORM_VSPHERE_TEMPLATE_NAME -> Template name (exact)
- TERRAFORM_VSPHERE_DOMAIN        -> Guest DNS domain to apply (e.g., example.local)

Add state/backend fields (for S3-compatible backends or R2/B2):

 - Label: `TERRAFORM_STATE_BUCKET`        Value: `your-bucket-name`
 - Label: `TERRAFORM_STATE_ACCESS_KEY`    Value: `<access key id>`
 - Label: `TERRAFORM_STATE_SECRET_KEY`    Value: `<secret access key>`
 - Label: `TERRAFORM_STATE_ENDPOINT`      Value: `https://...` (optional for S3-compatible)
 - Label: `TERRAFORM_STATE_REGION`        Value: `region-name` (optional)
