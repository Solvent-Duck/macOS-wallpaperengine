#!/usr/bin/env python3
import argparse
import json
import re
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CORPUS_ROOT = Path(
    os.environ.get(
        "WE_SCRIPT_COMPAT_CORPUS",
        str(Path.home() / "wallpaper_engine" / "test_wallpapers"),
    )
)
OUTPUT_PATH = ROOT / "CompatibilitySuite" / "reports" / "script_compatibility.json"

SUPPORTED_APIS = {
    "createScriptProperties": "supported",
    "addSlider": "supported",
    "addCheckbox": "supported",
    "addCombo": "supported",
    "addColor": "supported",
    "addText": "supported",
    "finish": "supported",
    "update": "supported",
    "applyUserProperties": "supported",
    "thisObject": "supported",
    "init": "supported",
    "destroy": "supported",
}

UNSUPPORTED_APIS = {}


def extract_scripts(text: str) -> list[str]:
    return re.findall(r'"script"\s*:\s*"((?:\\.|[^"])*)"', text)


def detect_apis(script: str) -> list[str]:
    candidates = sorted(set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", script)))
    interesting = [name for name in candidates if name in SUPPORTED_APIS or name in UNSUPPORTED_APIS]
    return interesting


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a script API coverage report for a wallpaper corpus.")
    parser.add_argument(
        "--corpus-root",
        default=DEFAULT_CORPUS_ROOT,
        type=Path,
        help="Root directory containing wallpaper projects to inspect",
    )
    parser.add_argument(
        "--output",
        default=OUTPUT_PATH,
        type=Path,
        help="Destination JSON report path",
    )
    args = parser.parse_args()

    corpus_root = args.corpus_root.resolve()
    output_path = args.output.resolve()

    output_path.parent.mkdir(parents=True, exist_ok=True)

    wallpapers = []
    total_api_refs = 0
    supported_api_refs = 0

    for project_json in sorted(corpus_root.glob("*/project.json")):
        wallpaper_dir = project_json.parent
        scene_json = wallpaper_dir / "scene.json"
        if not scene_json.exists():
            continue

        scripts = extract_scripts(scene_json.read_text())
        if not scripts:
            continue

        entries = []
        for index, script in enumerate(scripts):
            apis = detect_apis(bytes(script, "utf-8").decode("unicode_escape"))
            api_status = {}
            for api in apis:
                status = SUPPORTED_APIS.get(api) or UNSUPPORTED_APIS.get(api) or "unknown"
                api_status[api] = status
                total_api_refs += 1
                if status == "supported":
                    supported_api_refs += 1

            entries.append(
                {
                    "index": index,
                    "apis": api_status,
                    "supported": all(status == "supported" for status in api_status.values()) and bool(api_status),
                }
            )

        wallpapers.append(
            {
                "wallpaper": wallpaper_dir.name,
                "path": str(wallpaper_dir),
                "scripts": entries,
            }
        )

    report = {
        "generated_at": "2026-04-04",
        "corpus_root": str(corpus_root),
        "supported_apis": sorted(SUPPORTED_APIS.keys()),
        "unsupported_apis": UNSUPPORTED_APIS,
        "wallpapers": wallpapers,
        "coverage": {
            "api_reference_count": total_api_refs,
            "supported_api_reference_count": supported_api_refs,
            "coverage_ratio": (supported_api_refs / total_api_refs) if total_api_refs else 1.0,
        },
    }

    output_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
