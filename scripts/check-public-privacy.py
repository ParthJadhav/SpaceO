#!/usr/bin/env python3
"""Reject common personal data in tracked files without printing matched values."""

import re
import subprocess
from pathlib import Path


def findings(path: str, text: str) -> list[tuple[int, str]]:
    results = []
    fixture_users = {"test", "me", "o", "x", "a&b", "a&amp;b"}
    for number, line in enumerate(text.splitlines(), 1):
        for match in re.finditer(r"/Users" + r"/([^/\s\"']+)", line):
            user = match[1]
            if user == "you" or (path.startswith("Tests/") and user in fixture_users):
                continue
            results.append((number, "personal home path"))
        for match in re.finditer(r"[\w.+-]+@([\w.-]+\.[A-Za-z]{2,})", line):
            domain = match[1].lower()
            if domain in {"example.com", "example.org", "example.net", "2x.png", "3x.png"}:
                continue
            if domain == "users.noreply.github.com":
                continue
            results.append((number, "non-example email address"))
        for match in re.finditer(r"Developer ID Application: ([^\n\"']+) \([A-Z0-9_]+\)", line):
            if match[1] not in {"Example", "Example Corp", "Test", "YOUR SIGNING NAME"}:
                results.append((number, "personal signing identity"))
    return sorted(set(results))


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    rejected = False
    private_suffixes = {".p12", ".p8", ".pfx", ".pem", ".key", ".keychain-db",
                        ".keychain", ".mobileprovision", ".provisionprofile"}
    for name in filter(None, paths):
        path = root / name
        if (Path(name).suffix in private_suffixes or Path(name).name == ".env"
                or Path(name).name.startswith(".env.") or name.startswith((".artifacts/", ".release/"))):
            print(f"{name}: private file must not be tracked")
            rejected = True
        # Git publishes the link target itself. Inspect it even for dangling links, but never
        # follow the link into user data.
        if path.is_symlink():
            text = str(path.readlink())
        else:
            if not path.exists():
                continue
            if path.stat().st_size > 16 * 1024 * 1024:
                print(f"{name}: exceeds automatic privacy-review size limit")
                rejected = True
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue  # Binary assets require visual/metadata review.
        for line, kind in findings(name, text):
            print(f"{name}:{line}: {kind} (value withheld)")
            rejected = True
    if not rejected:
        print("Public-file privacy check passed. Credential scanning remains a separate check.")
    return int(rejected)


if __name__ == "__main__":
    raise SystemExit(main())
