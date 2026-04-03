#!/usr/bin/env python3

import argparse
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


FEATURE_ORDER = [
    "light",
    "audio",
    "text",
    "particle",
    "rtt",
    "video-texture",
    "script",
    "post-processing",
]

API_PATTERNS = {
    "createScriptProperties": re.compile(r"\bcreateScriptProperties\s*\("),
    "addSlider": re.compile(r"\baddSlider\s*\("),
    "addCheckbox": re.compile(r"\baddCheckbox\s*\("),
    "addCombo": re.compile(r"\baddCombo\s*\("),
    "addColor": re.compile(r"\baddColor\s*\("),
    "addText": re.compile(r"\baddText\s*\("),
    "finish": re.compile(r"\bfinish\s*\("),
    "update": re.compile(r"\bupdate\s*\("),
    "applyUserProperties": re.compile(r"\bapplyUserProperties\s*\("),
    "thisObject": re.compile(r"\bthisObject\b"),
    "thisScene": re.compile(r"\bthisScene\b"),
    "engine": re.compile(r"\bengine\.[A-Za-z_][A-Za-z0-9_]*"),
    "input": re.compile(r"\binput\.[A-Za-z_][A-Za-z0-9_]*"),
    "init": re.compile(r"\binit\s*\("),
    "destroy": re.compile(r"\bdestroy\s*\("),
}

TEXT_EXTENSIONS = {
    ".json",
    ".js",
    ".txt",
    ".frag",
    ".vert",
    ".glsl",
    ".vsh",
    ".fsh",
    ".fx",
    ".inc",
}

VIDEO_EXTENSIONS = {".mp4", ".mov", ".avi", ".webm", ".mkv", ".m4v"}


def iter_strings(value):
    if isinstance(value, dict):
        for child in value.values():
            yield from iter_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_strings(child)
    elif isinstance(value, str):
        yield value


def iter_scripts(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "script" and isinstance(child, str):
                yield child
            yield from iter_scripts(child)
    elif isinstance(value, list):
        for child in value:
            yield from iter_scripts(child)


def detect_script_apis(script_bodies):
    found = set()
    for body in script_bodies:
        for name, pattern in API_PATTERNS.items():
            if pattern.search(body):
                found.add(name)
    return sorted(found)


def detect_shader_includes(directory):
    includes = set()
    for path in directory.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in TEXT_EXTENSIONS:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        for match in re.finditer(r"#(?:include|require)\s+([^\s]+)", text):
            includes.add(match.group(1).strip("\"<>"))
    return sorted(includes)


def detect_object_type(obj):
    if "light" in obj:
        return "light"
    if "particle" in obj:
        return "particle"
    if "sound" in obj:
        return "sound"
    if "text" in obj:
        return "text"
    if "image" in obj:
        return "image"
    if "model" in obj:
        return "model"
    return "unknown"


def classify_category(project_type, counts, features):
    if "script" in features:
        return "script-heavy"
    if counts["text"] > 0:
        return "text-heavy"
    if counts["particle"] >= 2:
        return "particle-heavy"
    if "video-texture" in features or project_type == "video":
        return "video-scene"
    if "post-processing" in features or counts["shader_effects"] > 0:
        return "pathological-shader"
    if counts["objects"] <= 2 and len(features) <= 2:
        return "minimal"
    return "popular"


def build_fixture(project_dir):
    project_path = project_dir / "project.json"
    project = json.loads(project_path.read_text())
    project_type = project["type"]

    fixture = {
        "id": project_dir.name,
        "name": project.get("title", project_dir.name),
        "path": project_dir.name,
        "preview_path": project.get("preview"),
        "type": project_type,
        "category": "popular",
        "expected_features": [],
        "expected_script_apis": [],
        "expected_object_types": [],
        "shader_includes": detect_shader_includes(project_dir),
        "schema_version": project.get("version"),
        "known_status": "untested",
        "notes": "",
    }

    scene_path = project_dir / project["file"]
    counts = Counter()
    notes = []
    features = set()
    object_types = set()
    script_bodies = []

    if scene_path.exists() and scene_path.suffix.lower() == ".json":
        scene = json.loads(scene_path.read_text())
        objects = scene.get("objects", [])
        counts["objects"] = len(objects)
        counts["shader_effects"] = 0

        for obj in objects:
            object_type = detect_object_type(obj)
            object_types.add(object_type)
            counts[object_type] += 1

            if "effects" in obj:
                counts["shader_effects"] += len(obj.get("effects", []))
            if "particle" in obj:
                features.add("particle")
            if "text" in obj:
                features.add("text")
            if "light" in obj:
                features.add("light")
            if "sound" in obj:
                features.add("audio")
            if obj.get("copybackground") or any("target" in p for e in obj.get("effects", []) for p in e.get("passes", [])):
                features.add("rtt")

        general = scene.get("general", {})
        if general.get("bloom") or counts["shader_effects"] > 0:
            features.add("post-processing")

        script_bodies.extend(iter_scripts(scene))
        project_scripts = list(iter_scripts(project))
        script_bodies.extend(project_scripts)

        if script_bodies:
            features.add("script")
            notes.append(f"Detected {len(script_bodies)} inline script block(s).")

        string_pool = "\n".join(iter_strings(scene))
        if any(ext in string_pool.lower() for ext in VIDEO_EXTENSIONS):
            features.add("video-texture")

        if counts["light"] > 0:
            notes.append(f"Scene declares {counts['light']} light object(s).")
        if counts["particle"] > 0:
            notes.append(f"Scene declares {counts['particle']} particle object(s).")
        if counts["text"] > 0:
            notes.append(f"Scene declares {counts['text']} text object(s).")

    else:
        notes.append("No scene JSON was available for automated feature extraction.")

    js_files = sorted(project_dir.rglob("*.js"))
    for path in js_files:
        script_bodies.append(path.read_text(encoding="utf-8", errors="ignore"))

    if js_files:
        features.add("script")
        notes.append(f"Detected {len(js_files)} JavaScript file(s).")

    fixture["expected_script_apis"] = detect_script_apis(script_bodies)
    fixture["expected_object_types"] = sorted(t for t in object_types if t != "unknown")
    fixture["expected_features"] = [feature for feature in FEATURE_ORDER if feature in features]
    fixture["category"] = classify_category(project_type, counts, features)
    fixture["notes"] = " ".join(notes) if notes else "Auto-generated from project.json and scene assets."

    return fixture


def main():
    parser = argparse.ArgumentParser(description="Generate CompatibilitySuite fixture metadata.")
    parser.add_argument(
        "--root",
        default=str(Path.home() / "wallpaper_engine" / "test_wallpapers"),
        help="Wallpaper corpus root. Defaults to ~/wallpaper_engine/test_wallpapers",
    )
    parser.add_argument(
        "--output",
        default=str(Path(__file__).resolve().parent / "fixtures.json"),
        help="Output JSON path.",
    )
    args = parser.parse_args()

    root = Path(args.root).expanduser().resolve()
    output = Path(args.output).resolve()

    fixtures = []
    for project_path in sorted(root.glob("*/project.json")):
        fixtures.append(build_fixture(project_path.parent))

    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "corpus_root": str(root),
        "fixtures": fixtures,
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")


if __name__ == "__main__":
    main()
