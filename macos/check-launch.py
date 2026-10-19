#!/usr/bin/env python3
"""Check a bundle through LaunchServices, without showing a window."""
import pathlib
import subprocess
import sys
import tempfile


def check(bundle):
    bundle = pathlib.Path(bundle).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="nanomon-launch-") as tmp:
        snapshot = pathlib.Path(tmp) / "snapshot.png"
        result = subprocess.run(
            ["/usr/bin/open", "-n", "-W", str(bundle), "--args",
             "--nanoui-snapshot=" + str(snapshot), "--nanoui-wait=2"],
            cwd="/", capture_output=True, text=True, timeout=60,
        )
        if result.returncode != 0:
            detail = result.stderr.replace(str(bundle), "<bundle>").strip()
            raise RuntimeError("LaunchServices rejected the app (exit %d): %s" %
                               (result.returncode, detail))
        # open can succeed even if the app crashes immediately afterwards.
        if not snapshot.is_file() or snapshot.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError("The app did not render its first frame")
    print("Bundle launch and offscreen rendering passed.")


if __name__ == "__main__":
    check(sys.argv[1])
