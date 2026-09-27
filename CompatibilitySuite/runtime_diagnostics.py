"""Report functional gaps separately from successful frame capture.

A scene with no recognized diagnostics is still unverified against Windows.
This can audit an existing run without changing its original smoke results.
"""

import argparse
from collections import Counter
import json
from pathlib import Path


EXCLUDED_FIXTURES = {"2114290843", "3340296712", "3626081043", "3626090712"}


def collect_runtime_diagnostics(stdout, stderr):
    lines = list(dict.fromkeys(line.strip() for line in (stdout + "\n" + stderr).splitlines()))
    return {
        "script_errors": [
            line for line in lines
            if line.startswith("[NativeSceneRuntime]")
            and ("evaluation failed:" in line or "callback failed:" in line or "Script destroy failed:" in line)
        ],
        "renderer_fallbacks": [
            line for line in lines
            if line.startswith("[MaterialBinder]")
            and ("fallback" in line or ("Unknown vertex attribute" in line and "zero-filling" in line))
        ],
        "skipped_layers": [line for line in lines if line.startswith("[NativeSceneRenderer] Skipping ")],
    }


def compatibility_evidence(report, diagnostics):
    support = report.get("native_support") or {}
    issues = report.get("status") != "pass" or any(diagnostics.values()) or support.get("parityStatus") in {"partial", "unsupported"}
    return {
        **diagnostics,
        "compatibility_status": "issues_detected" if issues else "unverified",
        "windows_parity_verified": False,
    }


def audit_run(run_dir):
    run_dir = Path(run_dir)
    fixtures = []
    for path in sorted(run_dir.glob("*/report.json")):
        # Exclusions apply before reading any fixture content.
        if path.parent.name in EXCLUDED_FIXTURES:
            continue
        report = json.loads(path.read_text())
        if str(report.get("fixture_id")) in EXCLUDED_FIXTURES:
            continue
        def read_log(name):
            log = path.parent / name
            return log.read_text(errors="replace") if log.is_file() else ""
        diagnostics = collect_runtime_diagnostics(read_log("stdout.log"), read_log("stderr.log"))
        fixtures.append({
            "fixture_id": report["fixture_id"],
            "render_status": report["status"],
            **compatibility_evidence(report, diagnostics),
        })
    return {
        "run_dir": str(run_dir.resolve()),
        "fixture_count": len(fixtures),
        "render_status_counts": dict(Counter(f["render_status"] for f in fixtures)),
        "fixtures_with_script_errors": sum(bool(f["script_errors"]) for f in fixtures),
        "fixtures_with_renderer_fallbacks": sum(bool(f["renderer_fallbacks"]) for f in fixtures),
        "fixtures_with_skipped_layers": sum(bool(f["skipped_layers"]) for f in fixtures),
        "windows_parity_verified": False,
        "fixtures": fixtures,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_dir", help="One existing run directory containing fixture report/log files")
    parser.add_argument("--output", required=True, help="Write a separate diagnostic audit JSON")
    args = parser.parse_args()
    report = audit_run(args.run_dir)
    Path(args.output).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "fixtures"}, indent=2))


if __name__ == "__main__":
    main()
