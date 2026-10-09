#!/usr/bin/env python3
"""Render every corpus scene headless with a pinned clock and hash the output.

Use it as a regression gate: record a baseline, change the renderer, record
again with --compare. With WE_DETERMINISTIC and TZ=UTC set, an unchanged
renderer reproduces every hash, so any mismatch is a real behaviour change.

    swift build -c release --product SceneNativeSnapshotTool
    CompatibilitySuite/run_headless_corpus.py --label before
    # ...change code, rebuild...
    CompatibilitySuite/run_headless_corpus.py --label after \
        --compare CompatibilitySuite/reports/headless/before.json

Mismatched scenes keep their PNGs when --keep-images is given.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "CompatibilitySuite" / "full_scene_corpus.json"
TOOL = ROOT / ".build" / "release" / "SceneNativeSnapshotTool"
REPORTS = ROOT / "CompatibilitySuite" / "reports" / "headless"
ASSETS = Path.home() / "wallpaper_engine" / "assets"


def render(scene_id: str, args: argparse.Namespace, corpus_root: Path) -> dict:
    # Package extraction rejects the resolved /private/tmp form, so keep /tmp.
    work = tempfile.mkdtemp(prefix="we-headless-", dir="/tmp")
    output = Path(work) / "frame.png"
    env = dict(os.environ, WE_DETERMINISTIC="1", TZ="UTC", TMPDIR=work + "/", WE_PACKAGE_TEMP_DIR=work)
    command = [str(args.tool), str(corpus_root / scene_id), str(args.assets), str(output),
               "--frames", str(args.frames), "--delta-time", str(args.delta_time)]
    started = time.monotonic()
    try:
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=args.timeout)
        status = "ok" if result.returncode == 0 and output.exists() else f"exit {result.returncode}"
        detail = "" if status == "ok" else result.stderr.strip()[-400:]
    except subprocess.TimeoutExpired:
        status, detail = "timeout", ""
    record = {"status": status, "seconds": round(time.monotonic() - started, 2)}
    if detail:
        record["detail"] = detail
    if status == "ok":
        record["sha256"] = hashlib.sha256(output.read_bytes()).hexdigest()
        if args.keep_images:
            args.keep_images.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(output, args.keep_images / f"{scene_id}.png")
    shutil.rmtree(work, ignore_errors=True)
    return record


def compare(current: dict, baseline: dict) -> int:
    changed, broke, fixed = [], [], []
    for scene_id, record in current.items():
        before = baseline.get(scene_id)
        if before is None:
            continue
        if before["status"] == "ok" and record["status"] != "ok":
            broke.append(f"{scene_id} ({record['status']})")
        elif before["status"] != "ok" and record["status"] == "ok":
            fixed.append(scene_id)
        elif record.get("sha256") != before.get("sha256"):
            changed.append(scene_id)
    print(f"compared {len(current)} scenes: {len(changed)} changed, {len(broke)} newly failing, {len(fixed)} newly passing")
    for label, items in (("changed", changed), ("newly failing", broke), ("newly passing", fixed)):
        if items:
            print(f"{label}: {' '.join(items)}")
    return 1 if changed or broke else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--label", required=True, help="report name under CompatibilitySuite/reports/headless/")
    parser.add_argument("--compare", type=Path, help="baseline report to diff against")
    parser.add_argument("--scenes", nargs="*", help="subset of scene IDs (default: whole corpus)")
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--delta-time", type=float, default=1 / 30)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--tool", type=Path, default=TOOL)
    parser.add_argument("--assets", type=Path, default=ASSETS)
    parser.add_argument("--keep-images", type=Path, help="directory to copy rendered PNGs into")
    args = parser.parse_args()

    corpus = json.loads(CORPUS.read_text())
    corpus_root = Path(corpus["corpus_root"])
    scene_ids = args.scenes or [fixture["path"] for fixture in corpus["fixtures"]]

    results: dict[str, dict] = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {scene_id: pool.submit(render, scene_id, args, corpus_root) for scene_id in scene_ids}
        for index, (scene_id, future) in enumerate(futures.items(), 1):
            results[scene_id] = future.result()
            if index % 25 == 0 or index == len(futures):
                print(f"{index}/{len(futures)} rendered", file=sys.stderr, flush=True)

    REPORTS.mkdir(parents=True, exist_ok=True)
    report_path = REPORTS / f"{args.label}.json"
    report_path.write_text(json.dumps({
        "frames": args.frames, "delta_time": args.delta_time, "tool": str(args.tool), "scenes": results,
    }, indent=1, sort_keys=True))
    failures = sum(1 for record in results.values() if record["status"] != "ok")
    print(f"wrote {report_path} ({len(results) - failures} rendered, {failures} failed)")

    if args.compare:
        return compare(results, json.loads(args.compare.read_text())["scenes"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
