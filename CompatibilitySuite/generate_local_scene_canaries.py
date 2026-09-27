#!/usr/bin/env python3

import argparse
import importlib.util
import json
import random
from datetime import datetime, timezone
from pathlib import Path


def load_fixture_builder(script_path: Path):
    spec = importlib.util.spec_from_file_location("generate_fixtures", script_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.build_fixture


def collect_scene_projects(root: Path):
    projects = []
    for path in sorted(root.iterdir()):
        if not path.is_dir():
            continue
        project_path = path / "project.json"
        if not project_path.exists():
            continue
        try:
            project = json.loads(project_path.read_text())
        except Exception:
            continue
        if str(project.get("type", "")).lower() != "scene":
            continue
        projects.append(path)
    return projects


def build_canary_fixture(path: Path, build_fixture):
    fixture = build_fixture(path)
    fixture["type"] = str(fixture["type"]).lower()
    fixture["known_status"] = "untested"

    project = json.loads((path / "project.json").read_text())
    main_file = project.get("file", "")
    loose_scene_exists = bool(main_file) and (path / main_file).exists()
    scene_pkg_exists = (path / "scene.pkg").exists()
    gifscene_pkg_exists = (path / "gifscene.pkg").exists()

    notes = fixture["notes"]
    suffixes = []
    suffixes.append("Local Steam workshop scene canary selected with seed 431960.")
    suffixes.append(f"Main file: {main_file or 'unknown'}.")
    if scene_pkg_exists:
        suffixes.append("scene.pkg present.")
    if gifscene_pkg_exists:
        suffixes.append("gifscene.pkg present.")
    if not loose_scene_exists:
        suffixes.append("Loose scene JSON was not present at the project root.")

    if notes:
        notes = f"{notes} {' '.join(suffixes)}"
    else:
        notes = " ".join(suffixes)
    fixture["notes"] = notes
    return fixture


def main():
    parser = argparse.ArgumentParser(description="Generate a reproducible local scene-canary catalog from the Steam workshop corpus.")
    parser.add_argument(
        "--root",
        default=str(Path.home() / "Library" / "Application Support" / "Steam" / "steamapps" / "workshop" / "content" / "431960"),
        help="Wallpaper Engine Steam workshop root.",
    )
    parser.add_argument(
        "--output",
        default=str(Path(__file__).resolve().parent / "local_scene_canaries.json"),
        help="Output JSON path.",
    )
    parser.add_argument(
        "--sample-size",
        type=int,
        default=20,
        help="Number of scene projects to select.",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=431960,
        help="Random seed for reproducible selection.",
    )
    args = parser.parse_args()

    root = Path(args.root).expanduser().resolve()
    output = Path(args.output).resolve()
    build_fixture = load_fixture_builder(Path(__file__).resolve().parent / "generate_fixtures.py")

    scene_projects = collect_scene_projects(root)
    if len(scene_projects) < args.sample_size:
        raise SystemExit(f"Requested {args.sample_size} scene canaries, but only found {len(scene_projects)} scene projects in {root}")

    random.seed(args.seed)
    selected = sorted(random.sample(scene_projects, args.sample_size), key=lambda path: path.name)
    fixtures = [build_canary_fixture(path, build_fixture) for path in selected]

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "corpus_root": str(root),
        "fixtures": fixtures,
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
