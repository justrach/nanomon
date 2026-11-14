#!/usr/bin/env python3
"""Verify a draft's downloads before making it latest. Headless, temp files only."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile


def run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=90, check=True, **kwargs).stdout


def check_updater(root, checker, version, tag):
    releases = json.loads(run(["gh", "release", "list", "--repo", "justrach/nanomon", "--limit", "100",
                              "--json", "tagName,isDraft,isPrerelease"]))
    current = tuple(map(int, version.split(".")))
    prior = [r["tagName"] for r in releases if not r["isDraft"] and not r["isPrerelease"]
             and re.fullmatch(r"v\d+\.\d+\.\d+", r["tagName"])
             and (0, 1, 10) <= tuple(map(int, r["tagName"][1:].split("."))) < current]
    assert prior, "need an earlier signed stable release as the updater baseline"
    old_tag = max(prior, key=lambda t: tuple(map(int, t[1:].split("."))))
    old_dir = root / "baseline"
    old_dir.mkdir()
    run(["gh", "release", "download", old_tag, "--repo", "justrach/nanomon", "--pattern", "nanomon-macos-arm64.zip", "--dir", str(old_dir)])
    run(["ditto", "-x", "-k", str(old_dir / "nanomon-macos-arm64.zip"), str(old_dir)])
    run(["codesign", "--verify", "--deep", "--strict", str(old_dir / "nanomon.app")])
    (root / "update-fixture").write_text("nanomon headless update fixture\n")
    for case in ("accept", "checksum", "version", "team"):
        work = root / case
        work.mkdir()
        app = work / "nanomon.app"
        run(["ditto", str(old_dir / "nanomon.app"), str(app)])
        feed = work / "feed"
        feed.mkdir()
        archive = feed / "nanomon-macos-arm64.zip"
        if case == "team":
            candidate = work / "candidate/nanomon.app"
            run(["ditto", str(root / "nanomon.app"), str(candidate)])
            run(["codesign", "--force", "--deep", "--sign", "-", str(candidate)])
            run(["ditto", "-c", "-k", "--keepParent", str(candidate), str(archive)])
        else:
            import shutil
            shutil.copyfile(root / archive.name, archive)
        claimed = "99.0.0" if case == "version" else version
        digest = "0" * 64 if case == "checksum" else hashlib.sha256(archive.read_bytes()).hexdigest()
        (feed / "manifest.json").write_text(json.dumps({"version": claimed, "files": {archive.name: {"sha256": digest}}}))
        env = {"HOME": str(root / "home"), "PATH": os.environ.get("PATH", ""), "LC_ALL": "C",
               "NANOMON_UPDATE_TEST_ROOT": str(root)}
        run([str(checker), str(app), feed.as_uri(), old_tag[1:], claimed, case], env=env)
        installed = run(["plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", str(app / "Contents/Info.plist")]).strip()
        assert installed == (version if case == "accept" else old_tag[1:]), case
        assert not (work / "cache/updates" / claimed).exists(), "kept an installed/refused candidate"
    print(f"Real shared updater: {old_tag} -> {tag} installed; bad checksum, version and team refused (temporary copies, no relaunch)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    parser.add_argument("--require-linux-manifest", action="store_true")
    parser.add_argument("--update-check", type=lambda s: Path(s).resolve(), help="built nanomon-update-check executable")
    args = parser.parse_args()
    assert re.fullmatch(r"v\d+\.\d+\.\d+", args.tag), "invalid tag"
    version = args.tag[1:]
    with tempfile.TemporaryDirectory(prefix="nanomon-release-") as work:
        root = Path(work).resolve()
        run(["gh", "release", "download", args.tag, "--repo", "justrach/nanomon", "--dir", work])
        manifest = json.loads((root / "manifest.json").read_text())
        assert manifest["version"] == version
        archives = ["nanomon-macos-arm64.zip", "nanomon-linux-aarch64.tar.gz", "nanomon-linux-x86_64.tar.gz"]
        for name in archives:
            archive = root / name
            assert archive.is_file() and archive.stat().st_size > 0, name
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            if name.endswith(".zip") or args.require_linux_manifest:
                assert manifest["files"][name]["sha256"] == digest, name
            if name.endswith(".tar.gz"):
                assert (root / (name + ".sha256")).read_text().split()[0] == digest, name
                with tarfile.open(archive) as tar:
                    members = tar.getmembers()
                    assert any(m.name == "nanomon" and m.isfile() and m.mode & 0o111 for m in members)
                    assert all(not PurePosixPath(m.name).is_absolute() and ".." not in PurePosixPath(m.name).parts
                               and (m.isfile() or m.isdir()) for m in members), name
        dmg = root / "nanomon-macos-arm64.dmg"
        assert hashlib.sha256(dmg.read_bytes()).hexdigest() == (root / (dmg.name + ".sha256")).read_text().split()[0]
        with zipfile.ZipFile(root / archives[0]) as z:
            assert all(not PurePosixPath(i.filename).is_absolute() and ".." not in PurePosixPath(i.filename).parts
                       and not stat.S_ISLNK(i.external_attr >> 16) for i in z.infolist())
        if sys.platform == "darwin":
            run(["/usr/bin/ditto", "-x", "-k", str(root / archives[0]), work])
            app = root / "nanomon.app"
            run(["codesign", "--verify", "--deep", "--strict", str(app)])
            signature = subprocess.run(["codesign", "-dv", "--verbose=2", str(app)], capture_output=True, text=True, check=True)
            assert "TeamIdentifier=WWP9DLJ27P" in signature.stderr
            assert run(["plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", str(app / "Contents/Info.plist")]).strip() == version
            for item in (app, dmg):
                for attempt in range(4):
                    try:
                        run(["xcrun", "stapler", "validate", str(item)])
                        break
                    except subprocess.CalledProcessError:
                        if attempt == 3:
                            raise
                        time.sleep(5)
            run(["spctl", "--assess", "--type", "execute", str(app)])
            run(["hdiutil", "verify", str(dmg)])
            # The launch checker passes -g and --nanoui-snapshot; no input
            # events, user defaults or installed /Applications copies touched.
            run([sys.executable, str(Path(__file__).resolve().parent.parent / "macos/check-launch.py"), str(app)])
            binary = app / "Contents/MacOS/nanomon"
            env = {"HOME": str(root / "home"), "PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}
            Path(env["HOME"]).mkdir()
            if tuple(map(int, version.split("."))) >= (0, 1, 11):
                assert run([str(binary), "--version"], env=env).strip() == "nanomon " + version
            message = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}}) + "\n"
            reply = run([str(binary), "mcp"], env=env, input=message)
            assert json.loads(reply)["result"]["serverInfo"]["version"] == version
            if args.update_check:
                check_updater(root, args.update_check, version, args.tag)
        print(f"Verified {args.tag}: all archives/checksums, manifest, and native signed/notarized headless bundle on {platform.system()}")


if __name__ == "__main__":
    main()
