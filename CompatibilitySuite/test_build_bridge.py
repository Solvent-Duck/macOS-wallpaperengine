import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BuildBridgeTests(unittest.TestCase):
    def run_build(self, failed_compiler=None, missing_dependency=False, bad_patch=False):
        with tempfile.TemporaryDirectory(prefix="bridge-lookup-test-") as directory:
            root = Path(directory)
            shutil.copy2(Path(__file__).resolve().parents[1] / "build-bridge.sh", root)
            engine = root / "linux-wallpaperengine"
            engine.mkdir()
            (engine / "CMakeLists.txt").touch()
            for name in ("glslang-WallpaperEngine", "SPIRV-Cross-WallpaperEngine", "quickjs", "json"):
                dependency = engine / "src/External" / name
                dependency.mkdir(parents=True)
                if not (missing_dependency and name == "glslang-WallpaperEngine"):
                    (dependency / "CMakeLists.txt").touch()
            original = engine / "src/External/quickjs/quickjs.c"
            original.write_text("before\n")
            (root / "patches").mkdir()
            (root / "patches/quickjs-mapped-arguments-gc.patch").write_text(
                "invalid patch\n" if bad_patch else
                "--- a/quickjs.c\n+++ b/quickjs.c\n@@ -1 +1 @@\n-before\n+after\n")
            commands = root / "commands"
            commands.mkdir()
            stubs = {
                "git": 'if [ "$3" = submodule ]; then exit 42; fi\nexec "$REAL_GIT" "$@"\n',
                "xcrun": 'if [ "$2" = "$FAILED_COMPILER" ]; then exit 69; fi\nprintf "/test tools/%s\\n" "$2"\n',
                "cmake": 'printf "%s\\n" "$@" >> "$CMAKE_CALLS"\n',
                "sysctl": "echo 1\n",
            }
            for name, body in stubs.items():
                path = commands / name
                path.write_text("#!/bin/bash\n" + body)
                path.chmod(0o755)
            calls = root / "cmake-calls"
            env = {**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                   "REAL_GIT": shutil.which("git"), "FAILED_COMPILER": failed_compiler or "",
                   "CMAKE_CALLS": str(calls)}
            result = subprocess.run(["/bin/bash", str(root / "build-bridge.sh")],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(original.read_text(), "before\n", result.stderr)
            if result.returncode == 0:
                copied = root / "build/quickjs-source/quickjs.c"
                self.assertEqual(copied.read_text(), "after\n")
                timestamp = copied.stat().st_mtime_ns
                again = subprocess.run(["/bin/bash", str(root / "build-bridge.sh")],
                                       env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(again.returncode, 0, again.stderr)
                self.assertEqual(copied.stat().st_mtime_ns, timestamp)
            self.assertFalse(list((root / "build").glob("quickjs-stage.*")))
            return result.returncode, calls.read_text().splitlines() if calls.exists() else []

    def test_compiler_lookup_failure_stops_before_cmake(self):
        for compiler in ("cc", "c++"):
            with self.subTest(compiler=compiler):
                code, calls = self.run_build(failed_compiler=compiler)
                self.assertEqual(code, 69)
                self.assertEqual(calls, [])

    def test_resolved_compiler_paths_and_repeatable_patch_copy(self):
        code, calls = self.run_build()
        self.assertEqual(code, 0)
        self.assertIn("-DCMAKE_C_COMPILER=/test tools/cc", calls)
        self.assertIn("-DCMAKE_CXX_COMPILER=/test tools/c++", calls)
        self.assertTrue(any(value.endswith("/cmake/dependencies") for value in calls))
        self.assertIn("--build", calls)
        self.assertIn("wallpaper-dependencies", calls)

    def test_dependency_initialization_failure_stops_build(self):
        code, calls = self.run_build(missing_dependency=True)
        self.assertEqual(code, 42)
        self.assertEqual(calls, [])

    def test_bad_patch_stops_before_cmake(self):
        code, calls = self.run_build(bad_patch=True)
        self.assertNotEqual(code, 0)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
