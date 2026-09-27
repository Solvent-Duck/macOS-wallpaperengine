#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FIXTURE_ROOT = ROOT / "CompatibilitySuite" / "script_host_fixtures"
TOOL = ROOT / ".build" / "debug" / "ScriptHostFixtureTool"


def main() -> int:
    fixtures = sorted(path for path in FIXTURE_ROOT.iterdir() if path.is_dir())
    failures: list[str] = []

    for fixture in fixtures:
        expected = json.loads((fixture / "expected.json").read_text())
        output = subprocess.check_output([str(TOOL), str(fixture)], text=True)
        actual = json.loads(output)
        if actual != expected:
            failures.append(f"{fixture.name}: expected {expected}, got {actual}")

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1

    print(f"verified {len(fixtures)} script host fixtures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
