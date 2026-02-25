#!/usr/bin/env bash
set -euo pipefail

# sops_state.sh
# Workflow helper to use an encrypted terraform state file in the repo with sops.
# This script decrypts the committed encrypted state into a temporary file,
# runs terraform commands against it, then re-encrypts and cleans up.
#
# Usage (interactive):
#   cd terraform
#   export SOPS_STATE_FILE=state.sops.json       # file tracked in git (encrypted)
#   export TF_STATE_PATH=terraform.tfstate       # temporary decrypted path
#   source ./sops_state.sh plan                   # or apply/destroy

SOPS_FILE=${SOPS_STATE_FILE:-state.sops.json}
DECRYPTED=${TF_STATE_PATH:-terraform.tfstate}

if ! command -v sops >/dev/null 2>&1; then
  echo "error: sops binary not found" >&2
  return 2
fi

if [ ! -f "$SOPS_FILE" ]; then
  echo "No encrypted state file found at $SOPS_FILE; creating empty encrypted template"
  # create empty state securely
  old_umask=$(umask)
  umask 077
  printf '{}' > "$DECRYPTED"
  chmod 600 "$DECRYPTED" || true
  sops -e --output-type json "$DECRYPTED" > "$SOPS_FILE"
  # remove plaintext state
  shred -u "$DECRYPTED" || rm -f "$DECRYPTED"
  umask "$old_umask"
fi

cleanup() {
  # ensure decrypted file is removed
  if [ -f "$DECRYPTED" ]; then
    shred -u "$DECRYPTED" || rm -f "$DECRYPTED"
  fi
}
trap cleanup EXIT

action=${1:-plan}

echo "Decrypting $SOPS_FILE -> $DECRYPTED"
old_umask=$(umask)
umask 077
sops -d --output-type json "$SOPS_FILE" > "$DECRYPTED"
chmod 600 "$DECRYPTED" || true
umask "$old_umask"

case "$action" in
  plan)
    terraform init
    terraform plan -state="$DECRYPTED" "${@:2}"
    ;;
  apply)
    terraform init
    terraform apply -state="$DECRYPTED" "${@:2}"
    ;;
  destroy)
    terraform init
    terraform destroy -state="$DECRYPTED" "${@:2}"
    ;;
  *)
    echo "Usage: source ./sops_state.sh [plan|apply|destroy] [terraform args]" >&2
    return 2
    ;;
esac

echo "Re-encrypting state -> $SOPS_FILE"
sops -e "$DECRYPTED" > "$SOPS_FILE".tmp
mv "$SOPS_FILE" "$SOPS_FILE".bak || true
mv "$SOPS_FILE".tmp "$SOPS_FILE"
git add "$SOPS_FILE"
echo "Encrypted state updated and staged. Commit when ready."
