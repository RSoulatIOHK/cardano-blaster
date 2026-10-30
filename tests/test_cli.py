import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

from cardano_blaster.cli import Outcome, checked_artifact, classify, digest, main, read_json, select_profile, snapshot_context_assets


class ReportTests(unittest.TestCase):
    def report(self, results):
        return {"format": "plinth-counterexample-report-v1", "assuranceSha256": "aa",
                "blueprintSha256": "bb", "results": results}

    def classify(self, results, code=0, expected=("p",)):
        return classify(self.report(results), expected, "aa", "bb", code)

    def test_missing_results_are_incomplete_even_with_zero_exit(self):
        outcome, results = self.classify([])
        self.assertEqual(outcome, Outcome.INCONCLUSIVE)
        self.assertEqual(results[0]["outcome"], "not-checked")

    def test_verified_results_cannot_hide_process_failure(self):
        self.assertEqual(self.classify([{"property": "p", "outcome": "verified"}], 1)[0], Outcome.ERROR)

    def test_falsification_keeps_native_counterexample_and_replay_separate(self):
        cex = {"model": {"raw": "witness"}, "replay": {"status": "unavailable"}}
        outcome, results = self.classify([{"property": "p", "outcome": "falsified", "counterexample": cex}], 1)
        self.assertEqual(outcome, Outcome.FALSIFIED)
        self.assertEqual(results[0]["counterexample"], cex)

    def test_undetermined_is_not_verified(self):
        self.assertEqual(self.classify([{"property": "p", "outcome": "inconclusive"}], 1)[0], Outcome.INCONCLUSIVE)

    def test_unbound_report_is_rejected(self):
        report = self.report([{"property": "p", "outcome": "verified"}])
        report["blueprintSha256"] = "wrong"
        with self.assertRaisesRegex(ValueError, "bind"):
            classify(report, ["p"], "aa", "bb", 0)

    def test_duplicate_unknown_and_invalid_results_are_rejected(self):
        p = {"property": "p", "outcome": "verified"}
        for results in [[p, p], [{"property": "other", "outcome": "verified"}],
                        [{"property": "p", "outcome": "maybe"}]]:
            with self.subTest(results=results), self.assertRaises(ValueError):
                self.classify(results)


class InputTests(unittest.TestCase):
    def test_duplicate_keys_and_nonfinite_numbers_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / "input.json"
            for text in ['{"x": 1, "x": 2}', '{"x": NaN}', '{"x": Infinity}']:
                p.write_text(text)
                with self.subTest(text=text), self.assertRaises(ValueError):
                    read_json(p)

    def test_local_context_is_digest_checked_before_use(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            p = root / "context.json"
            p.write_text('{"environment": {}}')
            ref = {"uri": p.name, "hash": {"alg": "sha256", "digest": digest(p)}}
            self.assertEqual(checked_artifact(root, ref, {})[0], p.resolve())
            p.write_text("{}")
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                checked_artifact(root, ref, {})

    def test_profile_uses_fixed_imports_and_rejects_mixed_contexts(self):
        contexts = {"a": (None, None, None, {"modules": {"CardanoLedgerApi.V3": "hash"}})}
        self.assertEqual(select_profile(contexts), "cardano-v3")
        contexts["b"] = (None, None, None, {"modules": {}})
        with self.assertRaises(ValueError):
            select_profile(contexts)

    def test_parameter_snapshots_preserve_bytes_and_distinguish_same_names(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            run = root / "run"
            run.mkdir()
            refs = []
            for name, content in [("first", b"first flat term"), ("second", b"different flat term")]:
                directory = root / name
                directory.mkdir()
                term = directory / "value.flat"
                term.write_bytes(content)
                refs.append({"uri": str(term.relative_to(root)), "hash": {"alg": "sha256", "digest": digest(term)}})
            inputs = {}
            copied = snapshot_context_assets(refs, root, run, inputs)
            self.assertNotEqual(copied[0]["uri"], copied[1]["uri"])
            self.assertEqual(len(inputs), 2)
            for source, destination in zip(refs, copied):
                self.assertEqual((root / source["uri"]).read_bytes(), (run / destination["uri"]).read_bytes())
                self.assertEqual(source["hash"], destination["hash"])

    def test_tampered_parameter_is_not_snapshotted(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            term = root / "value.flat"
            term.write_bytes(b"original")
            ref = {"uri": term.name, "hash": {"alg": "sha256", "digest": digest(term)}}
            term.write_bytes(b"tampered")
            with self.assertRaisesRegex(ValueError, "digest mismatch"):
                snapshot_context_assets(ref, root, root, {})
            self.assertFalse((root / "artifacts").exists())

    def test_invalid_input_produces_fresh_machine_readable_error(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            blueprint = root / "plutus.json"
            assurance = root / "assurance.json"
            blueprint.write_text("{}")
            assurance.write_text(json.dumps({"blueprint": {"hash": {"alg": "sha256", "digest": "bad"}}}))
            old = root / "report.json"
            old.write_text('{"status":"verified"}')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = main(["check", str(blueprint), str(assurance), "--output", str(root), "--json"])
            report = json.loads(output.getvalue())
            self.assertEqual(code, 3)
            self.assertEqual(report["status"], "error")
            self.assertNotEqual(Path(report["artifacts"]), root)
            self.assertEqual(read_json(blueprint), {})
            self.assertEqual(read_json(old), {"status": "verified"})


if __name__ == "__main__":
    unittest.main()
