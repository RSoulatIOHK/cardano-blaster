"""Check compiled assurance with the same Lean command used by library clients."""

import argparse
from datetime import datetime, timezone
from enum import Enum
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from . import runtime


class Outcome(str, Enum):
    VERIFIED = "verified"
    FALSIFIED = "falsified"
    INCONCLUSIVE = "inconclusive"
    ERROR = "error"


EXIT_CODES = {Outcome.VERIFIED: 0, Outcome.FALSIFIED: 1,
              Outcome.INCONCLUSIVE: 2, Outcome.ERROR: 3}
PROFILES = {
    "core": ["PlutusCore.UPLC.BlueprintEncoding.Assurance"],
    "cardano-v3": ["PlutusCore.UPLC.BlueprintEncoding.Assurance", "CardanoLedgerApi.V3"],
    "cardano-v3-cex": ["PlutusCore.UPLC.BlueprintEncoding.Assurance", "CardanoLedgerApi.V3",
                       "CardanoLedgerApi.Counterexample.V3"],
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json(content):
    def invalid_constant(value):
        raise ValueError("Invalid JSON number: " + value)
    return json.loads(content, object_pairs_hook=unique_object,
                      parse_constant=invalid_constant)


def read_json(path):
    return parse_json(path.read_bytes())


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def terminal_text(value):
    return "".join(c if c.isprintable() else f"\\u{ord(c):04x}" for c in str(value))


def progress(args, message):
    if not args.json:
        print(message, file=sys.stderr, flush=True)


def local_uri(parent, uri):
    if not isinstance(uri, str) or "://" in uri:
        raise ValueError("A local artifact path is required")
    return (parent / uri).resolve(strict=True)


def checked_artifact(parent, ref, inputs):
    path = local_uri(parent, ref["uri"])
    expected = ref.get("hash", {})
    content = path.read_bytes()
    actual = hashlib.sha256(content).hexdigest()
    if expected.get("alg", "").lower() not in {"sha256", "sha-256"} or expected.get("digest") != actual:
        raise ValueError(f"Artifact digest mismatch: {path}")
    inputs[str(path)] = actual
    return path, parse_json(content)


def snapshot_context_assets(value, parent, run, inputs):
    if isinstance(value, list):
        return [snapshot_context_assets(v, parent, run, inputs) for v in value]
    if not isinstance(value, dict):
        return value
    if "uri" in value and "hash" in value:
        source = local_uri(parent, value["uri"])
        content = source.read_bytes()
        actual = hashlib.sha256(content).hexdigest()
        if value["hash"].get("alg", "").lower() not in {"sha256", "sha-256"} or value["hash"].get("digest") != actual:
            raise ValueError("Artifact digest mismatch: " + str(source))
        inputs[str(source)] = actual
        destination = run / "artifacts" / actual
        destination.parent.mkdir(exist_ok=True)
        destination.write_bytes(content)
        return {**value, "uri": "artifacts/" + actual}
    return {k: snapshot_context_assets(v, parent, run, inputs) for k, v in value.items()}


def absolute_uris(value, parent):
    """Preserve the meaning of local references when creating a derived document."""
    if isinstance(value, list):
        return [absolute_uris(v, parent) for v in value]
    if isinstance(value, dict):
        return {k: (str((parent / v).resolve()) if k == "uri" and isinstance(v, str)
                    and "://" not in v else absolute_uris(v, parent))
                for k, v in value.items()}
    return value


def select_profile(contexts):
    choices = set()
    for _, _, _, environment in contexts.values():
        modules = environment.get("modules", {})
        if "CardanoLedgerApi.Counterexample.V3" in modules:
            choices.add("cardano-v3-cex")
        elif "CardanoLedgerApi.V3" in modules:
            choices.add("cardano-v3")
        else:
            choices.add("core")
    if len(choices) > 1:
        raise ValueError("Checking contexts require different import profiles; select properties separately")
    return next(iter(choices), "core")


def run_process(command, project, env, timeout, log):
    """Terminate the verifier and its solver children together on interruption."""
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(command, cwd=project, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=os.name != "nt")
        try:
            return process.wait(timeout=timeout)
        except BaseException:
            try:
                if os.name == "nt":
                    process.terminate()
                else:
                    os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                if os.name == "nt":
                    process.kill()
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise


def lean_command(project, env):
    lookup = subprocess.run(
        ["lake", "env", sys.executable, "-c", "import os; print(os.environ.get('LEAN_PATH', ''))"],
        cwd=project, env=env, capture_output=True, text=True, timeout=60, check=True)
    native = env.get("ASSURANCE_NATIVE_LIBRARY")
    if not native:
        for directory in lookup.stdout.strip().split(os.pathsep):
            for name in ["libBlaster.so", "libBlaster.dylib", "Blaster.dll"]:
                candidate = Path(directory).resolve().parent / name
                if candidate.is_file():
                    native = str(candidate)
                    break
            if native:
                break
    command = ["lake", "env", "lean"]
    if native:
        native = str(Path(native).resolve(strict=True))
        env["ASSURANCE_NATIVE_LIBRARY"] = native
        command.append("--load-dynlib=" + native)
    return command


def classify(native, expected, assurance_hash, blueprint_hash, returncode):
    if native.get("format") != "plinth-counterexample-report-v1":
        raise ValueError("Unsupported verifier report format")
    if native.get("assuranceSha256") != assurance_hash or native.get("blueprintSha256") != blueprint_hash:
        raise ValueError("Verifier report does not bind the checked input files")
    results = native["results"]
    seen = set()
    for result in results:
        name = result["property"]
        if name not in expected or name in seen or result["outcome"] not in {
                "verified", "falsified", "inconclusive", "not-checked"}:
            raise ValueError("Invalid or duplicate property result in verifier report")
        seen.add(name)
    outcomes = {r["outcome"] for r in results}
    # Lean emits errors for falsification and undetermined results. A nonzero
    # exit with verified-only results is an execution error, never a success.
    if returncode and not outcomes.intersection({"falsified", "inconclusive"}):
        return Outcome.ERROR, results
    if "falsified" in outcomes:
        outcome = Outcome.FALSIFIED
    elif outcomes.intersection({"inconclusive", "not-checked"}) or seen != set(expected):
        outcome = Outcome.INCONCLUSIVE
    else:
        outcome = Outcome.VERIFIED
    for name in expected:
        if name not in seen:
            results.append({"property": name, "outcome": "not-checked", "counterexample": None})
    return outcome, results


def check(args, report, run):
    blueprint = args.blueprint.resolve(strict=True)
    assurance_path = args.assurance.resolve(strict=True)
    assurance_bytes = assurance_path.read_bytes()
    blueprint_bytes = blueprint.read_bytes()
    assurance = parse_json(assurance_bytes)
    parse_json(blueprint_bytes)
    inputs = report["inputs"]
    inputs.update({str(blueprint): hashlib.sha256(blueprint_bytes).hexdigest(),
                   str(assurance_path): hashlib.sha256(assurance_bytes).hexdigest()})
    ref = assurance["blueprint"].get("hash", {})
    if ref.get("alg", "").lower() not in {"sha256", "sha-256"} or ref.get("digest") != inputs[str(blueprint)]:
        raise ValueError("The supplied blueprint does not match the assurance blueprint digest")
    properties = assurance["properties"]
    ids = [p["id"] for p in properties]
    if not ids or any(not isinstance(x, str) or not x for x in ids) or len(set(ids)) != len(ids):
        raise ValueError("Assurance must contain nonempty, unique property identifiers")
    if args.property:
        unknown = set(args.property) - set(ids)
        if unknown:
            raise ValueError("Unknown properties: " + ", ".join(sorted(unknown)))
        properties = [p for p in properties if p["id"] in args.property]
    expected = [p["id"] for p in properties]
    report["selectedProperties"] = expected
    contexts = {}
    for prop in properties:
        key = prop.get("checkingContext")
        if key is None or key in contexts:
            continue
        path, ctx = checked_artifact(assurance_path.parent, assurance["checkingContexts"][key], inputs)
        env_path, environment = checked_artifact(path.parent, ctx["environment"], inputs)
        contexts[key] = (path, ctx, env_path, environment)
    profile = select_profile(contexts) if args.profile == "auto" else args.profile
    pinned = args.project is None
    project = runtime.prepare_project() if pinned else args.project.resolve(strict=True)
    if not any((project / name).is_file() for name in ["lakefile.lean", "lakefile.toml"]):
        raise ValueError("--project must name a configured Lake project containing the checker")
    report["profile"] = profile
    report["project"] = str(project)
    if pinned:
        runtime.validate_project(project, require_packages=False)
        report["runtime"] = {"id": runtime.runtime_id(), "lock": runtime.load_lock()}
    else:
        report["runtime"] = {"pinned": False, "projectOverride": str(project)}
    env = runtime.environment() if pinned else os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    if args.z3 or pinned:
        solver = args.z3.resolve(strict=True) if args.z3 else runtime.managed_solver()
        bin_dir = run / "bin"
        bin_dir.mkdir()
        (bin_dir / ("z3.exe" if os.name == "nt" else "z3")).symlink_to(solver)
        env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
    available_solver = shutil.which("z3", path=env.get("PATH"))
    if not available_solver:
        raise ValueError("Z3 is unavailable; provide --z3 or add the compatible solver to PATH")
    report["solver"] = {**runtime.solver_provenance(Path(available_solver).resolve()),
                        "override": args.z3 is not None or not pinned}
    if not args.no_build:
        progress(args, "Preparing the verifier…")
        targets = ["Blaster:shared", *PROFILES[profile]]
        if run_process(["lake", "build", *targets], project, env, args.timeout, run / "build.log"):
            raise ValueError("Checker build failed; see build.log")
    if pinned:
        report["runtime"]["packages"] = runtime.validate_project(project)
        report["runtime"]["leanVersion"] = runtime.lean_version(project, env)
        report["runtime"]["pinned"] = True
    lean = lean_command(project, env)
    header = "".join("import " + name + "\n" for name in PROFILES[profile])
    if profile.startswith("cardano-v3"):
        header += ("open PlutusCore.ByteString\nopen PlutusCore.Integer\n"
                   "open PlutusCore.Data (Data)\nopen CardanoLedgerApi.IsData.Class\n"
                   "open CardanoLedgerApi.V3\nopen CardanoLedgerApi.V3.Contexts\n"
                   "open CardanoLedgerApi.V3.Tx\n")
    checked_blueprint = run / "plutus.json"
    checked_blueprint.write_bytes(blueprint_bytes)
    assurance = absolute_uris(assurance, assurance_path.parent)
    assurance["properties"] = absolute_uris(properties, assurance_path.parent)
    assurance["blueprint"]["uri"] = "plutus.json"
    if args.refresh_environment:
        progress(args, "Capturing the current checking environment…")
        capture = run / "Environment.lean"
        environment_path = run / "environment.json"
        capture.write_text(header + "#write_checking_environment " + json.dumps(str(environment_path), ensure_ascii=False) + "\n")
        if run_process([*lean, str(capture)], project, env, args.timeout, run / "environment.log"):
            raise ValueError("Environment capture failed; see environment.log")
        for i, (key, (path, context, _, _)) in enumerate(contexts.items()):
            ctx = snapshot_context_assets({k: v for k, v in context.items() if k != "environment"}, path.parent, run, inputs)
            ctx["environment"] = {"uri": "environment.json", "hash": {"alg": "sha256", "digest": digest(environment_path)}}
            context_path = run / f"checking-{i}.json"
            write_json(context_path, ctx)
            assurance["checkingContexts"][key] = {"uri": context_path.name, "hash": {"alg": "sha256", "digest": digest(context_path)}}
        report["environmentSha256"] = digest(environment_path)
    # Always check stable input snapshots. Relative references keep their original
    # meaning; only explicit refresh replaces the bound environment/context bytes.
    checked_path = run / "assurance.json"
    write_json(checked_path, assurance)
    report["environmentRefreshed"] = args.refresh_environment
    native_path = run / "verifier-report.json"
    driver = run / "Check.lean"
    driver.write_text(header + "#verify_blueprint CardanoBlasterCheck " +
                      " ".join(json.dumps(str(p), ensure_ascii=False) for p in [checked_path, checked_blueprint]) +
                      " cex_report " + json.dumps(str(native_path), ensure_ascii=False) + "\n")
    progress(args, f"Checking {len(expected)} properties…")
    code = run_process([*lean, str(driver)], project, env, args.timeout, run / "verification.log")
    report["verifierExitCode"] = code
    if not native_path.is_file():
        raise ValueError("The checker did not produce a complete report; see verification.log")
    if pinned:
        runtime.validate_project(project)
    for path, original_hash in inputs.items():
        if digest(Path(path)) != original_hash:
            raise ValueError("An input artifact changed during verification: " + path)
    outcome, results = classify(read_json(native_path), expected, digest(checked_path), digest(checked_blueprint), code)
    report["results"] = results
    report["checkedAssuranceSha256"] = digest(checked_path)
    report["verifierReportSha256"] = digest(native_path)
    report["verificationLogSha256"] = digest(run / "verification.log")
    return outcome


def setup(args):
    project = runtime.prepare_project()
    print(f"Preparing pinned runtime {runtime.runtime_id()[:12]}…", flush=True)
    try:
        runtime.validate_project(project, require_packages=False)
        solver = runtime.managed_solver(install=True)
        env = runtime.environment()
        env["PATH"] = str(solver.parent) + os.pathsep + env.get("PATH", "")
        log = project.parent / "setup.log"
        if run_process(["lake", "build", "Blaster:shared", *PROFILES["cardano-v3-cex"]],
                       project, env, args.timeout, log):
            raise ValueError(f"Checker build failed; see {log}")
        runtime.validate_project(project)
        runtime.lean_version(project, env)
        print(f"Runtime ready: {project}\nZ3: {solver}")
        return 0
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print("Setup failed: " + (str(error) or "interrupted"), file=sys.stderr)
        return 3


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(3, f"{self.prog}: error: {message}\n")


def main(argv=None):
    parser = ArgumentParser(prog="cardano-blaster", description=__doc__)
    parser.add_argument("--version", action="version", version="cardano-blaster 0.1.0")
    sub = parser.add_subparsers(dest="command", required=True)
    install = sub.add_parser("setup", help="Download and build the exact pinned Lean dependencies and Z3")
    install.add_argument("--timeout", type=int, default=1800, help="Maximum seconds for the build")
    command = sub.add_parser("check", help="Verify the properties of a compiled blueprint")
    command.add_argument("blueprint", type=Path)
    command.add_argument("assurance", type=Path)
    command.add_argument("--project", type=Path, help="Override the bundled pinned runtime with a custom Lake project")
    command.add_argument("--output", type=Path, default=Path("cardano-blaster-results"))
    command.add_argument("--profile", choices=["auto", *PROFILES], default="auto")
    command.add_argument("--property", action="append", help="Check only this property; repeat to select several")
    command.add_argument("--z3", type=Path, help="Compatible solver executable")
    command.add_argument("--refresh-environment", action="store_true", help="Create a derived bundle bound to the current checking environment")
    command.add_argument("--no-build", action="store_true", help="Use an already-built checker")
    command.add_argument("--timeout", type=int, default=1800, help="Maximum seconds for each build/check process")
    command.add_argument("--json", action="store_true", help="Print the structured report to stdout")
    args = parser.parse_args(argv)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.command == "setup":
        return setup(args)
    start = time.monotonic()
    args.output = args.output.resolve()
    try:
        args.output.mkdir(parents=True, exist_ok=True)
        run = Path(tempfile.mkdtemp(prefix="run-", dir=args.output))
    except OSError as error:
        print("cardano-blaster: " + str(error), file=sys.stderr)
        return EXIT_CODES[Outcome.ERROR]
    report = {"format": "cardano-blaster-check-v1", "created": datetime.now(timezone.utc).isoformat(),
              "inputs": {}, "results": [], "artifacts": str(run),
              "tool": {"name": "cardano-blaster", "version": "0.1.0", "sourceSha256": digest(Path(__file__))},
              "method": "Blaster SMT; execution scope and bounds are specified by the checked assurance; no reconstructed Lean proof"}
    try:
        outcome = check(args, report, run)
    except KeyboardInterrupt:
        outcome = Outcome.ERROR
        report["error"] = "Verification interrupted"
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
        outcome = Outcome.ERROR
        report["error"] = str(error)
        for name in ["verification.log", "environment.log", "build.log"]:
            path = run / name
            if path.is_file():
                report["diagnostics"] = "\n".join(path.read_text(errors="replace").splitlines()[-20:])[-6000:]
                break
    report.update(status=outcome.value, exitCode=EXIT_CODES[outcome], elapsedSeconds=round(time.monotonic() - start, 3))
    try:
        write_json(run / "report.json", report)
    except OSError as error:
        print("Cannot save verification report: " + str(error), file=sys.stderr)
        return EXIT_CODES[Outcome.ERROR]
    if args.json:
        print(json.dumps(report, ensure_ascii=False))
    else:
        for result in report["results"]:
            print(f"{result['outcome']:12} {terminal_text(result['property'])}")
            cex = result.get("counterexample") or {}
            replay = cex.get("replay") or {}
            if replay:
                print("  replay: " + replay.get("status", "unavailable"))
                if replay.get("reason"):
                    print("  " + terminal_text(replay["reason"]))
            elif cex.get("messages"):
                print("  solver model (typed reconstruction unavailable):")
                lines = [line for message in cex["messages"] for line in message.splitlines()]
                for line in lines[:30]:
                    line = terminal_text(line)
                    print("    " + (line if len(line) <= 200 else line[:197] + "..."))
                if len(lines) > 30:
                    print("    … full model retained in the JSON report")
            for value in replay.get("inputs", []):
                text = json.dumps(value.get("value"), ensure_ascii=False)
                print("  " + terminal_text(value["name"]) + " = " + terminal_text(text if len(text) <= 160 else text[:157] + "..."))
        if report.get("error"):
            print("error: " + terminal_text(report["error"]), file=sys.stderr)
            if report.get("diagnostics"):
                for line in report["diagnostics"].splitlines():
                    print("  " + terminal_text(line), file=sys.stderr)
        print(f"{outcome.value}; report: {run / 'report.json'}")
    return EXIT_CODES[outcome]


if __name__ == "__main__":
    sys.exit(main())
