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

import base64
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


# --- Non-semver / dev / nightly tag handling ---------------------------------
# Tags like `dev`, `nightly`, `main`, `edge`, `unstable` have no GitHub release
# notes body. The closest analog is the `compare` view between the previous
# semver tag and the moving tag's HEAD commit, which exposes commit subjects
# and merged-PR titles. Date-suffixed tags (`nightly-20251006`,
# `2026-10-05-abcdef0`) are treated as a date for ordering only.
_VERSION_CLASS_RE = re.compile(
    r"^v?\d+(?:\.\d+){1,3}"
    r"(?:[-.+][0-9A-Za-z-]+)*"
    r"$"
)
# A prerelease must be glued to the version with a `-` (semver convention) and
# must contain at least one letter or hyphen; pure digits would be a build
# counter and don't change classification from semver → prerelease.
# `1.2.3-rc.1` matches because `rc` contains letters, and the inner `.1`
# is a semver prerelease sub-identifier.
_PRERELEASE_RE = re.compile(
    r"^v?\d+(?:\.\d+){1,3}-"
    r"(?=[0-9A-Za-z.-]*[A-Za-z-])"
    r"[0-9A-Za-z.-]+"
    r"(?:\+[0-9A-Za-z.-]+)?$"
)
_DATE_TAG_RE = re.compile(
    r"^(?:[A-Za-z][A-Za-z0-9._-]*-)?(?P<date>\d{4}[-._]?\d{2}[-._]?\d{2})"
    r"(?:[-.+](?P<sha>[0-9a-f]{7,40}))?$",
    re.IGNORECASE,
)
# 4-segment numerics like `2026.10.05` are almost always dates, not versions.
_4_SEGMENT_NUMERIC_RE = re.compile(r"^\d{4}\.\d{1,2}\.\d{1,2}$")
_NAMED_TAG_RE = re.compile(
    r"^(?P<name>(?:dev|nightly|edge|main|master|unstable|stable|latest|"
    r"rc|alpha|beta|preview|canary|hack|next|rolling|testing))"
    r"(?:[-.](?P<suffix>[0-9A-Za-z.-]+))?$",
    re.IGNORECASE,
)


def classify_version(version: str) -> str:
    """Return one of: "semver", "semver_with_prerelease", "date_tag",
    "named_tag", or "unknown". Used to pick the right fetch strategy in
    `fetch_release_notes` — the existing release-tag path stays the default
    for "semver" / "semver_with_prerelease"; the new compare-view path
    covers "date_tag" and "named_tag" so dev/nightly/main builds get a
    concrete commit list instead of the boilerplate "no release notes
    published" message."""
    v = (version or "").strip()
    if not v:
        return "unknown"
    # Date-shaped tags first because a 4-segment numeric (`2026.10.05`) also
    # matches the semver shape. Date wins so the compare-view path is used
    # instead of treating a date as a real release version.
    if _DATE_TAG_RE.match(v):
        return "date_tag"
    if _4_SEGMENT_NUMERIC_RE.match(v):
        return "date_tag"
    if _PRERELEASE_RE.match(v):
        return "semver_with_prerelease"
    if _VERSION_CLASS_RE.match(v):
        return "semver"
    if _NAMED_TAG_RE.match(v):
        return "named_tag"
    # Anything else (custom non-semver tag) falls back to the compare view —
    # the user gets commit messages rather than the boilerplate.
    return "named_tag"


def resolve_tag_to_sha(owner_repo: str, tag: str) -> str | None:
    """Resolve a git tag to its commit SHA via the git/refs API.

    Returns the SHA, or None if the tag does not exist on the default branch's
    history. Used for non-semver tags so we can anchor a compare view to a
    concrete commit."""
    data = gh_json(["repos", owner_repo, "git", "ref", f"tags/{tag}"])
    if isinstance(data, dict):
        obj = data.get("object") or {}
        if obj.get("sha") and obj.get("type") in (None, "commit"):
            return obj["sha"]
        # Annotated tags point at a tag object — dereference one hop.
        if obj.get("type") == "tag" and obj.get("sha"):
            inner = gh_json(["repos", owner_repo, "git", "commit", obj["sha"]])
            if isinstance(inner, dict):
                return inner.get("sha")
    return None


def find_previous_stable_tag(
    owner_repo: str,
    target_version: str,
    target_sha: str,
) -> str | None:
    """Return the most recent semver tag (no prerelease) that resolves to a
    commit strictly before `target_sha`, or None.

    Used as the base of a compare view for `:dev` / `:nightly` style targets
    when the user wants to know what changed since the last real release.
    Limited to a small page of tags to keep the API call cheap."""
    tags_data = gh_json(["repos", owner_repo, "tags", {"per_page": 100}])
    if not isinstance(tags_data, list) or not tags_data:
        return None

    target_n = numeric_version(target_version) or ()
    seen: set[str] = set()
    candidates: list[tuple[tuple[int, ...], str]] = []
    for entry in tags_data:
        name = entry.get("name") or ""
        if not name or name in seen:
            continue
        seen.add(name)
        n = numeric_version(name)
        if not n:
            continue
        # Skip prerelease-shaped tags (`8.7.2-rc.1`, `0.18.2-0043-dev`).
        if _PRERELEASE_RE.match(name):
            continue
        # Skip the target itself and any future tag.
        if target_n and n > target_n:
            continue
        candidates.append((n, name))

    if not candidates:
        return None

    # Highest numeric version that is < target_version wins.
    candidates.sort()
    best = candidates[-1][1] if candidates else None
    if best is None:
        return None
    # Confirm the candidate tag resolves to a commit; if not, skip.
    best_sha = resolve_tag_to_sha(owner_repo, best)
    if best_sha is None or best_sha == target_sha:
        return None
    return best


def fetch_compare_commits(
    owner_repo: str,
    base_ref: str,
    head_ref: str,
    head_display: str | None = None,
    base_display: str | None = None,
    max_commits: int = 50,
) -> dict | None:
    """Call the GitHub `compare` API between two refs and render the result as
    a fake "release" dict so the existing findings pipeline can ingest it
    unchanged. Returns None if the compare is empty or fails.

    `head_ref` / `base_ref` are the values the compare endpoint actually
    accepts (a tag name, branch name, or 7-40 char SHA). `head_display` /
    `base_display` are the user-friendly labels rendered in the body and
    `tag_name` (defaults to `head_ref` when not provided) — typically the
    literal target tag like `0.18.2-0043-dev` rather than the resolved SHA.

    The compare endpoint returns up to 250 commits; we cap at `max_commits`
    (50 by default — past that the per-finding body exceeds the action's
    `evidence-provider-max-output-bytes` budget for a single finding) and
    truncate the rendered body if the byte count is still excessive."""
    data = gh_json([
        "repos", owner_repo, "compare", f"{base_ref}...{head_ref}",
    ])
    if not isinstance(data, dict):
        return None
    commits = data.get("commits") or []
    if not commits:
        return None

    lines: list[str] = []
    for entry in commits[:max_commits]:
        sha = (entry.get("sha") or "")[:7]
        msg_full = (entry.get("commit", {}).get("message") or "").splitlines()
        subject = msg_full[0].strip() if msg_full else ""
        if len(subject) > 200:
            subject = subject[:197] + "…"
        author = (
            entry.get("commit", {}).get("author", {}).get("name")
            or entry.get("author", {}).get("login")
            or "unknown"
        )
        date = (
            entry.get("commit", {}).get("author", {}).get("date", "")[:10]
        )
        lines.append(f"- `{sha}` {subject} ({author}, {date})")

    if len(commits) > max_commits:
        lines.append(f"\n…{len(commits) - max_commits} additional commits omitted")

    head_label = head_display or head_ref
    base_label = base_display or base_ref
    body = (
        f"Non-semver target `{head_label}` — no GitHub release notes body was "
        f"published for this tag. The following commit list covers the "
        f"compare view between the previous semver release and the target "
        f"commit, which is the closest analog to a changelog for a moving "
        f"`:dev` / `:nightly` build.\n\n"
        f"## Commits between `{base_label}` and `{head_label}`\n\n"
        + "\n".join(lines)
    )

    return {
        "tag_name": head_label,
        "html_url": (
            data.get("html_url")
            or f"https://github.com/{owner_repo}/compare/{base_ref}...{head_ref}"
        ),
        "body": body,
        "_is_compare_view": True,
    }


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
        # First try the semver-shaped extractor (matches `1.2.3`,
        # `2024.10.5`, `8.7.2-dev+build.123`, etc.). For pure non-numeric
        # tags like `dev`, `nightly`, `edge`, fall through to the line-level
        # tag literal — Renovate PRs for these bumps put the tag on a
        # `tag: <name>` diff line that we still want to capture.
        version = extract_version(blob)
        if not version:
            for line in blob.splitlines():
                line_stripped = line.strip()
                m = re.search(
                    r"\b(?:image|tag|version|chart|appVersion|release)\s*[:=]\s*"
                    r"(?P<tag>[A-Za-z0-9._+-]+)",
                    line_stripped,
                )
                if m:
                    candidate_tag = m.group("tag")
                    cls = classify_version(candidate_tag)
                    if cls in ("named_tag", "date_tag", "semver_with_prerelease"):
                        version = candidate_tag
                        break
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

# Charts published as OCI Helm chart artifacts by `home-operations/charts-mirror`
# (a community project to mirror OCI charts from their original helm registries).
# This repo uses `apps/<chart>/metadata.yaml` to declare the upstream source.
_MIRROR_REPO = "home-operations/charts-mirror"

# Some chart-only repos are umbrella repos where upstream releases are tagged
# against the umbrella (`bitnami/charts`, `kedacore/charts`, `grafana/helm-charts`).
# Map those to the actual upstream application repo when known. Keys are matched
# case-insensitively against `lower()`.
_CHART_UMBRELLAS = {
    "grafana/helm-charts": "grafana/alloy",     # alloy → grafana/helm-charts, app is grafana/alloy
    "kedacore/charts": "kedacore/keda",
    "prometheus-community/helm-charts": "prometheus/prometheus",
    "ceph/charts": "ceph/ceph-csi",
    "rook/charts": "rook/rook",
    "argo-cd/argo-helm-charts": "argoproj/argo-cd",
    "jetstack/charts": None,                     # varies per chart; see per-chart overrides
    "quay.io/jetstack/charts": None,
}

# Per-chart overrides for umbrella chart repos whose app lives in a different org.
# Key: chart_name (from registry path). Value: upstream GitHub owner/repo.
_CHART_OVERRIDES = {
    "cert-manager": "cert-manager/cert-manager",
    "trust-manager": "cert-manager/trust-manager",
    "approver-policy": "cert-manager/approver-policy",
}


def _url_to_upstream_repo(registry_url: str) -> str | None:
    """Map a Helm registry URL to a probable GitHub owner/repo.

    Handles:
      - https://kubernetes-sigs.github.io/external-dns → kubernetes-sigs/external-dns
      - https://charts.longhorn.io                     → longhorn/longhorn
      - https://helm.goharbor.io                       → goharbor/harbor
      - https://rocm.github.io/k8s-device-plugin       → rocm/k8s-device-plugin
      - https://kedacore.github.io/charts              → null (umbrella; see _CHART_UMBRELLAS)
    """
    if not registry_url:
        return None
    # `https://ORG.github.io/REPO` → `ORG/REPO`
    m = re.match(r"https?://([A-Za-z0-9._-]+)\.github\.io/([A-Za-z0-9._-]+)",
                 registry_url)
    if m:
        return f"{m.group(1)}/{m.group(2)}"
    # `https://charts.PROJECT.io` (and similar): `ORG/REPO` is probably `ORG/ORG`.
    m = re.match(r"https?://charts\.([A-Za-z0-9_-]+)\.io/?$", registry_url)
    if m:
        return f"{m.group(1)}/{m.group(1)}"
    # `https://helm.PROJECT.io` → PROJECT/harbor or similar, vary case-by-case.
    m = re.match(r"https?://helm\.([A-Za-z0-9_-]+)\.io/?$", registry_url)
    if m:
        helm_org = m.group(1)
        return f"{helm_org}/{helm_org}"
    return None


def load_mirror_metadata(chart_name: str) -> dict | None:
    """Read `apps/<chart_name>/metadata.yaml` from `home-operations/charts-mirror`.

    Returns a dict like `{'registry': 'https://...', 'version': '1.22.0'}` or None.
    """
    if not chart_name:
        return None
    path = f"apps/{chart_name}/metadata.yaml"
    encoded = gh_json([
        "repos", _MIRROR_REPO, "contents", path + "?ref=main",
    ])
    # gh_json is intended for the `gh api <url>` interface, but `/contents/`
    # responses are dicts with a base64 `content` key, not lists. Special-case.
    if not isinstance(encoded, dict) or not encoded.get("content"):
        return None
    try:
        text = base64.b64decode(encoded["content"]).decode("utf-8", errors="replace")
    except (ValueError, TypeError):
        return None
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.rstrip()
        m = re.match(r"\s*registry:\s*(.+?)\s*$", line)
        if m:
            out["registry"] = m.group(1).strip().strip('"').strip("'")
            continue
        m = re.match(r"\s*version:\s*(.+?)\s*$", line)
        if m:
            out["version"] = m.group(1).strip().strip('"').strip("'")
            continue
    return out or None


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
    name matches the chart name or contains 'helm'/'chart'.

    Returns up to 4 chart-relevant sibling repos. Does NOT return
    unrelated siblings — those would dilute the search with false-positive
    matches (the `release-list proximity` fallback can pick a random sibling
    release when the upstream publishes no tag at our target version).
    """
    if "/" not in owner_repo:
        return []
    owner = owner_repo.split("/")[0]
    org_data = gh_json(["orgs", owner, "repos",
                        {"per_page": 100, "sort": "updated"}])
    if not isinstance(org_data, list):
        return []

    chart_targets: list[str] = []
    hint = chart_name.lower() if chart_name else ""
    for repo in org_data:
        name = (repo.get("name") or "").lower()
        full_name = repo.get("full_name") or ""
        if not full_name.startswith(owner + "/"):
            continue
        # Skip the org's umbrella chart repos (helm-charts, charts, helm,
        # terraform-providers); they usually don't publish per-chart notes.
        if name in {"helm-charts", "charts", "helm", "terraform-providers"}:
            continue
        # Chart-relevant: chart-specific hub repos, or a repo whose name
        # matches the chart hint exactly.
        if hint and (name == hint or name.endswith("-" + hint)
                     or name.endswith("_" + hint)):
            chart_targets.append(full_name)
            continue
        # If the chart hint suggests a "Helm chart for $X" pattern, prefer
        # repos whose name combines helm + hint, e.g. authentik → goauthentik/authentik
        # (handled by the equality check above) or jetstack/charts (skipped).
    return chart_targets[:4]


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

    # If the matched candidate is the home-operations mirror, follow the
    # metadata.yaml link to the true upstream repo (e.g. external-dns →
    # kubernetes-sigs/external-dns). The mirror typically publishes no
    # per-chart release notes; the upstream does.
    upstream_candidates: list[str] = []
    for cand in primary_candidates + expanded:
        if cand.lower() == _MIRROR_REPO:
            meta = load_mirror_metadata(target.chart_name)
            if meta:
                upstream_repo = _url_to_upstream_repo(meta.get("registry", ""))
                if upstream_repo and upstream_repo not in upstream_candidates:
                    upstream_candidates.append(upstream_repo)

    # Per-chart overrides: when the chart's upstream app lives in a different
    # org (e.g. `jetstack/charts/cert-manager` → `cert-manager/cert-manager`),
    # add the explicit upstream to the candidate list.
    override = _CHART_OVERRIDES.get(target.chart_name.lower())
    if override and override not in upstream_candidates:
        upstream_candidates.append(override)

    seen: set[str] = set()
    candidates: list[str] = []
    # Upstream candidates first — they're the source of authoritative release
    # notes. Then primary, then org-sibling expansions. This way the mirror
    # (which only publishes thin per-chart CalVer tags) only gets matched if
    # the upstream is unreachable.
    for cand in (
        upstream_candidates
        + primary_candidates
        + expanded
    ):
        if cand not in seen:
            seen.add(cand)
            candidates.append(cand)

    for owner_repo in candidates:
        for prefix in _TAG_PREFIXES:
            tag = f"{prefix}{target.version}"
            data = gh_json(["repos", owner_repo, "releases", "tags", tag])
            if isinstance(data, dict) and data.get("tag_name"):
                return owner_repo, data

        # Non-semver targets (dev/nightly/edge, prerelease like
        # `0.18.2-0043-dev`, date-suffixed tags) must NOT use the proximity
        # fallback — that branch would approximate `0.18.2-0043-dev` to
        # the published `0.18.2` release and return the boilerplate "no
        # release notes published" body. Skip the proximity branch so the
        # compare-view path below gets a chance.
        target_classification = classify_version(target.version)
        target_n = numeric_version(target.version) if target_classification in ("semver", "unknown") else None
        if target_n:
            releases_list = gh_json([
                "repos", owner_repo, "releases", {"per_page": 40}
            ])
            if isinstance(releases_list, list) and releases_list:
                # Drop prereleases; prefer stable releases that share the
                # last two numeric segments with the target. Fall back to
                # any release whose numeric_version is numerically closest
                # to the target.
                def proximity_score(rel: dict) -> tuple[int, int]:
                    n = numeric_version(rel.get("tag_name") or "")
                    if not n:
                        return (10**9, 10**9)
                    if rel.get("prerelease"):
                        return (10**9, 10**9)
                    # Reward sharing last 2 segments with target.
                    shared_mm = abs(n[-2] - target_n[-2]) if len(n) >= 2 and len(target_n) >= 2 else 10**9
                    distance = sum(abs(a - b) for a, b in zip(n, target_n))
                    return (shared_mm, distance)
                candidates_rel = [r for r in releases_list
                                  if proximity_score(r) != (10**9, 10**9)]
                if candidates_rel:
                    best = min(candidates_rel, key=proximity_score)
                    return owner_repo, best

        # Last-resort: list tags (some repos don't publish releases, just tags).
        # For non-semver targets (dev/nightly/edge, prerelease like
        # `0.18.2-0043-dev`, date-suffixed tags) skip this branch entirely —
        # the tag list would match a *different* semver tag (`0.18.2`) and
        # return the boilerplate "no release notes published" message, which
        # is exactly what we're trying to fix. Fall through to the
        # compare-view branch below.
        if target_classification in ("semver_with_prerelease", "named_tag", "date_tag"):
            pass  # intentionally fall through to the compare-view path
        else:
            tags_data = gh_json(["repos", owner_repo, "tags", {"per_page": 30}])
            if isinstance(tags_data, list) and tags_data:
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

    # Non-semver targets (`dev`, `nightly`, `edge`, `main`, date-suffixed tags,
    # `1.2.3-rc.1`, etc.) have no GitHub release body. The closest analog is
    # the compare view between the previous semver release and the moving
    # tag's HEAD — the commit subjects and merged-PR titles are the de-facto
    # changelog for `:dev` / `:nightly` style builds.
    classification = classify_version(target.version)
    if classification in ("named_tag", "date_tag", "semver_with_prerelease"):
        for owner_repo in candidates:
            target_sha = resolve_tag_to_sha(owner_repo, target.version)
            if not target_sha:
                continue
            previous_tag = find_previous_stable_tag(
                owner_repo, target.version, target_sha
            )
            if not previous_tag:
                # No prior semver tag — fall back to the default branch HEAD
                # so we still get a commit list. Most repos have a meaningful
                # `main` / `master` ref to anchor against.
                default_branch = gh_json(["repos", owner_repo]) or {}
                default_branch_name = default_branch.get("default_branch")
                if not default_branch_name:
                    continue
                # Resolve the default branch ref to a SHA so `compare` works.
                default_ref_data = gh_json([
                    "repos", owner_repo, "git", "ref",
                    f"heads/{default_branch_name}",
                ])
                if not isinstance(default_ref_data, dict):
                    continue
                base_ref = default_ref_data.get("object", {}).get("sha")
                base_display = f"{default_branch_name} HEAD"
                compare_note = (
                    f"No prior semver release tag found in {owner_repo}; "
                    f"compared the target commit against the default branch "
                    f"(`{default_branch_name}`) HEAD instead."
                )
            else:
                base_ref = previous_tag
                base_display = previous_tag
                compare_note = None
            if not base_ref or base_ref == target_sha:
                continue
            compared = fetch_compare_commits(
                owner_repo, base_ref, target_sha,
                head_display=target.version,
                base_display=base_display,
            )
            if compared is None:
                continue
            if compare_note:
                compared["body"] = compared["body"] + "\n\n" + compare_note
            return owner_repo, compared

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


# Vendors that publish thin GitHub release bodies pointing at docs pages
# (e.g. authentik, bitnami, mongodb). Keyed on the docs host substring so
# we don't fetch arbitrary URLs from arbitrary GitHub bodies.
_DOCS_HOSTS = (
    "docs.goauthentik.io",
    "goauthentik.io/docs",      # marketing redirect that ends up at docs.goauthentik.io
    "bitnami.com/docs",
    "docs.mongodb.com",
    "docs.arangodb.com",
    "docs.datadoghq.com",
)


def _fetch_url_text(url: str, max_bytes: int = 800_000) -> str | None:
    """Fetch a URL with curl and return up to `max_bytes` of text, or None."""
    try:
        result = subprocess.run(
            ["curl", "-fsSL", "--max-time", "20", url],
            capture_output=True, text=True, timeout=25, check=False,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if result.returncode != 0:
        return None
    return result.stdout[:max_bytes]


def _html_to_markdownish(html: str) -> str:
    """Coarse HTML→text conversion: strip script/style, drop tags, collapse
    whitespace, preserve heading boundaries (heading text on its own line).
    Good enough for changelogs; not a full markdown converter.
    """
    html = re.sub(r"<script.*?</script>", "", html, flags=re.DOTALL)
    html = re.sub(r"<style.*?</style>", "", html, flags=re.DOTALL)
    # Insert newline before block-level headings/lists so the model's
    # section boundaries survive whitespace collapse.
    html = re.sub(r"<(h[1-6]|li|p|ul|ol|div|br|tr)\b[^>]*>",
                  lambda m: "\n" + m.group(0), html, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", " ", html)
    text = (text.replace("&amp;", "&").replace("&lt;", "<")
                 .replace("&gt;", ">").replace("&nbsp;", " ")
                 .replace("&#39;", "'").replace("&quot;", '"'))
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n[ \t]+", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def expand_thin_release(release: dict, version: str) -> dict | None:
    """For a GitHub release whose body is just a link to a docs/release
    page, fetch the docs page and return a new release-shaped dict with the
    page content as the body. Returns None if no expansion was performed.

    Triggered when:
      - body length <= 400 chars (a real changelog is longer than this)
      - body contains a URL whose host is in `_DOCS_HOSTS`
    """
    body = (release.get("body") or "").strip()
    if len(body) > 400:
        return None
    # Find first URL whose host matches any known docs host.
    url_match = None
    for m in re.finditer(r"https?://([A-Za-z0-9._-]+)(/[^\s)]*)?", body):
        host = m.group(1).lower()
        if any(h in host for h in _DOCS_HOSTS):
            url_match = m.group(0)
            break
    if not url_match:
        return None

    html = _fetch_url_text(url_match)
    if not html:
        return None
    text = _html_to_markdownish(html)
    if not text:
        return None
    # Trim to the most useful section: prefer "Breaking changes" / "Fixed in <version>"
    # / changelog headers if present, otherwise take the first ~8000 chars.
    useful_match = re.search(
        r"(?:Breaking changes|What.{0,3}s new|Highlights|Fixed in\s+\S+|"
        r"Changelog|Release notes|API changes|New features)\b.*",
        text, flags=re.IGNORECASE | re.DOTALL,
    )
    excerpt = (useful_match.group(0) if useful_match else text)[:8000]

    return {
        "tag_name": release.get("tag_name", ""),
        "html_url": url_match,
        "body": (
            f"Source: {url_match}\n\n"
            f"The upstream GitHub release body was a thin pointer to the "
            f"vendor's docs/release page. Auto-extracted excerpt below:\n\n"
            f"{excerpt}"
        ),
    }


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
            if release.get("_is_compare_view"):
                # Compare-view findings are anchored to the compare URL, not
                # a release page. The body itself leads with a "non-semver
                # target" explainer, so the prefix only needs to name the
                # scope.
                prefix = (
                    f"Upstream compare view for {matched_owner} covering "
                    f"the moving tag `{release.get('tag_name', target.version)}`."
                )
            else:
                prefix = (
                    f"GitHub release notes for {matched_owner} @ "
                    f"{release.get('tag_name', '')}."
                )

        body = (release.get("body") or "").strip()
        if not body:
            body = "(Release notes body is empty.)"

        # Some vendored release bodies (authentik, bitnami, mongodb) point at
        # a docs page that has the real changelog. When the body looks like a
        # thin pointer, fetch the page and substitute a real excerpt.
        if len(body) <= 400:
            expanded = expand_thin_release(release, target.version)
            if expanded is not None:
                release = expanded
                body = expanded["body"]

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

    # Diagnostic output to stderr so failures are visible in CI logs.
    sys.stderr.write(
        f"upstream-release-notes: inferred targets for {pr.get('title','')} "
        f"-> {len(targets)} target(s); {len(findings)} finding(s); "
        f"{sum(len(f.get('message', '')) for f in findings)} chars of content\n"
    )

    out = json.dumps(payload, indent=2, ensure_ascii=False)
    if not out.strip():
        # Defensive: always emit a parsable JSON object, even with no findings.
        out = json.dumps({"severity": "info", "findings": [
            {"severity": "info",
             "message": "upstream-release-notes: provider ran but produced no findings",
             "source": "upstream-release-notes"}
        ]})
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
