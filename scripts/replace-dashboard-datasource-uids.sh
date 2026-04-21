#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <dashboard.json> [more-dashboard.json ...]" >&2
  exit 1
fi

python3 - "$@" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path


TARGET_UID = "${DS_PROMETHEUS}"


def rewrite_datasources(node: object) -> int:
    replacements = 0

    if isinstance(node, dict):
        datasource = node.get("datasource")
        if isinstance(datasource, dict):
            if datasource.get("type") == "prometheus" and datasource.get("uid") != TARGET_UID:
                datasource["uid"] = TARGET_UID
                replacements += 1

        for value in node.values():
            replacements += rewrite_datasources(value)
    elif isinstance(node, list):
        for item in node:
            replacements += rewrite_datasources(item)

    return replacements


def main(paths: list[str]) -> int:
    exit_code = 0

    for raw_path in paths:
        path = Path(raw_path)

        try:
            original = path.read_text(encoding="utf-8")
            data = json.loads(original)
        except FileNotFoundError:
            print(f"error: file not found: {path}", file=sys.stderr)
            exit_code = 1
            continue
        except json.JSONDecodeError as exc:
            print(f"error: invalid JSON in {path}: {exc}", file=sys.stderr)
            exit_code = 1
            continue

        replacements = rewrite_datasources(data)
        updated = json.dumps(data, indent=2, ensure_ascii=False) + "\n"

        if updated != original:
            path.write_text(updated, encoding="utf-8")

        print(f"{path}: updated {replacements} datasource uid value(s)")

    return exit_code


raise SystemExit(main(sys.argv[1:]))
PY
