#!/usr/bin/env python3

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

try:
    from .runtime_diagnostics import collect_runtime_diagnostics, compatibility_evidence
except ImportError:
    from runtime_diagnostics import collect_runtime_diagnostics, compatibility_evidence


def load_fixtures(path, corpus_root=None):
    catalog = Path(path).resolve()
    payload = json.loads(catalog.read_text())
    root = Path(corpus_root if corpus_root is not None else payload["corpus_root"]).expanduser()
    # Catalog-relative defaults travel with synthetic fixtures. Explicit CLI
    # overrides are relative to the caller's working directory.
    if not root.is_absolute() and corpus_root is None:
        root = catalog.parent / root
    return str(root.resolve()), payload["fixtures"]


def coerce_output(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def detect_observed_backend(stdout):
    if "[backend: native]" in stdout:
        return "native"
    if "[backend: bridge]" in stdout:
        return "bridge"
    return "unknown"


def detect_native_support(stdout):
    prefix = "[SceneRenderer] Native support report: "
    for line in stdout.splitlines():
        if line.startswith(prefix):
            payload = line[len(prefix):].strip()
            try:
                return json.loads(payload)
            except json.JSONDecodeError:
                return {"decode_error": payload}
    return None


def run_fixture(binary, corpus_root, fixture, output_dir, frames, benchmark_duration, timeout_seconds, backend):
    screenshot_time = fixture.get("screenshot_time", 0)
    if (isinstance(screenshot_time, bool) or not isinstance(screenshot_time, (int, float))
            or not math.isfinite(screenshot_time) or screenshot_time < 0):
        raise ValueError("screenshot_time must be a finite, nonnegative number of scene seconds")
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
    if screenshot_time > 0:
        command.extend(["--screenshot-time", str(screenshot_time)])

    started = time.perf_counter()
    errors = []
    warnings = []
    environment = os.environ.copy()

    try:
        # Scope native extraction explicitly; macOS Foundation can ignore
        # TMPDIR. Keep TMPDIR scoped for other subprocess temporary files.
        # Even failed/timed-out runs release this directory; screenshots,
        # benchmarks, and logs remain in the persistent report directory.
        with tempfile.TemporaryDirectory(prefix="WECompatibility-") as temporary_root:
            environment["TMPDIR"] = temporary_root + os.sep
            environment["WE_PACKAGE_TEMP_DIR"] = temporary_root
            completed = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
                check=False,
                env=environment,
            )
        duration_ms = (time.perf_counter() - started) * 1000.0
        stdout_path.write_text(completed.stdout)
        stderr_path.write_text(completed.stderr)
    except subprocess.TimeoutExpired as exc:
        duration_ms = (time.perf_counter() - started) * 1000.0
        stdout_path.write_text(coerce_output(exc.stdout))
        stderr_path.write_text(coerce_output(exc.stderr))
        report = {
            "fixture_id": fixture["id"],
            "status": "timeout",
            "launch_ok": False,
            "render_ok": False,
            "black_frame": None,
            "errors": [f"Timed out after {timeout_seconds}s"],
            "duration_ms": duration_ms,
            "command": command,
            "runtime_mode": "native",
            "observed_backend": detect_observed_backend(coerce_output(exc.stdout)),
            "screenshot": None,
            "benchmark": None,
        }
        report.update(compatibility_evidence(report, collect_runtime_diagnostics(coerce_output(exc.stdout), coerce_output(exc.stderr))))
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

    observed_backend = detect_observed_backend(completed.stdout)
    native_support = detect_native_support(completed.stdout)
    black_frame = screenshot_report["black_frame"] if screenshot_report else None
    flat_frame = screenshot_report.get("flat_frame") if screenshot_report else None
    animation_delta = screenshot_report.get("animation_delta") if screenshot_report else None
    skipped_layers = list(dict.fromkeys(
        line.strip() for line in (completed.stdout + "\n" + completed.stderr).splitlines()
        if "[NativeSceneRenderer] Skipping " in line
    ))
    errors.extend(skipped_layers)
    render_ok = screenshot_exists and black_frame is False and flat_frame is not True and not skipped_layers

    if not screenshot_exists:
        errors.append("Screenshot output was not produced")
    if not benchmark_exists:
        errors.append("Benchmark output was not produced")
    if black_frame:
        errors.append("Captured frame was classified as black")
    if flat_frame:
        errors.append("Captured frame is a single flat color")
    if animation_delta is not None and animation_delta < 0.02:
        warnings.append(
            f"No frame-to-frame motion detected (animation_delta={animation_delta:.4f})"
        )
    if launch_ok and observed_backend != "native":
        errors.append(f"Expected native runtime, observed {observed_backend}")

    if native_support:
        parity_status = native_support.get("parityStatus")
        placeholder_subsystems = native_support.get("placeholderSubsystems") or []
        if parity_status == "partial":
            warnings.append(
                "Native renderer used placeholder subsystems: "
                + ", ".join(placeholder_subsystems)
            )
        elif parity_status == "unsupported":
            errors.append(native_support.get("reason") or "Native renderer reported unsupported scene")

    status = "pass"
    if not launch_ok:
        status = "crash"
    elif black_frame or flat_frame or skipped_layers:
        status = "fail"
    elif not render_ok or not benchmark_exists:
        status = "partial"
    elif errors:
        status = "partial"
    elif native_support and native_support.get("parityStatus") == "partial":
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
        "runtime_mode": "native",
        "observed_backend": observed_backend,
        "screenshot": str(screenshot_path) if screenshot_exists else None,
        "screenshot_report": screenshot_report,
        "benchmark": benchmark_payload,
        "warnings": warnings,
        "native_support": native_support,
    }
    report.update(compatibility_evidence(report, collect_runtime_diagnostics(completed.stdout, completed.stderr)))
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return report


def main():
    default_root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Run the compatibility harness over the fixture catalog.")
    parser.add_argument("--fixtures", default=str(default_root / "fixtures.json"))
    parser.add_argument("--corpus-root", help="Override the catalog's wallpaper root")
    parser.add_argument("--binary", default=str(default_root.parent / ".build" / "debug" / "WallpaperEngine"))
    parser.add_argument("--reports-dir", default=str(default_root / "reports"))
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--benchmark-duration", type=float, default=5.0)
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--fixture", action="append", dest="fixture_ids")
    parser.add_argument(
        "--backend",
        choices=("native",),
        default="native",
        help="The app runtime is native-only as of the Phase 8 cutover."
    )
    args = parser.parse_args()

    corpus_root, fixtures = load_fixtures(args.fixtures, args.corpus_root)
    if args.fixture_ids:
        wanted = set(args.fixture_ids)
        fixtures = [fixture for fixture in fixtures if fixture["id"] in wanted]

    run_id = f"{datetime.now(timezone.utc).strftime('run_%Y-%m-%dT%H-%M-%S-%fZ')}_{uuid4().hex[:8]}"
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
            backend=args.backend,
        )
        reports.append(report)
        print(
            f"{fixture['id']}: {report['status']} "
            f"(runtime={report['runtime_mode']}, observed={report['observed_backend']})"
        )

    summary = {
        "run_id": run_id,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "runtime_mode": "native",
        "fixture_reports": reports,
    }
    summary_path = reports_dir / f"{run_id}.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(summary_path)

    return 0 if all(report["status"] == "pass" for report in reports) else 1


if __name__ == "__main__":
    sys.exit(main())
