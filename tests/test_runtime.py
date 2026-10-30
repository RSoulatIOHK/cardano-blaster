import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from cardano_blaster import runtime


class RuntimeTests(unittest.TestCase):
    def test_pinned_runtime_does_not_inherit_another_lean_or_native_library(self):
        with patch.dict(os.environ, {"ELAN_TOOLCHAIN": "another-lean", "LEAN_PATH": "/other/modules",
                                     "ASSURANCE_NATIVE_LIBRARY": "/other/native.so"}):
            env = runtime.environment()
            self.assertEqual(env["ELAN_TOOLCHAIN"], runtime.load_lock()["lean"])
            self.assertNotIn("LEAN_PATH", env)
            self.assertNotIn("ASSURANCE_NATIVE_LIBRARY", env)

    def test_lock_lakefile_and_manifest_agree_on_every_exact_revision(self):
        lock = runtime.load_lock()
        manifest = json.loads((runtime.ASSETS / "lake-manifest.json").read_text())
        lakefile = (runtime.ASSETS / "lakefile.lean").read_text()
        self.assertEqual((runtime.ASSETS / "lean-toolchain").read_text().strip(), lock["lean"])
        self.assertEqual(len(manifest["packages"]), 3)
        for pin, entry in zip(lock["packages"], manifest["packages"]):
            self.assertRegex(pin["rev"], r"^[0-9a-f]{40}$")
            self.assertEqual((pin["name"], pin["rev"], pin["url"]),
                             (entry["name"], entry["rev"], entry["url"]))
            self.assertEqual(entry["inputRev"], entry["rev"])
            self.assertEqual(entry["type"], "git")
            self.assertIn(f'require {pin["name"]} from git "{pin["url"]}" @ "{pin["rev"]}"', lakefile)

    def test_cache_is_independent_of_working_directory_and_rejects_changed_manifest(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"CARDANO_BLASTER_CACHE": folder}):
            project = runtime.prepare_project()
            self.assertEqual(project.parent.name, runtime.runtime_id())
            self.assertEqual(runtime.validate_project(project, require_packages=False), [])
            self.assertEqual(runtime.prepare_project(), project)
            (project / "lake-manifest.json").write_text("{}")
            with self.assertRaisesRegex(ValueError, "Pinned runtime file changed"):
                runtime.prepare_project()

    def test_revision_and_source_drift_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"CARDANO_BLASTER_CACHE": folder}):
            project = runtime.prepare_project()
            package = runtime.load_lock()["packages"][0]
            checkout = project / ".lake/packages" / package["name"]
            checkout.mkdir(parents=True)
            subprocess.run(["git", "init", "-q"], cwd=checkout, check=True)
            (checkout / "source").write_text("original")
            subprocess.run(["git", "add", "source"], cwd=checkout, check=True)
            subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=Test", "-c",
                            "user.email=test@example.invalid", "commit", "-qm", "fixture"], cwd=checkout, check=True)
            with self.assertRaisesRegex(ValueError, "Pinned dependency changed"):
                runtime.validate_project(project, require_packages=False)
            revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
            with patch.object(runtime, "load_lock", return_value={"packages": [{**package, "rev": revision}]}):
                self.assertEqual(runtime.validate_project(project)[0]["rev"], revision)
                (checkout / "source").write_text("changed")
                with self.assertRaisesRegex(ValueError, "Pinned dependency changed"):
                    runtime.validate_project(project)

    def test_solver_archive_pins_are_sha256_and_missing_solver_is_actionable(self):
        for asset in runtime.load_lock()["z3"]["assets"].values():
            self.assertRegex(asset["sha256"], r"^[0-9a-f]{64}$")
            self.assertIn("/z3-5.3.1/", asset["url"])
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, {"CARDANO_BLASTER_CACHE": folder}):
            with self.assertRaisesRegex(ValueError, "cardano-blaster setup"):
                runtime.managed_solver()


if __name__ == "__main__":
    unittest.main()
