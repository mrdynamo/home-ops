#!/usr/bin/env bash
# Relaxed strict mode to diagnose errors
set -u
set -o pipefail

# Wrapper to source TF_VARs from 1Password helper and run terraform in this
# example directory. Usage: ./run.sh [plan|apply]

cd "$(dirname "$0")"

echo "DEBUG: running from $(pwd)"
echo "DEBUG: SHELL=${SHELL:-unknown}"

# ops_export.sh lives at ../.. (terraform/ops_export.sh) relative to this
# example dir — source the helper directly.
if [ ! -f "../../ops_export.sh" ]; then
  echo "error: ../../ops_export.sh not found" >&2
  exit 2
fi

echo "DEBUG: ../../ops_export.sh found" >&2

# Attempt to obtain TF_VAR_* exports from ops_export.sh.
# Prefer sourcing it directly if `op` is available in PATH; otherwise try
# running it inside interactive shells and capture its printed `export` lines
# and eval them into this process.
if command -v op >/dev/null 2>&1; then
  echo "DEBUG: op found in PATH -> sourcing ../../ops_export.sh" >&2
  # shellcheck disable=SC1090
  . ../../ops_export.sh || {
    echo "error: failed to source ../../ops_export.sh" >&2
    exit 2
  }
else
  echo "DEBUG: op NOT in PATH; trying rc files and interactive shells" >&2
  # Try sourcing common rc files to pick up PATH modifications
  for rc in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -r "$rc" ] || continue
    echo "DEBUG: sourcing $rc" >&2
    # shellcheck disable=SC1090
    . "$rc" 2>/dev/null || true
  done

  if command -v op >/dev/null 2>&1; then
    echo "DEBUG: op found after rc sourcing -> sourcing ../../ops_export.sh" >&2
    # shellcheck disable=SC1090
    . ../../ops_export.sh || {
      echo "error: failed to source ../../ops_export.sh after rc files" >&2
      exit 2
    }
  else
    echo "DEBUG: op still not found; trying interactive shells" >&2
    # Try executing ops_export.sh inside interactive shells and capture export lines
    shells=("${SHELL:-}" "/usr/bin/zsh" "/bin/zsh" "/usr/bin/bash" "/bin/bash")
    exports=""
    for sh in "${shells[@]}"; do
      [ -x "$sh" ] || continue
      echo "DEBUG: trying interactive shell: $sh" >&2
      out=$($sh -ic ". ../../ops_export.sh" 2>/dev/null || true)
      # extract lines that start with 'export '
      exports=$(printf '%s\n' "$out" | sed -n -e "s/^export //p" || true)
      if [ -n "$exports" ]; then
        echo "DEBUG: obtained exports from $sh" >&2
        # eval each export line to set variables in this shell
        set +e
        while IFS= read -r line; do
          eval "export $line"
        done <<EOF
$exports
EOF
        set -e
        break
      fi
    done
    if [ -z "$exports" ]; then
      echo "error: 1Password CLI 'op' not found in PATH; sign in with 'eval \$(op signin)' or ensure 'op' is available" >&2
      exit 2
    fi
  fi
fi

# Debug: show which TF_VAR_* are set (redacted)
echo "DEBUG: checking TF_VAR_* variables:" >&2
for v in vsphere_server vsphere_user vsphere_password datacenter cluster resource_pool datastore network template_name vm_name_prefix vm_cpus vm_memory_mb; do
  tv="TF_VAR_${v}"
  if [ -n "${!tv:-}" ]; then
    echo "DEBUG:   $tv is set (length=${#${!tv}})" >&2
  else
    echo "DEBUG:   $tv is NOT set" >&2
  fi
done

if ! command -v terraform >/dev/null 2>&1; then
  echo "error: terraform not found in PATH" >&2
  exit 2
fi

echo "DEBUG: terraform found; running init..." >&2

set -e
terraform init -input=false

cmd=${1:-plan}
case "$cmd" in
  apply)
    terraform apply -auto-approve
    ;;
  plan)
    terraform plan
    ;;
  *)
    echo "usage: $0 [plan|apply]" >&2
    exit 2
    ;;
esac
