#!/usr/bin/env bash
# Detect if script is being sourced; if so avoid changing parent shell options.
sourced=0
(return 0 2>/dev/null) && sourced=1 || sourced=0
if [ "$sourced" -eq 0 ]; then
  set -euo pipefail
fi

# Helper to fail with return when sourced, or exit when executed
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

# govc_collect.sh
# Collect canonical vSphere names using govc, pulling connection info from 1Password.
# Usage:
#   eval $(op signin)
#   OP_VAULT=Kubernetes-Connect OP_ITEM=terraform ./scripts/govc_collect.sh

# Default 1Password vault and item (can be overridden by env)
OP_VAULT="${OP_VAULT:-Kubernetes-Connect}"
OP_ITEM="${OP_ITEM:-terraform}"

echo "DEBUG: PATH=$PATH"
echo "DEBUG: shell=$(ps -p $$ -o comm=)"

if ! command -v op >/dev/null 2>&1; then
  echo "DEBUG: 'op' not found initially; sourcing common rc files to pick up PATH" >&2
  for rc in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -r "$rc" ]; then
      echo "DEBUG: sourcing $rc" >&2
      # shellcheck disable=SC1090
      . "$rc" 2>/dev/null || true
    fi
  done
  echo "DEBUG: PATH after sourcing rc files: $PATH" >&2
  if ! command -v op >/dev/null 2>&1; then
    fail "error: 1Password CLI 'op' not found" 2
  fi
fi
OP_BIN=""
# Allow caller to override path to 1Password CLI binary
if [ -n "${OP_BIN:-}" ]; then
  : # respect caller-provided OP_BIN
else
  if command -v op >/dev/null 2>&1; then
    OP_BIN=$(command -v op)
  elif command -v op.exe >/dev/null 2>&1; then
    OP_BIN=$(command -v op.exe)
  fi
fi
# Ensure OP_BIN is an executable path; command -v in some shells returns alias text
if [ -n "$OP_BIN" ]; then
  if ! [ -x "$OP_BIN" ] && ! command -v "$OP_BIN" >/dev/null 2>&1; then
    # not an executable path (likely alias text) — clear to force interactive-shell fallback
    OP_BIN=""
  fi
fi
echo "DEBUG: op -> ${OP_BIN:-not-found}" >&2
if [ -n "$OP_BIN" ]; then
  echo "DEBUG: $($OP_BIN --version 2>/dev/null || true)" >&2
fi
if ! command -v jq >/dev/null 2>&1; then
  fail "error: 'jq' is required" 2
fi
if ! command -v govc >/dev/null 2>&1; then
  fail "error: 'govc' is required (install from https://github.com/vmware/govmomi)" 2
fi

: ${OP_VAULT:=Kubernetes-Connect}
: ${OP_ITEM:=terraform}

# Accept alternate env var name `GOV_INSECURE` (common typo/shortcut) and
# prefer an explicit GOVC_INSECURE value if provided. This script must not
# source `terraform/ops_export.sh` because it is used to populate values into
# 1Password that `ops_export.sh` later reads.
if [ -z "${GOVC_INSECURE:-}" ] && [ -n "${GOV_INSECURE:-}" ]; then
  GOVC_INSECURE="$GOV_INSECURE"
fi

echo "Fetching 1Password item '$OP_ITEM' from vault '$OP_VAULT'..."
op_err=""
item_json=""
# Parse command-line flags (supports --insecure / -i)
while [ "${1:-}" != "" ]; do
  case "$1" in
    -i|--insecure)
      GOVC_INSECURE=1
      shift || true
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: govc_collect.sh [--insecure|-i]

Options:
  -i, --insecure   Skip TLS verification by setting GOVC_INSECURE=1
  -h, --help       Show this help message
USAGE
      if [ "$sourced" -eq 1 ]; then
        return 0
      else
        exit 0
      fi
      ;;
    *)
      break
      ;;
  esac
done
if [ -n "$OP_BIN" ]; then
  item_json=$($OP_BIN item get "$OP_ITEM" --vault "$OP_VAULT" --format json 2>/dev/null || true)
else
  # Try running the user's interactive shells to pick up aliases (e.g., op=op.exe set in zsh)
  tried_shells=()
  # Prefer $SHELL, but try common shells if that fails
  shells_to_try=("${SHELL:-}" "/usr/bin/zsh" "/bin/zsh" "/usr/bin/bash" "/bin/bash")
  for sh in "${shells_to_try[@]}"; do
    [ -x "$sh" ] || continue
    # avoid duplicates
    for t in "${tried_shells[@]}"; do
      [ "$t" = "$sh" ] && sh="" && break
    done
    [ -n "$sh" ] || continue
    tried_shells+=("$sh")
    echo "DEBUG: trying interactive shell: $sh" >&2
    item_json=$($sh -ic "op item get '$OP_ITEM' --vault '$OP_VAULT' --format json" 2>/dev/null || true)
    if [ -n "$item_json" ]; then
      echo "DEBUG: obtained item_json from $sh" >&2
      break
    fi
  done
fi
  if [ -z "$item_json" ]; then
    # If there are no exported OP_SESSION_* variables in this process, it's
    # likely you signed in interactively in another shell without exporting the
    # session. Sourcing the script works because it runs inside your current
    # shell and can see unexported variables and aliases. When executing the
    # script directly it runs in a new process and will not see those.
    if ! env | grep -q '^OP_SESSION_' 2>/dev/null; then
      cat >&2 <<'MSG'
Notice: no exported 1Password session found in this shell.
If you signed in with `eval $(op signin)` in your interactive shell, that
session exists only in that shell unless exported. To run the script
directly (not via `source`), sign in in the same shell and export the
session, for example:

  eval $(op signin)

Alternatively you can run the script by sourcing it so it reuses your
existing interactive session:

  source ./scripts/govc_collect.sh --insecure

MSG
    fi
    echo "error: could not retrieve 1Password item. Ensure you ran: eval \$(op signin)" >&2
    echo "DEBUG: op error output:" >&2
    # Try a direct op command to surface potential signin errors
    if [ -n "$OP_BIN" ]; then
      $OP_BIN whoami 2>&1 || true
    else
      op whoami 2>&1 || true
    fi
    fail "failed to fetch 1Password item" 2
  fi

get_field() {
  local label="$1"
  echo "$item_json" | jq -r --arg label "$label" '.fields[] | select(.label==$label) | .value // empty'
}

VS_SERVER=${TF_VAR_vsphere_server:-$(get_field "TERRAFORM_VSPHERE_SERVER")}
# Accept both USER and USERNAME labels (some items may use USERNAME)
VS_USER=${TF_VAR_vsphere_user:-$(get_field "TERRAFORM_VSPHERE_USER")}
if [ -z "$VS_USER" ]; then
  VS_USER=${TF_VAR_vsphere_username:-$(get_field "TERRAFORM_VSPHERE_USERNAME")}
fi
VS_PASS=${TF_VAR_vsphere_password:-$(get_field "TERRAFORM_VSPHERE_PASSWORD")}
VS_DATACENTER=$(get_field "TERRAFORM_VSPHERE_DATACENTER")
VS_CLUSTER=$(get_field "TERRAFORM_VSPHERE_CLUSTER")
VS_RESOURCE_POOL=$(get_field "TERRAFORM_VSPHERE_RESOURCE_POOL")
VS_DATASTORE=$(get_field "TERRAFORM_VSPHERE_DATASTORE")
VS_NETWORK=$(get_field "TERRAFORM_VSPHERE_NETWORK")
VS_TEMPLATE=$(get_field "TERRAFORM_VSPHERE_TEMPLATE_NAME")
VS_DOMAIN=$(get_field "TERRAFORM_VSPHERE_DOMAIN")
VS_ALLOW_UNVERIFIED=$(get_field "TERRAFORM_VSPHERE_ALLOW_UNVERIFIED")

if [ -z "$VS_SERVER" ] || [ -z "$VS_USER" ] || [ -z "$VS_PASS" ]; then
  fail "error: missing connection info (server/user/password) in 1Password item" 2
fi

export GOVC_URL="$VS_SERVER"
export GOVC_USERNAME="$VS_USER"
export GOVC_PASSWORD="$VS_PASS"
if [[ "$VS_ALLOW_UNVERIFIED" =~ ^([Tt]rue|1)$ ]]; then
  export GOVC_INSECURE=true
else
  export GOVC_INSECURE=${GOVC_INSECURE:-false}
fi

echo
echo "Connection: $GOVC_URL (user: $GOVC_USERNAME)"
echo "Password: [redacted]"
echo

echo "Checking govc connectivity..."
if ! govc about >/dev/null 2>&1; then
  echo "warning: govc couldn't connect — check GOVC_URL/GOVC_USERNAME/GOVC_PASSWORD and network" >&2
fi

echo
echo "Available datacenters:"
govc find / -type d || true

echo
echo "Available clusters:"
govc find / -type c || true

echo
echo "Available datastores:"
govc find / -type s || true

echo
echo "Available networks (portgroups):"
govc find / -type n || true

echo
echo "Available resource pools:"
govc find / -type r || true

# Suggest a reasonable resource-pool name for the 1Password field if none set.
# When govc returns host entries (paths containing '/host/'), the typical
# resource-pool name to use is 'Resources' (the implicit pool on ESXi hosts).
rp_first=$(govc find / -type r | head -n1 || true)
if [ -n "$rp_first" ]; then
  if echo "$rp_first" | grep -q '/host/'; then
    # govc returned host paths — suggest the host-level Resources pool path
    suggested_resource_pool="${rp_first%/}/Resources"
  else
    suggested_resource_pool=$(basename "$rp_first")
  fi
else
  suggested_resource_pool=""
fi

echo
echo "Templates / VMs (searching for templates):"
govc find / -type m | grep -i template || true

# Capture first template path (if any) so we can suggest a sensible template name
tmpl_first=$(govc find / -type m | grep -i template | head -n1 || true)
if [ -n "$tmpl_first" ]; then
  suggested_template=$(basename "$tmpl_first")
  if [[ "$suggested_template" =~ ^(VM[[:space:]]Templates|Templates|)$ ]]; then
    suggested_template=""
  fi
else
  suggested_template=""
fi

if [ -n "$VS_TEMPLATE" ]; then
  echo
  echo "Searching for template named: $VS_TEMPLATE"
  tmpl_path=$(govc find / -type m | grep -F "$VS_TEMPLATE" | head -n1 || true)
  if [ -n "$tmpl_path" ]; then
    echo "Found: $tmpl_path"
    echo "Template details (guestId, SCSI type, NIC types):"
    govc vm.info -json "$tmpl_path" | jq '.VirtualMachines[0].Config | {guestId: .guestId, scsiType: .scsiType, hardware: .Hardware}'
  else
    echo "Template '$VS_TEMPLATE' not found by govc find. You may need to inspect VM folder paths or copy full path from the UI."
  fi
fi

echo
echo "Summary (copy these exact values into 1Password if desired):"
printf 'TERRAFORM_VSPHERE_SERVER=%s\n' "$VS_SERVER"
printf 'TERRAFORM_VSPHERE_USER=%s\n' "$VS_USER"
printf 'TERRAFORM_VSPHERE_PASSWORD=[redacted]\n'
printf 'TERRAFORM_VSPHERE_DATACENTER=%s\n' "$VS_DATACENTER"
printf 'TERRAFORM_VSPHERE_CLUSTER=%s\n' "$VS_CLUSTER"
if [ -n "$VS_RESOURCE_POOL" ]; then
  printf 'TERRAFORM_VSPHERE_RESOURCE_POOL=%s\n' "$VS_RESOURCE_POOL"
else
  printf 'TERRAFORM_VSPHERE_RESOURCE_POOL=%s\n' "$suggested_resource_pool"
fi
printf 'TERRAFORM_VSPHERE_DATASTORE=%s\n' "$VS_DATASTORE"
printf 'TERRAFORM_VSPHERE_NETWORK=%s\n' "$VS_NETWORK"
printf 'TERRAFORM_VSPHERE_TEMPLATE_NAME=%s\n' "$VS_TEMPLATE"
if [ -z "$VS_TEMPLATE" ] && [ -n "$suggested_template" ]; then
  echo "# Suggested template name (copy into 1Password): $suggested_template"
fi
printf 'TERRAFORM_VSPHERE_DOMAIN=%s\n' "$VS_DOMAIN"

echo
echo "Done."
