
#!/usr/bin/env bash
# If this script is sourced, avoid changing shell options (which can break prompts).
# Detect whether the script is being sourced.
sourced=0
(return 0 2>/dev/null) && sourced=1 || sourced=0
if [ "$sourced" -eq 0 ]; then
  set -euo pipefail
fi

# Helper to fail with either return (when sourced) or exit (when executed)
fail() {
  local msg="$1"; shift || true
  local code=${1:-2}
  echo "$msg" >&2
  if [ "$sourced" -eq 1 ]; then
    return "$code"
  else
    exit "$code"
  fi
}

# Helper to export TF_VAR_* variables from a 1Password item.
# It looks for fields whose labels start with: TERRAFORM_VSPHERE_
# The script should be sourced, not executed. Example:
#   export OP_ITEM="1Password"            # item name or id (default shown below)
#   export OP_VAULT="Kubernetes-Connect" # vault name (default)
#   eval $(op signin)                       # ensure a session exists
#   source ./ops_export.sh

if ! command -v op >/dev/null 2>&1; then
  fail "error: 1Password CLI 'op' not found in PATH" 2
fi
if ! command -v jq >/dev/null 2>&1; then
  fail "error: 'jq' is required but not found" 2
fi

# Defaults: vault and item as requested
: ${OP_VAULT:=Kubernetes-Connect}
: ${OP_ITEM:=terraform}

# Controls which TF_VAR namespaces are exported when sourcing this script.
# Valid values: "legacy" (export TF_VAR_<name>), "vsphere" (export TF_VAR_vsphere_<name>),
# or "both" (export both). Default: legacy (keeps env tidy for Terraform).
: ${EXPORT_TFVAR_MODE:=legacy}

# Fetch the item JSON once and reuse
item_json=$(op item get "$OP_ITEM" --vault "$OP_VAULT" --format json 2>/dev/null || true)

if [ -z "$item_json" ]; then
  fail "error: no item JSON returned for item='$OP_ITEM' vault='$OP_VAULT'" 2
fi

echo "Loading Terraform variables from 1Password item '$OP_ITEM' (vault: '$OP_VAULT')"

# Allow-list of variable names safe to print. All others will be redacted.
allowed_print=(
  server
  bucket
  endpoint
  region
  datacenter
  cluster
  resource_pool
  datastore
  network
  template_name
  domain
  vm_name_prefix
  vm_count
  vm_cpus
  vm_memory_mb
)

is_allowed() {
  local key="$1"
  for a in "${allowed_print[@]}"; do
    if [[ "$a" == "$key" ]]; then
      return 0
    fi
  done
  return 1
}


# Iterate fields and export those starting with TERRAFORM_VSPHERE_ or TERRAFORM_STATE_
# Use process substitution so the loop runs in the current shell (so exports persist when sourced)
while read -r f; do
  label=$(echo "$f" | jq -r '.label // empty')
  value=$(echo "$f" | jq -r '.value // empty')
  if [[ -z "$label" ]]; then
    continue
  fi

  if [[ $label == TERRAFORM_VSPHERE_* ]]; then
    suffix=${label#TERRAFORM_VSPHERE_}
    # normalized var name: lowercase, non-alnum -> underscore
    varname=$(echo "$suffix" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | tr -d '\r\n')
    # Prepare export names for the chosen namespace(s)
    vsphere_export="TF_VAR_vsphere_${varname}"
    legacy_export="TF_VAR_${varname}"
    mode_lc=$(printf '%s' "$EXPORT_TFVAR_MODE" | tr '[:upper:]' '[:lower:]')
    case "$mode_lc" in
      vsphere)
        export "$vsphere_export"="$value"
        if is_allowed "$varname"; then
          printf 'export %s="%s"\n' "$vsphere_export" "$value"
        else
          printf 'export %s="%s"\n' "$vsphere_export" "[redacted]"
        fi
        ;;
      both)
        export "$vsphere_export"="$value"
        export "$legacy_export"="$value"
        if is_allowed "$varname"; then
          printf 'export %s="%s"\n' "$vsphere_export" "$value"
          printf 'export %s="%s"\n' "$legacy_export" "$value"
        else
          printf 'export %s="%s"\n' "$vsphere_export" "[redacted]"
          printf 'export %s="%s"\n' "$legacy_export" "[redacted]"
        fi
        ;;
      *)
        # legacy (default)
        export "$legacy_export"="$value"
        if is_allowed "$varname"; then
          printf 'export %s="%s"\n' "$legacy_export" "$value"
        else
          printf 'export %s="%s"\n' "$legacy_export" "[redacted]"
        fi
        ;;
    esac
  fi

  if [[ $label == TERRAFORM_STATE_* ]]; then
    # TERRAFORM_STATE_* fields are intended for backend configuration (bucket, endpoint, keys)
    suffix=${label#TERRAFORM_STATE_}
    varname=$(echo "$suffix" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | tr -d '\r\n')
    exportname="TF_VAR_state_${varname}"
    export "$exportname"="$value"
    # Map common names to AWS env vars used by S3-compatible backends
    case "$varname" in
      access_key|accesskey|access_key_id)
        export AWS_ACCESS_KEY_ID="$value"
        printf 'export AWS_ACCESS_KEY_ID="%s"\n' "[redacted]"
        ;;
      secret_key|secret|secretaccesskey|secret_key)
        export AWS_SECRET_ACCESS_KEY="$value"
        printf 'export AWS_SECRET_ACCESS_KEY="%s"\n' "[redacted]"
        ;;
      bucket)
        export TF_VAR_state_bucket="$value"
        if is_allowed "bucket"; then
          printf 'export TF_VAR_state_bucket="%s"\n' "$value"
        else
          printf 'export TF_VAR_state_bucket="%s"\n' "[redacted]"
        fi
        ;;
      endpoint)
        export TF_VAR_state_endpoint="$value"
        if is_allowed "endpoint"; then
          printf 'export TF_VAR_state_endpoint="%s"\n' "$value"
        else
          printf 'export TF_VAR_state_endpoint="%s"\n' "[redacted]"
        fi
        ;;
      region)
        export TF_VAR_state_region="$value"
        if is_allowed "region"; then
          printf 'export TF_VAR_state_region="%s"\n' "$value"
        else
          printf 'export TF_VAR_state_region="%s"\n' "[redacted]"
        fi
        ;;
      *)
        printf 'export %s="%s"\n' "$exportname" "[redacted]"
        ;;
    esac
  fi
done < <(echo "$item_json" | jq -c '.fields[]')

echo "1Password fields with prefix 'TERRAFORM_VSPHERE_' exported as TF_VAR_*."
