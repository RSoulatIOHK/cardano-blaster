"""Exercise the installed command from outside its checkout, using locked libraries."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = Path(os.environ.get("CARDANO_BLASTER_TEST_OUTPUT", ROOT / "cardano-blaster-results/integration")).resolve()


def check(blueprint, assurance, expected, cwd, refresh=True, count=None):
    command = [sys.executable, "-m", "cardano_blaster", "check", str(blueprint), str(assurance),
               "--json", "--no-build", "--output", str(OUTPUT), "--timeout", "300"]
    if refresh:
        command.append("--refresh-environment")
    process = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=650)
    report = json.loads(process.stdout)
    if process.returncode != expected or report["exitCode"] != expected:
        raise AssertionError(json.dumps(report, indent=2) + "\n" + process.stderr)
    if expected in (0, 1):
        assert report["runtime"]["pinned"] is True
        assert len(report["runtime"]["packages"]) == 3
        if count is not None:
            assert len(report["results"]) == count
        assert len(report["selectedProperties"]) == len(report["results"])
    print(f"{assurance.parent.name}: {report['status']} ({report['elapsedSeconds']}s)", flush=True)
    return report


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    reports = []
    with tempfile.TemporaryDirectory() as folder:
        cwd = Path(folder)
        for name, code, count in [("game", 0, 3), ("parameters", 0, 6), ("recursive", 0, 4),
                                  ("auction", 0, 31), ("helper-counterexample", 1, 1),
                                  ("auction-counterexample", 1, 1)]:
            example = ROOT / "examples" / name
            report = check(example / "plutus.json", example / "assurance.json", code, cwd, count=count)
            if code == 0:
                assert all(result["outcome"] == "verified" for result in report["results"])
            else:
                cex = report["results"][0]["counterexample"]
                assert cex["model"]["bindings"], "typed witness must be available"
                assert cex["replay"]["status"] == "confirmed", "compiled replay must confirm the false claim"
                assert cex["replay"]["propertyHolds"] is False
                assert cex["replay"]["calls"], "replay must reach an imported compiled wrapper"
            reports.append(report)
        # A derived context is usable without silently refreshing it again.
        derived = Path(reports[0]["artifacts"])
        reports.append(check(derived / "plutus.json", derived / "assurance.json", 0, cwd, refresh=False, count=3))
        # A mismatched blueprint is rejected before invoking the verifier.
        reports.append(check(ROOT / "examples/game/plutus.json", ROOT / "examples/auction/assurance.json", 3, cwd))
        # Unsupported natural-language-only statements cannot pass as verified.
        example = ROOT / "examples/game"
        notes = json.loads((example / "assurance.json").read_text())
        notes["properties"] = [{"id": "notes", "scope": {"validators": ["gameValidator"]},
                                "statement": {"text": "Documentation only"}}]
        notes["blueprint"]["uri"] = str(example / "plutus.json")
        notes["checkingContexts"] = {}
        notes_path = cwd / "notes.json"
        notes_path.write_text(json.dumps(notes))
        report = check(example / "plutus.json", notes_path, 2, cwd)
        assert report["results"][0]["outcome"] == "not-checked"
        reports.append(report)
    (OUTPUT / "summary.json").write_text(json.dumps(reports, indent=2) + "\n")
    print("44 true properties, 2 typed/replayed counterexamples, strict recheck, wrong blueprint and unchecked claim passed.")


if __name__ == "__main__":
    main()
