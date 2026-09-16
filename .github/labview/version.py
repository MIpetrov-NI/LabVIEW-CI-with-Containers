#!/usr/bin/env python3
"""Derive the next LabVIEW CI version from the published tags and write the catalog.

The catalog version is the version of record: the release workflow reads it to cut
the tag and force-move the v<major> alias every client pins to. It used to be
hand-edited on feature branches, which is how it was silently rolled back from
4.12.4 to 4.11.10 on 2026-07-30 (e9cd54b): a stale copy overwrote a newer one, the
file stayed internally consistent so nothing complained, and every client release
stalled for two weeks behind a tag that already existed.

So nothing here derives the next version from the file. The published tags are the
only source of truth -- whatever the catalog currently says, the next version is
always above every v<MAJOR>.<MINOR>.<PATCH> tag that exists. A stale, regressed or
conflicted catalog therefore cannot produce a colliding or backwards version; the
worst it can do is lose a release note, which is visible and recoverable.

Release notes come from fragment files under .github/labview-ci/notes/ (one per
pull request, so two PRs can never conflict in the same file). `apply` folds them
into a single history entry and prints the fragments it consumed so the caller can
delete them.

Usage:
    version.py next  --bump minor
    version.py apply --bump minor [--date YYYY-MM-DD] [--fallback-note "..."]
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / ".github" / "labview-ci" / "catalog.json"
NOTES_DIR = ROOT / ".github" / "labview-ci" / "notes"

SEMVER_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
LEVELS = ("major", "minor", "patch")


def die(message: str) -> "None":
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def published_versions() -> list[tuple[int, int, int]]:
    """Every released version, read from the tags rather than from the catalog."""
    try:
        out = subprocess.run(
            ["git", "tag", "--list", "v*.*.*"],
            cwd=ROOT, capture_output=True, text=True, timeout=30, check=True,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        die(f"could not read git tags ({exc}); check out with fetch-depth: 0")
    found = []
    for line in out.stdout.splitlines():
        match = SEMVER_TAG.match(line.strip())
        if match:
            found.append((int(match[1]), int(match[2]), int(match[3])))
    return found


def next_version(bump: str) -> str:
    versions = published_versions()
    if not versions:
        die("no v<MAJOR>.<MINOR>.<PATCH> tags found; refusing to guess a starting version")
    major, minor, patch = max(versions)
    if bump == "major":
        return f"{major + 1}.0.0"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def read_fragments() -> tuple[list[Path], str]:
    """Collect release-note fragments, oldest filename first for a stable order."""
    if not NOTES_DIR.is_dir():
        return [], ""
    paths = sorted(p for p in NOTES_DIR.iterdir() if p.suffix.lower() == ".md" and p.name != "README.md")
    chunks = []
    used = []
    for path in paths:
        text = " ".join(path.read_text(encoding="utf-8").split()).strip()
        if not text:
            continue
        chunks.append(text if text.endswith((".", "!", "?")) else text + ".")
        used.append(path)
    return used, " ".join(chunks)


def write_catalog(version: str, date: str, notes: str) -> None:
    """Surgically edit the catalog text.

    Deliberately NOT json.dump: the file stores each release as one compact line,
    and re-serialising reflows all 417 of them into a 4,000-line diff that buries
    the actual change and conflicts with every other branch. Two targeted string
    edits keep the diff to the two lines that really changed.
    """
    text = CATALOG.read_text(encoding="utf-8")
    catalog = json.loads(text)

    current = str(catalog.get("version", ""))
    old_line = f'\n  "version": "{current}",\n'
    if text.count(old_line) != 1:
        die(f'could not locate a unique top-level "version": "{current}" line in the catalog')
    text = text.replace(old_line, f'\n  "version": "{version}",\n')

    entry = "      " + json.dumps(
        {"version": version, "date": date, "notes": notes}, ensure_ascii=False
    ) + ",\n"
    anchor = '    "releases": [\n'
    if text.count(anchor) != 1:
        die('could not locate a unique history.releases array in the catalog')
    index = text.index(anchor) + len(anchor)
    text = text[:index] + entry + text[index:]

    # Prove the result before it lands: valid JSON, and the invariant the
    # validator and the release workflow both depend on.
    parsed = json.loads(text)
    releases = (parsed.get("history") or {}).get("releases") or []
    if parsed.get("version") != version:
        die("post-write check failed: top-level version did not update")
    if not releases or releases[0].get("version") != version:
        die("post-write check failed: history.releases[0] is not the new version")

    CATALOG.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p_next = sub.add_parser("next", help="print the next version derived from the tags")
    p_next.add_argument("--bump", choices=LEVELS, default="patch")

    p_apply = sub.add_parser("apply", help="write the next version + release notes into the catalog")
    p_apply.add_argument("--bump", choices=LEVELS, default="patch")
    p_apply.add_argument("--date", default="")
    p_apply.add_argument("--fallback-note", default="")

    args = parser.parse_args()
    version = next_version(args.bump)

    if args.command == "next":
        print(version)
        return 0

    used, notes = read_fragments()
    if not notes:
        notes = " ".join((args.fallback_note or "").split()).strip()
    if not notes:
        die(
            "no release note: add a fragment under .github/labview-ci/notes/ "
            "or pass --fallback-note"
        )

    date = args.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    write_catalog(version, date, notes)

    print(f"version={version}")
    print(f"consumed={len(used)}")
    for path in used:
        print(f"fragment={path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
