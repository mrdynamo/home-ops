#!/usr/bin/env python3
"""Cosign signature evidence provider for the AI PR Reviewer.

For every Flux `OCIRepository` with a `spec.verify` block whose ref the PR
changes, run `cosign verify` against the new ref using the same
`matchOIDCIdentity` issuer/subject regexes Flux will enforce. A missing or
non-matching signature is reported as a `blocker`: Flux fails closed with
`VerificationError` and the artifact never reconciles. Registry/network
errors are reported as `warning` (could not check), never as a blocker.

Why: spegel chart 0.8.2 was published without a signature (upstream release
workflow failed at its signing step). The model confirmed the identity regex
still matched the upstream workflow file, but nothing checked that a
signature actually existed for the new digest.

Output schema (same as pr_review_upstream_releases.py):
    {"severity": "info" | "warning" | "blocker",
     "findings": [{"severity": "...", "message": "...", "source": "..."}]}

Environment:
    REPO        - `owner/name` of the PR's repo (set by the action)
    PR_NUMBER   - PR number (set by the action)
    GH_TOKEN / GITHUB_TOKEN - used implicitly by `gh api`
    cosign must be on PATH (sigstore/cosign-installer in pr-reviewer.yaml).

Dependency-free on purpose (the ARC runner image has no PyYAML): OCIRepository
manifests here are plain block-style YAML, parsed by the small subset parser
below.
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

PROVIDER = "cosign-signatures"
# The action kills providers at 60s (pr-review-providers.json); stay under it.
OVERALL_BUDGET_SEC = 50
PER_CALL_TIMEOUT_SEC = 25
MAX_PARALLEL = 4
MAX_TARGETS = 16

# cosign stderr fragments meaning "the artifact is not signed the way Flux
# requires", as opposed to "could not reach the registry / TUF".
_UNSIGNED_MARKERS = (
    "no signatures found",
    "no matching signatures",
    "no matching attestations",
    "no matching certificateidentity",
)


# --- gh helpers ----------------------------------------------------------------

def gh(args: list[str]) -> str | None:
    try:
        result = subprocess.run(
            ["gh", "api", *args],
            capture_output=True, text=True, timeout=30, check=False,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    return result.stdout if result.returncode == 0 else None


def gh_json(args: list[str]) -> object:
    out = gh(args)
    if not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


# --- minimal YAML subset parser --------------------------------------------------
# Block mappings, block sequences (including "- key: value" items), plain and
# quoted scalars, comments. No anchors, flow collections, or block scalars;
# those come back as raw strings, which is fine for the fields read here.

_KEY_RE = re.compile(r"^(?P<key>[^\s:'\"#][^:]*?|'[^']*'|\"[^\"]*\"):(?:\s+(?P<val>.*))?$")


def _strip_comment(text: str) -> str:
    if text.startswith(("'", '"')):
        quote = text[0]
        i = 1
        while i < len(text):
            if text[i] == quote:
                if quote == "'" and text[i + 1:i + 2] == "'":
                    i += 2
                    continue
                if quote == '"' and text[i - 1] == "\\":
                    i += 1
                    continue
                return text[:i + 1]
            i += 1
        return text
    return re.sub(r"\s+#.*$", "", text).rstrip()


def _scalar(text: str) -> object:
    text = _strip_comment(text.strip())
    if len(text) >= 2 and text[0] == text[-1] == "'":
        return text[1:-1].replace("''", "'")
    if len(text) >= 2 and text[0] == text[-1] == '"':
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text[1:-1]
    if text in ("", "~", "null"):
        return None
    if text in ("true", "false"):
        return text == "true"
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    return text


def _lines(doc: str) -> list[tuple[int, str]]:
    out = []
    for raw in doc.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        out.append((len(raw) - len(raw.lstrip(" ")), raw.strip()))
    return out


def _parse(lines: list[tuple[int, str]], i: int, indent: int) -> tuple[object, int]:
    if i < len(lines) and lines[i][1].startswith("- ") or (i < len(lines) and lines[i][1] == "-"):
        return _parse_seq(lines, i, indent)
    return _parse_map(lines, i, indent)


def _child(lines, i, indent, allow_same_indent_seq):
    """Parse the value of a key/item whose inline value was empty."""
    if i >= len(lines):
        return None, i
    nxt_indent, nxt = lines[i]
    if nxt_indent > indent:
        return _parse(lines, i, nxt_indent)
    if allow_same_indent_seq and nxt_indent == indent and (nxt.startswith("- ") or nxt == "-"):
        return _parse_seq(lines, i, indent)
    return None, i


def _parse_map(lines, i, indent):
    result: dict = {}
    while i < len(lines):
        cur_indent, text = lines[i]
        if cur_indent != indent or text.startswith("- ") or text == "-":
            break
        m = _KEY_RE.match(text)
        if not m:
            raise ValueError(f"unsupported YAML line: {text!r}")
        key = _scalar(m.group("key"))
        val = m.group("val")
        i += 1
        if val is None or _strip_comment(val) == "":
            result[key], i = _child(lines, i, indent, allow_same_indent_seq=True)
        else:
            result[key] = _scalar(val)
    return result, i


def _parse_seq(lines, i, indent):
    result: list = []
    while i < len(lines):
        cur_indent, text = lines[i]
        if cur_indent != indent or not (text.startswith("- ") or text == "-"):
            break
        content = text[1:].strip()
        if not content:
            item, i = _child(lines, i + 1, indent, allow_same_indent_seq=False)
        elif _KEY_RE.match(content):
            # "- key: value" starts a mapping whose keys sit at indent + 2.
            sub_indent = indent + 2
            sub = [(sub_indent, content)] + lines[i + 1:]
            item, used = _parse_map(sub, 0, sub_indent)
            i += used
        else:
            item = _scalar(content)
            i += 1
        result.append(item)
    return result, i


def parse_yaml_doc(doc: str) -> object:
    lines = _lines(doc)
    if not lines:
        return None
    value, _ = _parse(lines, 0, lines[0][0])
    return value


def oci_repositories(text: str) -> list[dict]:
    """Return parsed OCIRepository documents from a (multi-doc) YAML file."""
    docs = []
    for doc in re.split(r"^---\s*$", text, flags=re.MULTILINE):
        # Only parse documents that are OCIRepositories; other kinds in the
        # same file (HelmRelease values, etc.) may use YAML features the
        # subset parser does not support.
        if not re.search(r"^kind:\s*OCIRepository\s*$", doc, flags=re.MULTILINE):
            continue
        try:
            parsed = parse_yaml_doc(doc)
        except ValueError:
            parsed = {"kind": "OCIRepository", "_parse_error": True}
        if isinstance(parsed, dict):
            docs.append(parsed)
    return docs


# --- targets & verification ---------------------------------------------------------

@dataclass
class Target:
    path: str
    name: str
    ref: str
    identities: list[dict] = field(default_factory=list)
    file_url: str = ""


@dataclass
class Result:
    target: Target
    severity: str
    message: str


def _added_text(patch: str | None) -> str:
    if not patch:
        return ""
    return "\n".join(
        line[1:] for line in patch.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


def collect_targets(repo: str, head_sha: str, files: list[dict]) -> tuple[list[Target], list[dict]]:
    targets: list[Target] = []
    notes: list[dict] = []
    for entry in files:
        path = entry.get("filename", "")
        if entry.get("status") == "removed" or not path.endswith((".yaml", ".yml")):
            continue
        patch = entry.get("patch")
        added = _added_text(patch)
        # Cheap prefilter: only fetch files whose diff could touch an OCIRepository.
        if patch is not None and not re.search(r"\b(tag|digest|url|semver|verify|subject|issuer)\b", added):
            continue
        content = gh_json([f"repos/{repo}/contents/{path}?ref={head_sha}"])
        if not isinstance(content, dict) or content.get("encoding") != "base64":
            continue
        try:
            text = base64.b64decode(content.get("content", "")).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            continue
        file_url = f"https://github.com/{repo}/blob/{head_sha}/{path}"
        for doc in oci_repositories(text):
            name = ((doc.get("metadata") or {}).get("name")) or "<unnamed>"
            if doc.get("_parse_error"):
                notes.append({
                    "severity": "warning",
                    "message": f"`{path}`: could not parse OCIRepository document; signature not checked.",
                    "source": file_url,
                })
                continue
            spec = doc.get("spec") or {}
            verify = spec.get("verify")
            if not isinstance(verify, dict):
                continue
            ref = spec.get("ref") or {}
            digest, tag = ref.get("digest"), ref.get("tag")
            # Only check OCIRepositories this PR actually changes.
            if patch is not None and not any(
                v and str(v) in added for v in (digest, tag, spec.get("url"))
            ):
                continue
            url = str(spec.get("url", ""))
            if not url.startswith("oci://"):
                continue
            base = url[len("oci://"):]
            if digest:
                full_ref = f"{base}@{digest}"
            elif tag:
                full_ref = f"{base}:{tag}"
            else:
                notes.append({
                    "severity": "info",
                    "message": f"`{name}` (`{path}`) uses a semver/floating ref; signature not checked by this provider.",
                    "source": file_url,
                })
                continue
            if verify.get("provider") != "cosign":
                notes.append({
                    "severity": "info",
                    "message": f"`{name}` uses verify provider `{verify.get('provider')}`; only cosign is checked.",
                    "source": file_url,
                })
                continue
            if verify.get("secretRef"):
                notes.append({
                    "severity": "info",
                    "message": f"`{name}` verifies with a key from a Secret; keyed verification is not checked by this provider.",
                    "source": file_url,
                })
                continue
            identities = [i for i in (verify.get("matchOIDCIdentity") or []) if isinstance(i, dict)]
            targets.append(Target(path, name, full_ref, identities, file_url))
    return targets, notes


def verify_target(target: Target, deadline: float) -> Result:
    identities = target.identities or [{"issuer": ".*", "subject": ".*"}]
    last_err = ""
    unsigned = False
    for ident in identities:
        remaining = deadline - time.monotonic()
        if remaining < 3:
            break
        cmd = [
            "cosign", "verify", target.ref,
            "--certificate-oidc-issuer-regexp", str(ident.get("issuer", ".*")),
            "--certificate-identity-regexp", str(ident.get("subject", ".*")),
        ]
        try:
            proc = subprocess.run(
                cmd, capture_output=True, text=True, check=False,
                timeout=min(PER_CALL_TIMEOUT_SEC, remaining),
            )
        except subprocess.TimeoutExpired:
            last_err = "cosign verify timed out"
            continue
        if proc.returncode == 0:
            return Result(target, "info",
                          f"`{target.name}`: cosign signature verified for `{target.ref}` "
                          f"(identity `{ident.get('subject')}`). Flux `spec.verify` will pass.")
        err = " ".join(proc.stderr.strip().splitlines()[-1:]) or f"exit {proc.returncode}"
        last_err = err
        if any(marker in err.lower() for marker in _UNSIGNED_MARKERS):
            unsigned = True
    if unsigned:
        return Result(target, "blocker", (
            f"`{target.name}` (`{target.path}`): **no valid cosign signature** for `{target.ref}` "
            f"matching the OCIRepository's `matchOIDCIdentity`. cosign: `{last_err}`. "
            f"Flux will fail this source with `VerificationError` and keep serving the previous "
            f"artifact. Do not merge until upstream signs this digest (check the upstream release "
            f"workflow run for a failed signing step)."
        ))
    return Result(target, "warning", (
        f"`{target.name}` (`{target.path}`): could not check the cosign signature for "
        f"`{target.ref}` ({last_err or 'time budget exhausted'}). Signature status is unknown; "
        f"this is not evidence that it is unsigned."
    ))


# --- main -------------------------------------------------------------------------

_SEVERITY_RANK = {"info": 0, "warning": 1, "blocker": 2}


def emit(findings: list[dict]) -> None:
    if not findings:
        findings = [{"severity": "info",
                     "message": "No changed OCIRepository with a `verify` block; nothing to check.",
                     "source": PROVIDER}]
    top = max((f["severity"] for f in findings), key=_SEVERITY_RANK.__getitem__)
    print(json.dumps({"severity": top, "findings": findings}, indent=2, ensure_ascii=False))


def main() -> int:
    repo = os.environ.get("REPO", "").strip()
    pr_number = os.environ.get("PR_NUMBER", "").strip()
    if not repo or not pr_number:
        emit([{"severity": "info", "message": "Missing REPO/PR_NUMBER environment; skipping.",
               "source": PROVIDER}])
        return 0

    pr = gh_json([f"repos/{repo}/pulls/{pr_number}"])
    head_sha = (pr or {}).get("head", {}).get("sha") if isinstance(pr, dict) else None
    files = gh_json([f"repos/{repo}/pulls/{pr_number}/files?per_page=100"])
    if not head_sha or not isinstance(files, list):
        emit([{"severity": "warning",
               "message": f"Could not fetch PR {repo}#{pr_number} via `gh api`; cosign signatures not checked.",
               "source": PROVIDER}])
        return 0

    targets, findings = collect_targets(repo, head_sha, files)
    if not targets:
        emit(findings)
        return 0

    if shutil.which("cosign") is None:
        findings.append({"severity": "warning",
                         "message": "`cosign` is not on PATH; signatures for changed OCIRepositories were not checked.",
                         "source": PROVIDER})
        emit(findings)
        return 0

    if len(targets) > MAX_TARGETS:
        findings.append({"severity": "warning",
                         "message": f"{len(targets)} signed OCIRepositories changed; only the first {MAX_TARGETS} were checked.",
                         "source": PROVIDER})
        targets = targets[:MAX_TARGETS]

    deadline = time.monotonic() + OVERALL_BUDGET_SEC
    with ThreadPoolExecutor(max_workers=MAX_PARALLEL) as pool:
        results = list(pool.map(lambda t: verify_target(t, deadline), targets))
    for r in results:
        findings.append({"severity": r.severity, "message": r.message, "source": r.target.file_url})
        sys.stderr.write(f"{PROVIDER}: {r.target.ref} -> {r.severity}\n")

    emit(findings)
    return 0


if __name__ == "__main__":
    sys.exit(main())
