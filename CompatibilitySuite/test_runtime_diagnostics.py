import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from CompatibilitySuite.runtime_diagnostics import audit_run, collect_runtime_diagnostics, compatibility_evidence


class RuntimeDiagnosticsTests(unittest.TestCase):
    def test_visible_frame_and_static_complete_label_do_not_prove_compatibility(self):
        failure = "[NativeSceneRuntime] Script scene.node.4.alpha evaluation failed: ReferenceError: localStorage is not defined"
        fallback = "[MaterialBinder] Texture 'cover' could not be resolved — using fallback"
        diagnostics = collect_runtime_diagnostics(failure + "\n" + fallback, failure)
        report = compatibility_evidence({"status": "pass", "native_support": {"parityStatus": "complete"}}, diagnostics)
        self.assertEqual(report["script_errors"], [failure])
        self.assertEqual(report["renderer_fallbacks"], [fallback])
        self.assertEqual(report["compatibility_status"], "issues_detected")
        self.assertFalse(report["windows_parity_verified"])

    def test_silent_logs_and_successful_render_remain_unverified(self):
        report = compatibility_evidence({"status": "pass"}, collect_runtime_diagnostics("[AudioReactivity] Stopped", ""))
        self.assertEqual(report["compatibility_status"], "unverified")
        self.assertFalse(report["windows_parity_verified"])

    def test_missing_mesh_attributes_are_renderer_fallbacks(self):
        missing = "[MaterialBinder] Unknown vertex attribute 'a_Normal' (bufferIndex 27) — zero-filling"
        diagnostics = collect_runtime_diagnostics(missing, missing)
        self.assertEqual(diagnostics["renderer_fallbacks"], [missing])
        report = compatibility_evidence({"status": "pass"}, diagnostics)
        self.assertEqual(report["compatibility_status"], "issues_detected")

    def test_audit_preserves_smoke_results_and_ignores_excluded_fixture_content(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            fixture = root / "fixture"
            fixture.mkdir()
            original = json.dumps({"fixture_id": "fixture", "status": "pass"})
            (fixture / "report.json").write_text(original)
            (fixture / "stderr.log").write_text("[NativeSceneRenderer] Skipping image node 4: shader failure\n")
            # A synthetic invalid file proves excluded content is never read.
            excluded = root / "excluded_fixture"
            excluded.mkdir()
            (excluded / "report.json").write_text("not JSON")
            with patch("CompatibilitySuite.runtime_diagnostics.EXCLUDED_FIXTURES", {"excluded_fixture"}):
                result = audit_run(root)
            self.assertEqual(result["fixture_count"], 1)
            self.assertEqual(result["render_status_counts"], {"pass": 1})
            self.assertEqual(result["fixtures_with_skipped_layers"], 1)
            self.assertEqual(result["fixtures"][0]["compatibility_status"], "issues_detected")
            self.assertEqual((fixture / "report.json").read_text(), original)


if __name__ == "__main__":
    unittest.main()
