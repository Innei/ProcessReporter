#!/usr/bin/env python3
"""Update ProcessReporter marketing/build versions for a new release."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
MARKETING = re.compile(r"MARKETING_VERSION = ([^;]+);")
BUILD = re.compile(r"CURRENT_PROJECT_VERSION = ([^;]+);")


def fail(message: str) -> None:
    raise SystemExit(message)


def git(root: Path, *arguments: str) -> str:
    return subprocess.check_output(
        ["git", *arguments], cwd=root, text=True, stderr=subprocess.STDOUT
    ).strip()


def main() -> None:
    if len(sys.argv) != 2 or not SEMVER.fullmatch(sys.argv[1]):
        fail("usage: set-release-version.py X.Y.Z")

    version = sys.argv[1]
    root = Path(__file__).resolve().parents[4]
    project = root / "ProcessReporter.xcodeproj" / "project.pbxproj"
    if not project.is_file():
        fail(f"Xcode project not found at {project}")

    if git(root, "status", "--porcelain"):
        fail("working tree must be clean before preparing a release")
    if git(root, "branch", "--show-current") != "main":
        fail("release versions must be prepared from main")
    try:
        git(root, "fetch", "--prune", "--tags", "origin", "main")
    except subprocess.CalledProcessError:
        fail("could not refresh origin/main and remote tags")
    try:
        origin_main = git(root, "rev-parse", "--verify", "origin/main")
    except subprocess.CalledProcessError:
        fail("origin/main is unavailable; fetch origin before preparing a release")
    if git(root, "rev-parse", "HEAD") != origin_main:
        fail("main must exactly match origin/main before preparing a release")

    tag = f"v{version}"
    if subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}"], cwd=root
    ).returncode == 0:
        fail(f"tag already exists: {tag}")

    source = project.read_text(encoding="utf-8")
    marketing_values = MARKETING.findall(source)
    build_values = BUILD.findall(source)
    if not marketing_values or len(set(marketing_values)) != 1:
        fail("MARKETING_VERSION must have one consistent value in all configurations")
    if not build_values or len(set(build_values)) != 1 or not build_values[0].isdigit():
        fail("CURRENT_PROJECT_VERSION must have one consistent integer value")

    current = tuple(map(int, marketing_values[0].split(".")))
    requested = tuple(map(int, version.split(".")))
    if requested <= current:
        fail(f"new version {version} must be greater than current {marketing_values[0]}")

    next_build = int(build_values[0]) + 1
    updated = MARKETING.sub(f"MARKETING_VERSION = {version};", source)
    updated = BUILD.sub(f"CURRENT_PROJECT_VERSION = {next_build};", updated)
    project.write_text(updated, encoding="utf-8")

    print(f"MARKETING_VERSION: {marketing_values[0]} -> {version}")
    print(f"CURRENT_PROJECT_VERSION: {build_values[0]} -> {next_build}")
    print(f"Write release notes to .github/release-notes/{tag}.md")


if __name__ == "__main__":
    main()
