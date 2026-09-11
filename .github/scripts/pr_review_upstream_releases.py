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


def gh_json(args: list) -> object:
    """Run `gh api <url>` and return parsed JSON, or None on failure.

    `gh api` takes a single URL/path positional; query-string params on that
    path are how you paginate / filter. We accept a mixed list of str and
    dict, build a path with `?k=v&k=v` query appended, and use `-q` only if
    `gh` requires explicit flagging.
    """
    path_parts: list[str] = []
    qs_parts: list[str] = []
    for arg in args:
        if isinstance(arg, dict):
            for k, v in arg.items():
                qs_parts.append(f"{k}={v}")
        else:
            path_parts.append(str(arg))
    path = "/".join(path_parts)
    if qs_parts:
        path = f"{path}?{'&'.join(qs_parts)}"
    try:
        result = subprocess.run(
            ["gh", "api", path],
            capture_output=True, text=True, timeout=30, check=False,
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
    last_chart_name = ""
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

    # Pick a chart_name hint: the trailing non-version segment after the last
    # registry host. e.g. `ghcr.io/goauthentik/helm-charts/authentik:2026.8.2`
    # → chart_name = "authentik".
    title_blob = pr.get("title", "") or ""
    for blob in (title_blob, blobs[0] if blobs else ""):
        m = re.search(
            r"\b(?:ghcr\.io|quay\.io|docker\.io|registry\.gitlab\.com)/"
            r"(?P<a>[^/: \n\r\t]+)/"
            r"(?:[^/: \n\r\t]+/)*?"
            r"(?P<chart>[A-Za-z0-9._-]+)"
            r"(?::v?\d|\s|$)",
            blob,
        )
        if m and m.group("chart") != m.group("a"):
            last_chart_name = m.group("chart")
            break

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

    return [Target(owner_repo_candidates=cands, version=v,
                   chart_name=last_chart_name)
            for v, cands in sorted(by_version.items())]


_TAG_PREFIXES = (
    "", "v", "V", "version/", "release/", "chart/", "helm-",
    "helm-chart-", "release-", "chart-v", "charts-v",
)


@dataclass
class Target:
    owner_repo_candidates: list[str]   # primary guesses from PR title/diff
    version: str                        # e.g. "1.14.0" (no leading 'v')
    chart_name: str = ""                # last registry path segment, used for org-sibling heuristic

    @property
    def key(self) -> str:
        return f"{self.owner_repo_candidates[0]}@{self.version}"


def _expand_org_candidates(owner_repo: str, chart_name: str) -> list[str]:
    """For multi-component projects where the registry path doesn't match the
    GH repo name (e.g. ghcr.io/goauthentik/helm-charts/authentik → upstreams
    in `goauthentik/authentik`), list the org's repos and find ones whose
    description mentions 'helm' or whose name matches the chart name.

    Returns up to 4 chart-relevant sibling repos plus 2 recent fallbacks.
    """
    if "/" not in owner_repo:
        return []
    owner = owner_repo.split("/")[0]
    org_data = gh_json(["orgs", owner, "repos",
                        {"per_page": 100, "sort": "updated"}])
    if not isinstance(org_data, list):
        return []

    chart_targets: list[str] = []
    fallback_targets: list[str] = []
    hint = chart_name.lower() if chart_name else ""
    for repo in org_data:
        name = (repo.get("name") or "").lower()
        description = (repo.get("description") or "").lower()
        full_name = repo.get("full_name") or ""
        if not full_name.startswith(owner + "/"):
            continue
        # Skip the org's umbrella chart repo (helm-charts, etc.) — it rarely
        # publishes release notes; the chart-specific repo or the main app
        # repo do.
        if name in {"helm-charts", "charts", "helm", "terraform-providers"}:
            continue
        # Chart-relevant: contains helm/chart in name, or matches the chart
        # name directly.
        if "helm" in name or "chart" in name:
            chart_targets.append(full_name)
            continue
        if hint and (name == hint or name.endswith("-" + hint)
                     or name.endswith("_" + hint)):
            chart_targets.append(full_name)
            continue
        # Anything else (the main app repo, etc.) — fall back to it after the
        # explicit picks.
        fallback_targets.append(full_name)
    return chart_targets[:4] + fallback_targets[:2]


def fetch_release_notes(target: Target) -> tuple[str | None, dict | None]:
    """Try `gh api repos/{owner_repo}/releases/tags/{variant}` for many tag
    variants and several owner/repo candidates (including org siblings for
    chart-bundle repos).

    Returns (matched_owner_repo, release_dict) or (None, None) on full miss.
    """
    # Build the candidate list: explicit guesses first, then inferred org siblings.
    primary_candidates = list(target.owner_repo_candidates)
    expanded: list[str] = []
    for cand in primary_candidates:
        expanded.extend(_expand_org_candidates(cand, target.chart_name))
    seen: set[str] = set()
    candidates: list[str] = []
    for cand in primary_candidates + expanded:
        if cand not in seen:
            seen.add(cand)
            candidates.append(cand)

    for owner_repo in candidates:
        for prefix in _TAG_PREFIXES:
            tag = f"{prefix}{target.version}"
            data = gh_json(["repos", owner_repo, "releases", "tags", tag])
            if isinstance(data, dict) and data.get("tag_name"):
                return owner_repo, data
        # Last-resort: list tags (some repos don't publish releases, just tags).
        tags_data = gh_json(["repos", owner_repo, "tags", {"per_page": 30}])
        if isinstance(tags_data, list) and tags_data:
            target_n = numeric_version(target.version)
            best = None
            best_n: tuple[int, ...] = ()
            for tag_entry in tags_data:
                tag_name = tag_entry.get("name") or ""
                n = numeric_version(tag_name)
                if not n or (target_n and n > target_n):
                    continue
                if n >= best_n:
                    best_n = n
                    best = tag_entry
            if best is not None:
                commit = best.get("commit") or {}
                return owner_repo, {
                    "tag_name": best.get("name"),
                    "html_url": (
                        f"https://github.com/{owner_repo}/releases/tag/"
                        f"{best.get('name')}"
                    ),
                    "body": (
                        f"Tagged release `{best.get('name')}` at "
                        f"https://github.com/{owner_repo}/commit/"
                        f"{(commit.get('sha') or '')[:7]}.\n\n"
                        f"No GitHub release notes body published for this tag; "
                        f"consult the upstream changelog or compare view for "
                        f"the full list of changes between this tag and the "
                        f"previous one."
                    ),
                }
        # Releases index — useful when tag style is wildly different.
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
