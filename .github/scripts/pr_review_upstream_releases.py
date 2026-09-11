#!/usr/bin/env python3
"""Upstream release-notes evidence provider for the AI PR Reviewer.

Reads the PR title, body, and changed files via `gh api`, infers each
`<owner>/<repo>@<version>` pair touched by the PR, and fetches the matching GitHub
release notes body. Emits JSON on stdout in the evidence-provider schema so the
action can inject it into the model context.

Output schema:
    {
      "severity": "info" | "warning" | "blocker",
      "findings": [
        {"severity": "...", "message": "...", "source": "https://..."}
      ]
    }

Environment:
    REPO        - `owner/name` of the PR's repo (always set by the action)
    PR_NUMBER   - PR number (always set by the action)
    GH_TOKEN / GITHUB_TOKEN - used implicitly by `gh api`
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass
class Target:
    owner_repo_candidates: list[str]  # e.g. ["siderolabs/talos"]
    version: str                       # e.g. "1.14.0" (no leading 'v')

    @property
    def key(self) -> str:
        return f"{self.owner_repo_candidates[0]}@{self.version}"


def gh_json(args: list[str]) -> object:
    """Run `gh api <args>` and return parsed JSON, or None on failure."""
    try:
        result = subprocess.run(
            ["gh", "api", *args],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def gh_text(args: list[str]) -> str:
    try:
        result = subprocess.run(
            ["gh", "api", *args],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""
    return result.stdout if result.returncode == 0 else ""


_VERSION_RE = re.compile(r"v?(\d+(?:\.\d+){1,3}(?:[-.][0-9A-Za-z.-]+)?)")


def extract_version(blob: str) -> str | None:
    match = _VERSION_RE.findall(blob)
    if not match:
        return None
    # Prefer the LAST semver-shaped hit — Renovate titles "X (a ➔ b)" put the new
    # version last; diff lines like `tag: 1.2.3` also put target last.
    return match[-1].lstrip("v")


_REGISTRY_OWNER_RE = re.compile(
    r"\b(?:ghcr\.io|quay\.io|docker\.io|registry\.gitlab\.com)/"
    r"(?P<namespace>[A-Za-z0-9._-]+)/(?P<repo>[A-Za-z0-9._-]+)"
)


def _registry_segments(blob: str) -> Iterable[tuple[str, str]]:
    """Yield (owner, repo) candidates from registry paths in `blob`, shortest first.

    For `ghcr.io/intel/intel-resource-drivers-for-kubernetes/foo-chart`:
        - ('intel', 'intel-resource-drivers-for-kubernetes')  → real GH repo
        - ('intel-resource-drivers-for-kubernetes', 'foo-chart') → also real GH repo
    Try each candidate via `fetch_release_notes`; first one with a real release wins.
    """
    for match in _REGISTRY_OWNER_RE.finditer(blob):
        yield match.group("namespace"), match.group("repo")


def extract_owner_repo(blob: str) -> str | None:
    """Best-effort conversion of a path/URL fragment into `owner/repo`.

    Returns the FIRST registry-path candidate; callers should use
    `extract_owner_repo_candidates` when there are multiple plausible paths.
    """
    for owner, repo in _registry_segments(blob):
        return f"{owner}/{repo}"
    match = re.search(r"github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)", blob)
    if match:
        return f"{match.group(1)}/{match.group(2)}"
    return None


_KNOWN_NON_REPO_OWNERS = frozenset({
    "feat", "fix", "chore", "ci", "docs", "deps", "aqua",
    "feat(container)", "fix(container)", "feat(container)!",
    "feat(deps)", "feat(container)!:", "fix(deps)",
})
_KNOWN_NON_REPO_REPOS = frozenset({"charts", "manifests", "config"})


def extract_owner_repo_candidates(blob: str) -> list[str]:
    """All plausible owner/repo candidates from a single string, registry paths first.

    Bare `owner/repo` pairs are filtered: the owner must not be a renovate prefix
    (`feat/fix/chore/...`) or a registry hostname (ghcr.io/quay.io/docker.io/...),
    and the repo must not be a generic chart-hub directory like `charts`.
    """
    found: list[str] = []
    seen: set[str] = set()
    for owner, repo in _registry_segments(blob):
        key = f"{owner}/{repo}"
        if key not in seen:
            seen.add(key)
            found.append(key)
    github_match = re.search(r"github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)", blob)
    if github_match:
        key = f"{github_match.group(1)}/{github_match.group(2)}"
        if key not in seen:
            seen.add(key)
            found.append(key)
    for bare in re.finditer(r"\b([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)\b", blob):
        owner, repo = bare.group(1), bare.group(2)
        if owner in _KNOWN_NON_REPO_OWNERS:
            continue
        if owner.endswith(".io") or owner.endswith(".com"):
            continue
        if repo in _KNOWN_NON_REPO_REPOS:
            continue
        if re.fullmatch(r"v?\d+(?:\.\d+)*", repo):
            continue
        # Reject registry-shaped owners that survive the URL-extraction regex.
        if owner.startswith("ghcr.") or owner.startswith("quay."):
            continue
        if owner.startswith("docker.") or owner.startswith("registry."):
            continue
        key = f"{owner}/{repo}"
        if key not in seen:
            seen.add(key)
            found.append(key)
    return found


def infer_targets(pr: dict, files: list[dict]) -> list[Target]:
    """Collect (owner/repo, version) targets from the PR title, body, and diff.

    For each version-bearing line in the PR, gather every plausible owner/repo
    candidate (multiple paths can match for registry-style images). At fetch
    time, we try each candidate — first GitHub release hit wins.
    """
    blobs: list[str] = [pr.get("title", ""), pr.get("body") or ""]
    for entry in files:
        patch = entry.get("patch")
        filename = entry.get("filename") or ""
        blob_parts: list[str] = []
        if isinstance(patch, str):
            blob_parts.append(patch)
        blob_parts.append(filename)
        blob = "\n".join(blob_parts)
        # Only consider version-bearing lines to avoid pulling unrelated
        # `owner/repo` strings from the diff.
        for line in blob.splitlines():
            if any(token in line for token in ("image:", "tag:", "version:",
                                               "chart:", "appVersion:",
                                               "digest:")):
                blobs.append(line)

    by_version: dict[str, list[str]] = {}
    for blob in blobs:
        version = extract_version(blob)
        if not version:
            continue
        candidates = extract_owner_repo_candidates(blob)
        for c in candidates:
            by_version.setdefault(version, [])
            if c not in by_version[version]:
                by_version[version].append(c)

    return [Target(owner_repo_candidates=cands, version=v)
            for v, cands in sorted(by_version.items())]


def fetch_release_notes(target: Target) -> tuple[str | None, dict | None]:
    """Try `gh api repos/{owner_repo}/releases/tags/{variant}` for several tag
    variants and several owner/repo candidates. Returns (matched_owner_repo,
    release_dict) or (None, None) on full miss."""
    for owner_repo in target.owner_repo_candidates:
        for prefix in ("v", "", "V"):
            tag = f"{prefix}{target.version}"
            data = gh_json(["repos", owner_repo, "releases", "tags", tag])
            if isinstance(data, dict) and data.get("tag_name"):
                return owner_repo, data
        # Also try listing releases for this candidate (handles cases where
        # the upstream tag is named differently from Renovate's expected slug).
        data = gh_json(["repos", owner_repo, "releases", {"per_page": 30}])
        if isinstance(data, list) and data:
            return owner_repo, data
    return None, None


def numeric_version(version: str) -> tuple[int, ...]:
    m = re.match(r"v?(\d+(?:\.\d+){1,3})", version)
    if not m:
        return ()
    return tuple(int(p) for p in m.group(1).split("."))


def best_proxy_release(releases: list[dict], target: str) -> dict | None:
    """Pick the most recent release whose numeric version is <= target."""
    target_n = numeric_version(target)
    matches = [r for r in releases
               if numeric_version(r.get("tag_name") or "") <= target_n
               and numeric_version(r.get("tag_name") or "")]
    if not matches:
        return None
    # Latest one closest to target.
    return max(matches, key=lambda r: numeric_version(r.get("tag_name") or ""))


def build_findings(targets: Iterable[Target]) -> list[dict]:
    findings: list[dict] = []
    target_list = list(targets)
    if not target_list:
        return [
            {
                "severity": "info",
                "message": (
                    "No upstream (owner/repo, version) pairs could be inferred "
                    "from the PR title or changed-file diff. Did not attempt "
                    "to fetch release notes."
                ),
                "source": "upstream-release-notes",
            }
        ]

    for target in target_list:
        matched_owner, fetched = fetch_release_notes(target)

        if matched_owner is None or fetched is None:
            findings.append({
                "severity": "warning",
                "message": (
                    f"Could not fetch GitHub release notes for any candidate of "
                    f"{target.owner_repo_candidates} @ version {target.version}. "
                    f"The PR is likely a digest-only or unreleased bump, the "
                    f"upstream repo is private/restricted, or the tag naming "
                    f"scheme differs from Renovate's expectation."
                ),
                "source": (
                    f"https://github.com/{target.owner_repo_candidates[0]}/releases"
                    if target.owner_repo_candidates else "upstream-release-notes"
                ),
            })
            continue

        # `fetched` is a dict (single release) or list (release index).
        if isinstance(fetched, list):
            release = best_proxy_release(fetched, target.version)
            if release is None:
                continue
            prefix = (
                f"No release at exact version {target.version}; "
                f"showing the most recent release at or before it."
            )
        else:
            release = fetched
            prefix = (
                f"GitHub release notes for {matched_owner} @ "
                f"{release.get('tag_name', '')}."
            )

        body = (release.get("body") or "").strip()
        if not body:
            body = "(Release notes body is empty.)"
        if len(body) > 6000:
            body = body[:6000] + "\n\n[release notes truncated at 6000 chars]"

        findings.append({
            "severity": "info",
            "message": f"{prefix}\n\n{body}",
            "source": release.get("html_url") or
                      f"https://github.com/{matched_owner}/releases",
        })

    return findings


def main() -> int:
    repo = os.environ.get("REPO", "").strip()
    pr_number = os.environ.get("PR_NUMBER", "").strip()
    if not repo or not pr_number:
        sys.stderr.write(
            "upstream-release-notes: REPO and PR_NUMBER must be set by the "
            "reviewer action\n"
        )
        print(json.dumps({
            "severity": "info",
            "findings": [{
                "severity": "info",
                "message": "Missing REPO/PR_NUMBER environment; skipping.",
                "source": "upstream-release-notes",
            }],
        }))
        return 0

    pr = gh_json(["repos", repo, "pulls", pr_number])
    if not isinstance(pr, dict):
        sys.stderr.write(f"upstream-release-notes: could not fetch PR {repo}#{pr_number}\n")
        print(json.dumps({
            "severity": "warning",
            "findings": [{
                "severity": "warning",
                "message": (
                    f"Could not fetch PR metadata via `gh api` for "
                    f"{repo}#{pr_number}. Upstream release notes will not be "
                    f"included in this review."
                ),
                "source": "upstream-release-notes",
            }],
        }))
        return 0

    files_raw = gh_text([
        "repos", repo, "pulls", pr_number, "files",
        "--paginate", "--jq",
        ".[] | {filename, patch, previous_filename}",
    ])
    files: list[dict] = []
    if files_raw.strip():
        for line in files_raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                files.append(json.loads(line))
            except json.JSONDecodeError:
                continue

    targets = infer_targets(pr, files)
    findings = build_findings(targets)
    payload = {"severity": "info", "findings": findings}
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
