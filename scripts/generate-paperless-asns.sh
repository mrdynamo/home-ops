#!/usr/bin/env bash
set -euo pipefail

# Runs GenerateASNs.py in an isolated, temporary virtualenv so it doesn't
# modify or rely on the repo's or system's persistent python environments.

RES_DIR="kubernetes/apps/default/paperless/app/resources"
SCRIPT="$RES_DIR/GenerateASNs.py"

if [ ! -f "$SCRIPT" ]; then
  echo "Script not found: $SCRIPT" >&2
  exit 1
fi

TMPDIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

PYTHON_BIN=$(command -v python3 || command -v python) || {
  echo "python3 or python not found in PATH" >&2
  exit 1
}

"$PYTHON_BIN" -m venv "$TMPDIR/venv"
# shellcheck source=/dev/null
. "$TMPDIR/venv/bin/activate"

pip install --upgrade pip setuptools wheel

# Install ReportLab pinned to a known working version
pip install "reportlab==4.4.9"

# Try to install reportlab_qrcode if the script needs it (safe to skip if not available)
if ! python -c "import reportlab_qrcode" >/dev/null 2>&1; then
  pip install reportlab_qrcode 2>/dev/null || pip install reportlab-qrcode 2>/dev/null || true
fi

# Ensure the resources directory is on PYTHONPATH so `import AveryLabels` works
export PYTHONPATH="$RES_DIR"

# If a first arg is provided, accept either a range id (1-2 digits) or a start number
if [ "$#" -ge 1 ]; then
  FIRST="$1"
  if [[ "$FIRST" =~ ^[0-9]{1,2}$ ]]; then
    # treat as range id
    RANGE="$FIRST"
    shift || true
    python "$SCRIPT" --range "$RANGE" "$@"
    exit $?
  elif [[ "$FIRST" =~ ^[0-9]+$ ]]; then
    # treat as explicit start number
    START="$FIRST"
    shift || true
    python "$SCRIPT" "$START" "$@"
    exit $?
  else
    # forward flags/other args as-is
    python "$SCRIPT" "$@"
    exit $?
  fi
else
  python "$SCRIPT" "$@"
fi

# venv will be removed by the trap on exit
