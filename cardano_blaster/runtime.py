"""Install and identify the exact, independently versioned Lean runtime."""

import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile


ASSETS = Path(__file__).with_name("runtime")
PROJECT_FILES = ("lean-toolchain", "lakefile.lean", "lake-manifest.json", "lock.json")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_lock():
    return json.loads((ASSETS / "lock.json").read_text())


def runtime_id():
    digest = hashlib.sha256()
    for name in PROJECT_FILES:
        digest.update(name.encode() + b"\0" + (ASSETS / name).read_bytes())
    return digest.hexdigest()


def cache_root():
    if os.environ.get("CARDANO_BLASTER_CACHE"):
        return Path(os.environ["CARDANO_BLASTER_CACHE"]).expanduser().resolve()
    if platform.system() == "Darwin":
        return Path.home() / "Library/Caches/cardano-blaster"
    return Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "cardano-blaster"


def prepare_project():
    project = cache_root() / runtime_id() / "lean"
    project.mkdir(parents=True, exist_ok=True)
    for name in PROJECT_FILES:
        target = project / name
        source = ASSETS / name
        if target.exists():
            if target.read_bytes() != source.read_bytes():
                raise ValueError(f"Pinned runtime file changed: {target}; use a new CARDANO_BLASTER_CACHE")
        else:
            # Concurrent invocations may create the same, identical file.
            with tempfile.NamedTemporaryFile(dir=project, delete=False) as temporary:
                temporary.write(source.read_bytes())
                temporary_path = Path(temporary.name)
            temporary_path.replace(target)
    return project


def environment():
    env = os.environ.copy()
    # Do not accidentally load a different project's native library or modules.
    for name in ["ASSURANCE_NATIVE_LIBRARY", "LEAN_PATH", "LEAN_SRC_PATH", "LEAN_SYSROOT"]:
        env.pop(name, None)
    env["ELAN_TOOLCHAIN"] = load_lock()["lean"]
    return env


def lean_version(project, env):
    version = subprocess.check_output(["lake", "env", "lean", "--version"], cwd=project,
                                      env=env, text=True, timeout=60).strip()
    expected = load_lock()["lean"].split(":v", 1)[1]
    if not version.startswith("Lean (version " + expected + ","):
        raise ValueError(f"Expected Lean {expected}, got {version}")
    return version


def validate_project(project, require_packages=True):
    """Fail on a changed lock, Git revision or tracked dependency source."""
    for name in PROJECT_FILES:
        if (project / name).read_bytes() != (ASSETS / name).read_bytes():
            raise ValueError(f"Pinned runtime file changed: {project / name}")
    actual = []
    for package in load_lock()["packages"]:
        checkout = project / ".lake/packages" / package["name"]
        if not checkout.exists() and not require_packages:
            continue
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
        dirty = subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=normal"], cwd=checkout, text=True).strip()
        if revision != package["rev"] or dirty:
            raise ValueError(f"Pinned dependency changed: {package['name']} (expected {package['rev']})")
        actual.append({**package, "clean": True})
    return actual


def solver_asset():
    machine = platform.machine().lower()
    machine = {"amd64": "x86_64", "arm64": "arm64" if platform.system() == "Darwin" else "aarch64"}.get(machine, machine)
    key = platform.system() + "-" + machine
    asset = load_lock()["z3"]["assets"].get(key)
    if asset is None:
        raise ValueError(f"No pinned Z3 binary for {key}; provide --z3 with a compatible solver")
    return asset


def managed_solver(install=False):
    asset = solver_asset()
    folder = cache_root() / "z3" / asset["sha256"]
    binary = folder / "z3"
    receipt_path = folder / "receipt.json"
    if binary.is_file() and receipt_path.is_file():
        receipt = json.loads(receipt_path.read_text())
        if receipt.get("archiveSha256") != asset["sha256"] or receipt.get("binarySha256") != sha256(binary):
            raise ValueError("The cached Z3 executable changed; remove its cache directory and run setup again")
        return binary
    if not install:
        raise ValueError("Pinned Z3 is not installed; run 'cardano-blaster setup' first")
    request = urllib.request.Request(asset["url"], headers={"User-Agent": "cardano-blaster/0.1.0"})
    with urllib.request.urlopen(request, timeout=120) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != asset["sha256"]:
        raise ValueError("The Z3 release archive does not match the pinned SHA-256")
    with zipfile.ZipFile(io.BytesIO(content)) as archive:
        matches = [name for name in archive.namelist() if name.endswith("/bin/z3")]
        if len(matches) != 1:
            raise ValueError("The Z3 archive must contain exactly one executable")
        executable = archive.read(matches[0])
    folder.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=folder.parent) as temporary:
        stage = Path(temporary)
        (stage / "z3").write_bytes(executable)
        (stage / "z3").chmod(0o755)
        version = subprocess.check_output([str(stage / "z3"), "--version"], text=True, timeout=30)
        if not version.startswith("Z3 version " + load_lock()["z3"]["version"] + " "):
            raise ValueError("The downloaded Z3 executable has an unexpected version")
        receipt = {"archiveSha256": asset["sha256"], "binarySha256": sha256(stage / "z3"), "url": asset["url"]}
        (stage / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        folder.mkdir(exist_ok=True)
        for name in ["z3", "receipt.json"]:
            shutil.move(str(stage / name), folder / name)
    return binary


def solver_provenance(binary):
    return {"path": str(binary), "sha256": sha256(binary),
            "version": subprocess.check_output([str(binary), "--version"], text=True, timeout=30).strip()}
