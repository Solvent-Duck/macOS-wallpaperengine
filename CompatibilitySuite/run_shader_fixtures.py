#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
from pathlib import Path


def run_fixture(tool_path: Path, fixture_dir: Path) -> str:
    result = subprocess.run(
        [str(tool_path), str(fixture_dir)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        stderr = result.stderr.strip() or "(no stderr)"
        raise RuntimeError(f"{fixture_dir.name}: ShaderFixtureTool failed: {stderr}")
    return result.stdout


def iter_fixture_dirs(root: Path) -> list[Path]:
    return sorted(
        path for path in root.iterdir() if path.is_dir() and (path / "fixture.json").exists()
    )


def normalize_json_text(raw: str) -> str:
    return json.dumps(json.loads(raw), indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify shader fixture snapshots")
    parser.add_argument(
        "--fixture-root",
        default=Path("CompatibilitySuite/shader_fixtures"),
        type=Path,
        help="Root directory containing shader fixtures",
    )
    parser.add_argument(
        "--tool",
        default=Path(".build/debug/ShaderFixtureTool"),
        type=Path,
        help="Path to the built ShaderFixtureTool executable",
    )
    args = parser.parse_args()

    fixture_root = args.fixture_root.resolve()
    tool_path = args.tool.resolve()

    if not tool_path.exists():
        print(f"missing tool: {tool_path}", file=sys.stderr)
        return 2

    failures: list[str] = []

    for fixture_dir in iter_fixture_dirs(fixture_root):
        expected_path = fixture_dir / "expected.json"
        if not expected_path.exists():
            failures.append(f"{fixture_dir.name}: missing expected.json")
            continue

        try:
            actual = normalize_json_text(run_fixture(tool_path, fixture_dir))
            expected = normalize_json_text(expected_path.read_text(encoding="utf-8"))
        except Exception as error:
            failures.append(str(error))
            continue

        if actual != expected:
            failures.append(f"{fixture_dir.name}: snapshot mismatch")

    if failures:
        print("shader fixture verification failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print(f"verified {len(iter_fixture_dirs(fixture_root))} shader fixtures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
