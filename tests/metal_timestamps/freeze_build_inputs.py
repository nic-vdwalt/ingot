"""Assemble a frozen, hash-manifested build tree for one timing game capture.

Copies (never symlinks) the union game packages, the demo assets and every Ingot
collection package into one directory so the compile inputs are immutable for
the capture's lifetime, then records SHA-256 for every copied file plus the
compiler and pinned wgpu archive identities before any build happens.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

INGOT_SKIP = {"artifacts", "benchmarks", "dist", "docs", "examples", "scripts", "testdata",
              "tests", "tools", "web"}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                          check=True).stdout.strip()


def copy_union(forgecore, demo, dest):
    for package in ("client", "shared", "host"):
        target = dest / package
        target.mkdir()
        seen = {}
        for side in (forgecore, demo):
            source = side / package
            if not source.is_dir():
                continue
            for file in sorted(source.glob("*.odin")):
                if file.name in seen:
                    raise SystemExit(f"duplicate source {package}/{file.name}")
                seen[file.name] = side
                shutil.copy2(file, target / file.name)


def copy_ingot(ingot, dest):
    dest.mkdir()
    for entry in sorted(ingot.iterdir()):
        if not entry.is_dir() or entry.name.startswith(".") or entry.name in INGOT_SKIP:
            continue
        if entry.name.endswith(".dSYM"):
            continue
        shutil.copytree(entry, dest / entry.name, symlinks=False,
                        ignore=shutil.ignore_patterns("*.dSYM", ".git", "*.bin", "*.o"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--demo", default="planetforger")
    parser.add_argument("--dest", type=Path, required=True)
    parser.add_argument("--odin", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    dest = args.dest.resolve()
    dest.mkdir()
    forgecore, demo, ingot = root / "forgecore", root / args.demo, root / "ingot"
    copy_union(forgecore, demo, dest)
    # The demo asset tree carries a self-referencing `assets` link; copying it
    # would recurse forever and it is not a compile input.
    shutil.copytree(demo / "assets", dest / "assets", symlinks=True)
    (dest / "assets" / "assets").unlink(missing_ok=True)
    copy_ingot(ingot, dest / "ingot")
    (dest / "build").mkdir()
    hashes = {}
    for file in sorted(dest.rglob("*")):
        if file.is_file():
            hashes[str(file.relative_to(dest))] = sha256(file)
    odin = args.odin.resolve()
    wgpu = (odin.parent / "vendor/wgpu/lib/wgpu-macos-aarch64-release/lib/libwgpu_native.a")
    manifest = dict(
        scope="frozen compile inputs copied before build: union game packages, demo assets, "
              "Ingot collection packages, compiler and pinned wgpu archive",
        repositories={name: dict(head=git(path, "rev-parse", "HEAD"),
                                 dirty=git(path, "status", "--porcelain") != "")
                      for name, path in (("forgecore", forgecore), (args.demo, demo),
                                         ("ingot", ingot))},
        compiler=dict(path=str(odin), sha256=sha256(odin),
                      version=subprocess.run([str(odin), "version"], capture_output=True,
                                             text=True).stdout.strip()),
        wgpu_archive=dict(path=str(wgpu.resolve()), sha256=sha256(wgpu)),
        file_count=len(hashes),
        sha256=hashes,
    )
    (dest / "prebuild-inputs.json").write_text(json.dumps(manifest, indent=1) + "\n")
    print(dest, len(hashes), "files hashed")


if __name__ == "__main__":
    main()
