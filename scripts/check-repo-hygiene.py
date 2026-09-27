#!/usr/bin/env python3
"""Reject generated files and missing authored files in the Git inventory."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
AUTHORED = ("Sources", "Tests", "CompatibilitySuite", "cmake", "patches", "scripts", ".github")


def generated(path):
    parts = Path(path).parts
    return (parts[0] in {"build", ".build", ".repo-backups"}
            or "__pycache__" in parts or ".pytest_cache" in parts
            or path.startswith("CompatibilitySuite/reports/")
            or Path(path).suffix in {".pyc", ".pyo", ".o", ".a"})


def main():
    def paths(*args):
        return subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", *args]).decode().split("\0")

    tracked = {p for p in paths() if p}
    errors = [f"generated file is tracked: {p}" for p in sorted(tracked) if generated(p)]
    errors += [f"authored file is untracked: {p}" for p in paths("--others", "--exclude-standard", "--", *AUTHORED) if p]
    for required in ("Package.swift", "build-bridge.sh", "run.sh", "cmake/dependencies/CMakeLists.txt",
                     "patches/quickjs-mapped-arguments-gc.patch"):
        if required not in tracked or not (ROOT / required).is_file():
            errors.append(f"required build input is missing from Git inventory: {required}")
    for directory in ("Sources", "Tests"):
        if not any(p.startswith(directory + "/") for p in tracked):
            errors.append(f"no {directory} files in Git inventory")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Repository inventory contains source/tests and no generated build artifacts.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
