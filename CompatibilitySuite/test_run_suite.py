import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from subprocess import CompletedProcess, TimeoutExpired
import subprocess
from contextlib import nullcontext

from CompatibilitySuite.run_suite import load_fixtures, run_fixture


class FixtureRootTests(unittest.TestCase):
    def test_catalog_relative_root_is_independent_of_working_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            catalog = Path(directory) / "fixtures.json"
            catalog.write_text(json.dumps({"corpus_root": "assets", "fixtures": []}))
            root, fixtures = load_fixtures(catalog)
            self.assertEqual(Path(root), catalog.parent.resolve() / "assets")
            self.assertEqual(fixtures, [])

    def test_override_and_home_expansion(self):
        with tempfile.TemporaryDirectory() as directory:
            catalog = Path(directory) / "fixtures.json"
            catalog.write_text(json.dumps({"corpus_root": "/old/machine", "fixtures": []}))
            self.assertEqual(load_fixtures(catalog)[0], "/old/machine")
            self.assertEqual(load_fixtures(catalog, "~/workshop")[0], str(Path.home() / "workshop"))
            self.assertEqual(load_fixtures(catalog, "workshop")[0], str(Path.cwd() / "workshop"))


class FixtureTemporaryStorageTests(unittest.TestCase):
    def test_capture_time_is_forwarded_without_exempting_black_frames(self):
        for seconds, black in [(None, False), (0, False), (7, False), (7.5, True)]:
            with self.subTest(seconds=seconds, black=black), tempfile.TemporaryDirectory() as root:
                fixture = {"id": "intro", "path": "intro"}
                if seconds is not None:
                    fixture["screenshot_time"] = seconds

                def renderer(command, **kwargs):
                    if seconds:
                        self.assertEqual(command[command.index("--screenshot-time") + 1], str(seconds))
                    else:
                        self.assertNotIn("--screenshot-time", command)
                    output = Path(command[command.index("--screenshot") + 1])
                    output.write_bytes(b"capture")
                    output.with_suffix(".png.json").write_text(json.dumps({"black_frame": black, "flat_frame": False}))
                    Path(command[command.index("--benchmark") + 1]).write_text("{}")
                    return CompletedProcess(command, 0, stdout="[backend: native]\n", stderr="")

                with patch("CompatibilitySuite.run_suite.subprocess.run", side_effect=renderer):
                    report = run_fixture("renderer", root, fixture, Path(root) / "reports", 2, 0.1, 30, "native")
                self.assertEqual(report["status"], "fail" if black else "pass")
                self.assertEqual(report["black_frame"], black)
                if black:
                    self.assertIn("Captured frame was classified as black", report["errors"])

    def test_invalid_capture_time_is_rejected_before_launch(self):
        for value in [-1, float("nan"), float("inf"), "7", True]:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as root:
                with patch("CompatibilitySuite.run_suite.subprocess.run") as run:
                    with self.assertRaisesRegex(ValueError, "finite, nonnegative"):
                        run_fixture("renderer", root, {"id": "intro", "path": "intro", "screenshot_time": value},
                                    Path(root) / "reports", 2, 0.1, 30, "native")
                    run.assert_not_called()

    def test_timeout_before_renderer_startup_removes_temporary_storage(self):
        with tempfile.TemporaryDirectory() as root:
            temporary = None
            def never_started(command, **kwargs):
                nonlocal temporary
                temporary = Path(kwargs["env"]["WE_PACKAGE_TEMP_DIR"])
                self.assertTrue(temporary.exists())
                raise TimeoutExpired(command, kwargs["timeout"])

            with patch("CompatibilitySuite.run_suite.subprocess.run", side_effect=never_started):
                report = run_fixture("renderer", root, {"id": "startup", "path": "startup"},
                                     Path(root) / "reports", 1, 0.1, 1, "native")
            self.assertFalse(temporary.exists())
            self.assertEqual(report["status"], "timeout")
            self.assertEqual(report["observed_backend"], "unknown")
            self.assertEqual((Path(root) / "reports/startup/stdout.log").read_text(), "")
            self.assertEqual((Path(root) / "reports/startup/stderr.log").read_text(), "")

    def test_extractions_are_removed_after_success_failure_and_timeout(self):
        for mode, expected_status in [("success", "pass"), ("failure", "crash"), ("timeout", "timeout"), ("skipped", "fail")]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                unrelated = root / "keep.txt"
                unrelated.write_text("unrelated data")
                executable = root / "fixture-renderer"
                executable.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
mode = pathlib.Path(sys.argv[1]).name
output = pathlib.Path(sys.argv[sys.argv.index('--screenshot') + 1])
temporary = pathlib.Path(os.environ['WE_PACKAGE_TEMP_DIR'])
(temporary / 'NativeScenePkg-fixture').mkdir()
(temporary / 'NativeScenePkg-fixture' / 'asset.json').write_text('{}')
(output.parent / 'temp-root.txt').write_text(str(temporary))
print('[backend: native]', flush=True)
if mode == 'skipped':
    print('[NativeSceneRenderer] Skipping image node 2: failed shader')
    print('[NativeSceneRenderer] Skipping image node 2: failed shader', file=sys.stderr)
if mode == 'failure': sys.exit(7)
output.write_bytes(b'fixture capture')
output.with_suffix('.png.json').write_text(json.dumps({'black_frame': False, 'flat_frame': False}))
pathlib.Path(sys.argv[sys.argv.index('--benchmark') + 1]).write_text('{}')
""")
                executable.chmod(0o755)
                original_tmp = os.environ.get("TMPDIR")
                real_run = subprocess.run
                def timed_out_after_startup(command, **kwargs):
                    # Let the fixture create its extraction and output marker
                    # before simulating subprocess' timeout. A 0.5-second real
                    # deadline races interpreter startup under rendering load.
                    completed = real_run(command, **kwargs)
                    raise TimeoutExpired(command, kwargs["timeout"],
                                         output=completed.stdout.encode(), stderr=completed.stderr.encode())

                timeout_patch = patch("CompatibilitySuite.run_suite.subprocess.run", side_effect=timed_out_after_startup)
                with timeout_patch if mode == "timeout" else nullcontext():
                    report = run_fixture(executable, root, {"id": mode, "path": mode}, root / "reports",
                                         frames=1, benchmark_duration=0.1, timeout_seconds=10,
                                         backend="native")
                output = root / "reports" / mode
                temporary = Path((output / "temp-root.txt").read_text())
                self.assertFalse(temporary.exists())
                self.assertNotEqual(str(temporary), original_tmp)
                self.assertEqual(os.environ.get("TMPDIR"), original_tmp)
                self.assertEqual(unrelated.read_text(), "unrelated data")
                self.assertEqual(report["status"], expected_status)
                self.assertFalse(report["windows_parity_verified"])
                self.assertEqual(report["compatibility_status"], "unverified" if mode == "success" else "issues_detected")
                self.assertEqual(json.loads((output / "report.json").read_text())["status"], expected_status)
                self.assertIn("[backend: native]", (output / "stdout.log").read_text())
                if mode == "success":
                    self.assertTrue((output / "screenshot.png").exists())
                    self.assertTrue((output / "benchmark.json").exists())
                if mode == "skipped":
                    self.assertFalse(report["render_ok"])
                    self.assertEqual(report["errors"], ["[NativeSceneRenderer] Skipping image node 2: failed shader"])
                if mode == "timeout":
                    self.assertEqual(report["observed_backend"], "native")
                    self.assertIn("Timed out", report["errors"][0])


if __name__ == "__main__":
    unittest.main()
