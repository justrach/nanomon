#!/usr/bin/env python3
"""Real stdio MCP + temporary Git fixtures; sandbox/namespace prevents personal repo reads."""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/nanomon")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--linux-namespace", action="store_true", help="CI only: sudo -n unshare mount/PID namespace")
    args = parser.parse_args()
    binary = args.binary.resolve()
    with tempfile.TemporaryDirectory(prefix="nanomon-mcp-worktrees-") as tmp:
        root = Path(tmp).resolve()
        home = root / "home"
        home.mkdir()
        env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "LC_ALL": "C",
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
               "COMMAND_LINE_INSTALL": "1"}
        repo = root / "repo"
        repo.mkdir()

        def git(*cmd):
            return subprocess.run(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", str(repo), *cmd],
                                  env=env, check=True, capture_output=True, text=True, timeout=15).stdout

        git("init", "-b", "main")
        git("config", "user.name", "Temporary MCP Fixture")
        git("config", "user.email", "fixture@example.invalid")
        (repo / "fixture.txt").write_text("temporary fixture only\n")
        git("add", "fixture.txt")
        git("commit", "-m", "temporary fixture")
        for name in ("old", "locked", "missing"):
            git("worktree", "add", "-b", name, str(root / name))
        git("worktree", "lock", str(root / "locked"))
        shutil.rmtree(root / "missing")  # Only our newly-created temp fixture.
        past = time.time() - 30 * 86400
        for name in ("old", "locked"):
            os.utime(root / name, (past, past))
        executable = root / "nanomon"
        shutil.copy2(binary, executable)
        if sys.platform == "darwin":
            # Block personal files and all non-fixture .git metadata, while
            # leaving system libraries and anonymous stdio pipes available.
            profile = root / "sandbox.sb"
            exception = f'(require-not (subpath {json.dumps(str(root))}))'
            profile.write_text('(version 1)\n(allow default)\n'
                               '(deny file-read-data (require-all (require-any '
                               '(subpath "/Users") (subpath "/Volumes") '
                               '(subpath "/private/var/folders") (regex #"/[.]git(/|$)")) '
                               f'{exception}))\n'
                               '(deny file-write* (require-all (require-any '
                               '(subpath "/Users") (subpath "/private/var/folders")) '
                               f'{exception}))\n')
            # Prove the deny boundary using a second temporary directory,
            # never a personal file. Fail closed if the profile stops working.
            with tempfile.TemporaryDirectory(prefix="nanomon-mcp-blocked-") as blocked:
                guard = Path(blocked).resolve() / ".git"
                guard.mkdir()
                (guard / "HEAD").write_text("must not be read\n")
                check = subprocess.run(["/usr/bin/sandbox-exec", "-f", str(profile), "/bin/cat", str(guard / "HEAD")],
                                       env=env, capture_output=True, timeout=10)
                assert check.returncode != 0 and not check.stdout, "sandbox allowed non-fixture Git contents"
            command = ["/usr/bin/sandbox-exec", "-f", str(profile), str(executable), "mcp"]
        elif sys.platform == "linux" and args.linux_namespace:
            # Fresh /proc contains only the temporary server and supervisor.
            command = ["sudo", "-n", "unshare", "--mount", "--pid", "--fork", "--mount-proc",
                       "env", *[f"{k}={v}" for k, v in env.items()], str(executable), "mcp"]
        else:
            raise SystemExit("Refusing unisolated discovery: use macOS sandbox or CI --linux-namespace")
        proc = subprocess.Popen(command, cwd=repo, env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        selector = selectors.DefaultSelector()
        selector.register(proc.stdout, selectors.EVENT_READ)
        receipts = []
        counter = 0

        def request(method, params=None):
            nonlocal counter
            counter += 1
            body = {"jsonrpc": "2.0", "id": counter, "method": method}
            if params is not None:
                body["params"] = params
            proc.stdin.write((json.dumps(body) + "\n").encode())
            proc.stdin.flush()
            if not selector.select(40):
                raise AssertionError(f"MCP timeout: {method}")
            line = proc.stdout.readline()
            if not line:
                raise AssertionError(f"MCP exited {proc.wait()}: {proc.stderr.read(4096)!r}")
            reply = json.loads(line)
            assert reply["id"] == counter, reply
            receipts.append({"request": body, "response": reply})
            return reply

        def call(name, arguments):
            result = request("tools/call", {"name": name, "arguments": arguments})["result"]
            assert not result.get("isError"), result
            payload = result["structuredContent"]
            assert json.loads(result["content"][0]["text"]) == payload
            return payload

        try:
            initialized = request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                                  "clientInfo": {"name": "isolated-storage-check", "version": "1"}})
            catalog = request("tools/list")["result"]["tools"]
            assert {t["name"] for t in catalog} == {"get_system", "list_processes", "get_process", "get_history", "list_worktrees"}
            assert all(t["annotations"]["readOnlyHint"] and not t["annotations"]["destructiveHint"] for t in catalog)
            storage = call("get_system", {})["storage"]
            native = os.statvfs("/")
            assert storage and storage["total_bytes"] == native.f_blocks * (native.f_frsize or native.f_bsize), storage
            all_rows = call("list_worktrees", {"stale_only": False, "limit": 200})
            entries = all_rows["worktrees"]
            assert {e["path"] for e in entries} == {str(repo), *[str(root / n) for n in ("old", "locked", "missing")]}, all_rows
            assert all(e["status_checked"] is False and e["prunable"] is False and e["dirty"] is None for e in entries)
            by_branch = {e["branch"]: e for e in entries}
            assert by_branch["main"]["is_primary"] and by_branch["locked"]["locked"]
            assert by_branch["missing"]["missing"] and by_branch["missing"]["size_bytes"] == 0
            assert by_branch["old"]["size_bytes"] is None and "untouched" in by_branch["old"]["reasons"]
            stale = call("list_worktrees", {})
            assert stale["total_matches"] == stale["stale_count"] == 3 and stale["stale_bytes"] is None
            page = call("list_worktrees", {"stale_only": False, "limit": 1, "offset": 1})
            assert len(page["worktrees"]) == 1 and page["total_matches"] == 4 and page["next_offset"] == 2
            bad = request("tools/call", {"name": "list_worktrees", "arguments": {"path": "/"}})
            assert bad["error"]["code"] == -32602
            denied = request("tools/call", {"name": "prune_worktrees", "arguments": {"dry_run": False}})
            assert denied["error"]["code"] == -32602
            # Neither the catalog nor the calls can remove even this clean fixture.
            assert (root / "old/fixture.txt").read_text() == "temporary fixture only\n"
            assert git("show-ref", "--verify", "refs/heads/old")
            result = {"disclosure": "Actual production stdio MCP. Storage is live; Git repositories are temporary fixtures. No agent registration or cleanup tool.",
                      "server": initialized["result"]["serverInfo"],
                      "tools": [t["name"] for t in catalog], "storage": storage,
                      "worktrees": stale, "receipts": receipts}
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps({"server": result["server"], "tools": result["tools"], "storage": storage,
                              "temporary_worktrees": stale["total_matches"], "cleanup_tool": False}, indent=2))
        finally:
            if proc.poll() is None:
                proc.stdin.close()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
            selector.close()
            if proc.returncode != 0:
                raise AssertionError((proc.returncode, proc.stderr.read(4096)))


if __name__ == "__main__":
    main()
