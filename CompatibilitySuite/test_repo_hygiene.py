from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts/check-repo-hygiene.py"
spec = importlib.util.spec_from_file_location("repo_hygiene", MODULE_PATH)
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)


class RepositoryHygieneTests(unittest.TestCase):
    def test_git_inventory_distinguishes_source_from_generated_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            for name in ("Package.swift", "build-bridge.sh", "run.sh",
                         "cmake/dependencies/CMakeLists.txt", "patches/quickjs-mapped-arguments-gc.patch",
                         "Sources/App/main.swift", "Tests/AppTests/test.swift"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)

            def check():
                output = io.StringIO()
                with patch.object(hygiene, "ROOT", root), redirect_stderr(output), redirect_stdout(output):
                    code = hygiene.main()
                return code, output.getvalue()

            self.assertEqual(check()[0], 0)
            (root / "Tests/AppTests/untracked.swift").touch()
            code, output = check()
            self.assertEqual(code, 1)
            self.assertIn("authored file is untracked", output)
            subprocess.run(["git", "-C", str(root), "add", "Tests"], check=True)
            (root / "build").mkdir()
            (root / "build/CMakeCache.txt").touch()
            self.assertEqual(check()[0], 0)
            subprocess.run(["git", "-C", str(root), "add", "build"], check=True)
            code, output = check()
            self.assertEqual(code, 1)
            self.assertIn("generated file is tracked: build/CMakeCache.txt", output)


if __name__ == "__main__":
    unittest.main()
