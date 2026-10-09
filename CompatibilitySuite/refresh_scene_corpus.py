#!/usr/bin/env python3
"""Rebuild full_scene_corpus.json from the scenes Steam has installed.

Every Workshop item whose project.json type is "scene" is included, except
Mature-rated items and the IDs below, which are excluded from all testing
(see docs/archive/DEVELOPMENT_HISTORY.md) even if Steam downloads them again.
Presets and video/web items are not scenes and stay out.

The corpus is a saved list rather than a live folder scan, so the regression
gate's baseline only changes when this script is run on purpose.
"""
import datetime
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "CompatibilitySuite" / "full_scene_corpus.json"
WORKSHOP = Path.home() / "Library/Application Support/Steam/steamapps/workshop/content/431960"
EXCLUDED_IDS = {"2114290843", "3340296712", "3626081043", "3626090712"}


def main() -> int:
    fixtures = []
    for item in sorted(WORKSHOP.iterdir()):
        project_file = item / "project.json"
        if item.name in EXCLUDED_IDS or not project_file.is_file():
            continue
        project = json.loads(project_file.read_text(encoding="utf-8-sig"))
        if str(project.get("type", "")).lower() != "scene":
            continue
        if str(project.get("contentrating", "")).lower() == "mature":
            continue
        fixtures.append({"id": item.name, "path": item.name, "type": "scene"})

    previous = {fixture["id"] for fixture in json.loads(CORPUS.read_text())["fixtures"]} if CORPUS.exists() else set()
    current = {fixture["id"] for fixture in fixtures}
    CORPUS.write_text(json.dumps({
        "generated_at": datetime.date.today().isoformat(),
        "corpus_root": str(WORKSHOP),
        "fixtures": fixtures,
    }, indent=1) + "\n")
    print(f"{len(fixtures)} scenes ({len(current - previous)} added, {len(previous - current)} removed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
