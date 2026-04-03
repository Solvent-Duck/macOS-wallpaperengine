#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def load_fixtures(path):
    payload = json.loads(Path(path).read_text())
    return payload["corpus_root"], payload["fixtures"]


def run_fixture(binary, corpus_root, fixture, output_dir, frames, benchmark_duration, timeout_seconds):
    fixture_dir = Path(corpus_root) / fixture["path"]
    fixture_output_dir = output_dir / fixture["id"]
    fixture_output_dir.mkdir(parents=True, exist_ok=True)

    screenshot_path = fixture_output_dir / "screenshot.png"
    benchmark_path = fixture_output_dir / "benchmark.json"
    report_path = fixture_output_dir / "report.json"
    stdout_path = fixture_output_dir / "stdout.log"
    stderr_path = fixture_output_dir / "stderr.log"

    command = [
        str(binary),
        str(fixture_dir),
        "--screenshot",
        str(screenshot_path),
        "--benchmark",
        str(benchmark_path),
        "--frames",
        str(frames),
        "--benchmark-duration",
        str(benchmark_duration),
    ]

    started = time.perf_counter()
    errors = []

    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
        duration_ms = (time.perf_counter() - started) * 1000.0
        stdout_path.write_text(completed.stdout)
        stderr_path.write_text(completed.stderr)
    except subprocess.TimeoutExpired as exc:
        duration_ms = (time.perf_counter() - started) * 1000.0
        stdout_path.write_text(exc.stdout or "")
        stderr_path.write_text(exc.stderr or "")
        report = {
            "fixture_id": fixture["id"],
            "status": "crash",
            "launch_ok": False,
            "render_ok": False,
            "black_frame": None,
            "errors": [f"Timed out after {timeout_seconds}s"],
            "duration_ms": duration_ms,
            "command": command,
            "screenshot": None,
            "benchmark": None,
        }
        report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        return report

    launch_ok = completed.returncode == 0
    if not launch_ok:
        errors.append(f"Process exited with code {completed.returncode}")

    screenshot_exists = screenshot_path.exists()
    benchmark_exists = benchmark_path.exists()
    screenshot_report_path = screenshot_path.with_suffix(screenshot_path.suffix + ".json")
    screenshot_report = None
    if screenshot_report_path.exists():
        screenshot_report = json.loads(screenshot_report_path.read_text())

    black_frame = screenshot_report["black_frame"] if screenshot_report else None
    render_ok = screenshot_exists and black_frame is False

    if not screenshot_exists:
        errors.append("Screenshot output was not produced")
    if not benchmark_exists:
        errors.append("Benchmark output was not produced")
    if black_frame:
        errors.append("Captured frame was classified as black")

    status = "pass"
    if not launch_ok:
        status = "crash"
    elif black_frame:
        status = "fail"
    elif not render_ok or not benchmark_exists:
        status = "partial"

    benchmark_payload = json.loads(benchmark_path.read_text()) if benchmark_exists else None

    report = {
        "fixture_id": fixture["id"],
        "status": status,
        "launch_ok": launch_ok,
        "render_ok": render_ok,
        "black_frame": black_frame,
        "errors": errors,
        "duration_ms": duration_ms,
        "command": command,
        "screenshot": str(screenshot_path) if screenshot_exists else None,
        "screenshot_report": screenshot_report,
        "benchmark": benchmark_payload,
    }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def main():
    default_root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Run the compatibility harness over the fixture catalog.")
    parser.add_argument("--fixtures", default=str(default_root / "fixtures.json"))
    parser.add_argument("--binary", default=str(default_root.parent / ".build" / "debug" / "WallpaperEngine"))
    parser.add_argument("--reports-dir", default=str(default_root / "reports"))
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--benchmark-duration", type=float, default=5.0)
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--fixture", action="append", dest="fixture_ids")
    args = parser.parse_args()

    corpus_root, fixtures = load_fixtures(args.fixtures)
    if args.fixture_ids:
        wanted = set(args.fixture_ids)
        fixtures = [fixture for fixture in fixtures if fixture["id"] in wanted]

    run_id = datetime.now(timezone.utc).strftime("run_%Y-%m-%dT%H-%M-%SZ")
    reports_dir = Path(args.reports_dir)
    run_dir = reports_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    reports = []
    for fixture in fixtures:
        report = run_fixture(
            binary=Path(args.binary),
            corpus_root=corpus_root,
            fixture=fixture,
            output_dir=run_dir,
            frames=args.frames,
            benchmark_duration=args.benchmark_duration,
            timeout_seconds=args.timeout,
        )
        reports.append(report)
        print(f"{fixture['id']}: {report['status']}")

    summary = {
        "run_id": run_id,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "fixture_reports": reports,
    }
    summary_path = reports_dir / f"{run_id}.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(summary_path)

    return 0 if all(report["status"] == "pass" for report in reports) else 1


if __name__ == "__main__":
    sys.exit(main())
