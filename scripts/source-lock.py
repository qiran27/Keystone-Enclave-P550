#!/usr/bin/env python3
"""Fetch and verify source repositories pinned by sources.lock.yml."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import yaml


PROJECT_DIR = Path(__file__).resolve().parent.parent
SOURCES_DIR = PROJECT_DIR / "sources"
LOCK_FILE = PROJECT_DIR / "sources.lock.yml"


def run(args: list[str], *, cwd: Path | None = None, capture: bool = False) -> str:
    result = subprocess.run(
        args,
        cwd=cwd,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    return result.stdout.strip() if capture else ""


def git(repo: Path, *args: str, capture: bool = False) -> str:
    return run(["git", "-C", str(repo), *args], capture=capture)


def load_components() -> dict[str, dict[str, object]]:
    with LOCK_FILE.open("r", encoding="utf-8") as stream:
        document = yaml.safe_load(stream)
    if document.get("format") != 1 or not isinstance(document.get("components"), dict):
        raise RuntimeError(f"Unsupported or invalid source lock file: {LOCK_FILE}")
    return document["components"]


def directory_for(name: str, spec: dict[str, object]) -> str:
    return str(spec.get("directory", name))


def ensure_origin(repo: Path, expected_url: str) -> None:
    try:
        actual_url = git(repo, "remote", "get-url", "origin", capture=True)
    except subprocess.CalledProcessError as error:
        raise RuntimeError(f"{repo}: missing origin remote") from error

    def canonical(url: str) -> str:
        return url.rstrip("/").removesuffix(".git")

    if canonical(actual_url) != canonical(expected_url):
        raise RuntimeError(
            f"{repo}: origin URL mismatch\n"
            f"  expected: {expected_url}\n"
            f"  actual:   {actual_url}"
        )


def ensure_commit(repo: Path, revision: str) -> None:
    try:
        git(repo, "cat-file", "-e", f"{revision}^{{commit}}")
        return
    except subprocess.CalledProcessError:
        pass

    try:
        git(repo, "fetch", "--depth", "1", "origin", revision)
    except subprocess.CalledProcessError:
        git(repo, "fetch", "origin", revision)
    git(repo, "cat-file", "-e", f"{revision}^{{commit}}")


def repository_is_dirty(repo: Path) -> bool:
    return bool(git(repo, "status", "--porcelain", capture=True))


def fetch_sources(include_optional: bool) -> int:
    components = load_components()
    SOURCES_DIR.mkdir(parents=True, exist_ok=True)
    initialized: set[str] = set()

    for name, raw_spec in components.items():
        spec = dict(raw_spec)
        if spec.get("required", True) is False and not include_optional:
            print(f"OPTIONAL {name:<28} skipped")
            continue

        directory = directory_for(name, spec)
        repo = SOURCES_DIR / directory
        url = str(spec["url"])
        revision = str(spec["revision"])
        local_ref = spec.get("local_ref")

        if directory not in initialized:
            if not (repo / ".git").exists():
                if repo.exists() and any(repo.iterdir()):
                    raise RuntimeError(f"Refusing to replace non-repository directory: {repo}")
                repo.mkdir(parents=True, exist_ok=True)
                run(["git", "init", str(repo)])
                git(repo, "remote", "add", "origin", url)
            ensure_origin(repo, url)
            git(repo, "config", "core.symlinks", "true")
            git(repo, "config", "core.fileMode", "true")
            initialized.add(directory)

        ensure_commit(repo, revision)

        if local_ref:
            git(repo, "update-ref", f"refs/heads/{local_ref}", revision)
            print(f"PIN      {name:<28} {revision} -> {local_ref}")
            continue

        try:
            head = git(repo, "rev-parse", "HEAD", capture=True)
        except subprocess.CalledProcessError:
            head = ""
        if head != revision:
            if head and repository_is_dirty(repo):
                raise RuntimeError(
                    f"{repo}: working tree is dirty; refusing to switch to {revision}"
                )
            git(repo, "checkout", "--detach", revision)
        print(f"FETCHED  {name:<28} {revision}")

    return verify_sources()


def verify_sources() -> int:
    components = load_components()
    failures = 0

    for name, raw_spec in components.items():
        spec = dict(raw_spec)
        directory = directory_for(name, spec)
        repo = SOURCES_DIR / directory
        expected = str(spec["revision"])
        local_ref = spec.get("local_ref")
        required = spec.get("required", True) is not False

        if not (repo / ".git").exists():
            status = "MISSING" if required else "OPTIONAL"
            print(f"{status:<8} {name:<28} {repo}")
            failures += int(required)
            continue

        ref = str(local_ref) if local_ref else "HEAD"
        try:
            actual = git(repo, "rev-parse", ref, capture=True)
        except subprocess.CalledProcessError:
            actual = "missing"

        if actual == expected:
            print(f"OK       {name:<28} {actual}")
        else:
            print(f"MISMATCH {name:<28} expected={expected} actual={actual}")
            failures += int(required)

    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    fetch_parser = subparsers.add_parser("fetch", help="fetch and pin missing sources")
    fetch_parser.add_argument(
        "--include-optional",
        action="store_true",
        help="also fetch reference-only repositories",
    )
    subparsers.add_parser("verify", help="verify pinned source revisions")
    args = parser.parse_args()

    try:
        if args.command == "fetch":
            return fetch_sources(args.include_optional)
        return verify_sources()
    except (KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
