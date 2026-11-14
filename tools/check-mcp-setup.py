#!/usr/bin/env python3
"""Real setup CLI against fake homes/clients only; never touch user configs."""
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

FAKE_CODEX = r'''
import json, os, sys
from pathlib import Path
home = Path(os.environ["HOME"])
root = Path(os.environ["CODEX_HOME"])
assert Path.cwd() == home.resolve() and root == home / ".codex"
assert os.environ["LC_ALL"] == "C"
assert root.is_dir(), "explicit CODEX_HOME must exist before Codex resolves it"
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
config = root / "config.toml"
entry = root / "fixture-entry.json"
text = config.read_text() if config.exists() else ""
if text.startswith("INVALID"):
    print("invalid config", file=sys.stderr)
    sys.exit(2)
args = sys.argv[1:]
if args == ["mcp", "get", "nanomon", "--json"]:
    if not entry.exists():
        print("No MCP server named 'nanomon' found.", file=sys.stderr)
        sys.exit(1)
    print(entry.read_text())
elif len(args) == 6 and args[:4] == ["mcp", "add", "nanomon", "--"] and args[-1] == "mcp":
    assert not entry.exists(), "must not overwrite a custom entry"
    entry.write_text(json.dumps({"name": "nanomon", "enabled": True,
        "transport": {"type": "stdio", "command": args[4], "args": ["mcp"],
                      "env": None, "env_vars": [], "cwd": None}}))
    config.write_text(text + "# nanomon fixture registration\n")
elif args == ["mcp", "remove", "nanomon"]:
    entry.unlink()
    config.write_text(text.replace("# nanomon fixture registration\n", ""))
else:
    raise AssertionError(args)
'''


def check_real_codex(binary):
    """Optional interoperability check; still no real agent configuration."""
    assert shutil.which("codex"), "--real-codex requires an existing Codex CLI on PATH"
    with tempfile.TemporaryDirectory(prefix="nanomon-real-codex-") as home:
        env = {"HOME": home, "PATH": os.environ["PATH"], "LC_ALL": "C"}
        for command, expected in [("status", "not connected"), ("install", "connected"),
                                  ("status", "already connected"), ("install", "already connected"),
                                  ("uninstall", "disconnected")]:
            r = subprocess.run([str(binary), "mcp", command, "--client", "codex"],
                               env=env, text=True, capture_output=True, timeout=20)
            assert r.returncode == 0 and not r.stderr, (r.stdout, r.stderr)
            assert f"Codex: {expected}" in r.stdout, r.stdout
        assert "mcp_servers.nanomon" not in Path(home, ".codex/config.toml").read_text()
        assert json.loads(Path(home, ".nanomon/mcp-setup.json").read_text())["decision"] == "dismissed"
    print("Real Codex CLI interoperability passed using only temporary HOME/CODEX_HOME")


def main():
    args = [arg for arg in sys.argv[1:] if arg != "--real-codex"]
    assert len(args) <= 1, "usage: check-mcp-setup.py [binary] [--real-codex]"
    source = Path(args[0] if args else "zig-out/bin/nanomon").resolve()
    with tempfile.TemporaryDirectory(prefix="nanomon-setup-") as temp:
        base = Path(temp)
        install = base / "installed app with spaces ' snowman ☃"
        install.mkdir()
        executable = install / "nanomon"
        shutil.copy2(source, executable)
        executable = executable.resolve()
        home = base / "home"
        home.mkdir()
        bin_dir = base / "bin"
        bin_dir.mkdir()
        codex = bin_dir / "codex"
        codex.write_text(f"#!{sys.executable}\n" + FAKE_CODEX)
        codex.chmod(0o700)
        env = os.environ.copy()
        env.update(HOME=str(home), PATH=str(bin_dir))
        for key in ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "DISPLAY", "WAYLAND_DISPLAY"):
            env.pop(key, None)

        def run(*args, environment=None):
            result = subprocess.run([str(executable), "mcp", *args], capture_output=True,
                                    text=True, timeout=20, env=environment or env)
            assert result.returncode == 0, (result.stdout, result.stderr)
            assert not result.stderr, result.stderr
            return result.stdout

        # A fresh profile must be created before invoking a real Codex CLI,
        # while status and dry-run must leave a missing profile missing.
        run("install", "--dry-run", "--client", "codex")
        run("status", "--client", "codex")
        assert not (home / ".codex").exists()
        assert "Codex: connected" in run("install", "--client", "codex")
        assert "Codex: disconnected" in run("uninstall", "--client", "codex")
        shutil.rmtree(home / ".codex")
        shutil.rmtree(home / ".nanomon")
        (home / ".claude").mkdir()
        desktop = (home / "Library/Application Support/Claude" if sys.platform == "darwin"
                   else home / ".config/Claude")
        paths = [home / ".claude.json", desktop / "claude_desktop_config.json",
                 home / ".cursor/mcp.json", home / ".gemini/settings.json",
                 home / ".codeium/windsurf/mcp_config.json"]
        original = {"theme": "keep", "mcpServers": {"other": {"command": "keep", "env": {"SECRET": "do not print"}}}}
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(original))
        codex_dir = home / ".codex"
        codex_dir.mkdir()
        toml = codex_dir / "config.toml"
        old_toml = '# preserve comment\nmodel = "keep"\n[mcp_servers.other]\ncommand = "keep"\n'
        toml.write_text(old_toml)

        def snapshot():
            return {str(p.relative_to(home)): p.read_bytes() for p in home.rglob("*") if p.is_file()}

        before = snapshot()
        plan = run("install", "--dry-run")
        assert "would connect" in plan and "no command executed" in plan
        assert snapshot() == before, "Dry run changed files or executed Codex"
        # The default MCP entry point must never auto-register, even with
        # profiles present and an initialized session.
        session = subprocess.run([str(executable), "mcp"], input=json.dumps({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-11-25"}}) + "\n",
            capture_output=True, text=True, env=env, timeout=10)
        assert session.returncode == 0 and not session.stderr
        assert json.loads(session.stdout)["result"]["serverInfo"]["name"] == "nanomon"
        assert snapshot() == before
        connected = run("install")
        assert "do not print" not in connected
        assert "Codex: connected" in connected, connected
        for path in paths:
            data = json.loads(path.read_text())
            assert data["theme"] == original["theme"]
            assert data["mcpServers"]["other"] == original["mcpServers"]["other"]
            assert data["mcpServers"]["nanomon"] == {"command": str(executable), "args": ["mcp"]}
            backups = list(path.parent.glob(path.name + ".nanomon-backup-*"))
            assert len(backups) == 1 and json.loads(backups[0].read_text()) == original
            assert stat.S_IMODE(path.stat().st_mode) == 0o600
            assert stat.S_IMODE(backups[0].stat().st_mode) == 0o600
        assert list(codex_dir.glob("config.toml.nanomon-backup-*"))[0].read_text() == old_toml
        assert json.loads((home / ".nanomon/mcp-setup.json").read_text())["decision"] == "connected"
        sizes = {p: p.read_bytes() for p in paths}
        run("install")
        assert all(p.read_bytes() == text for p, text in sizes.items())
        assert all(len(list(p.parent.glob(p.name + ".nanomon-backup-*"))) == 1 for p in paths)
        run("uninstall")
        assert all(json.loads(p.read_text()) == original for p in paths)
        assert toml.read_text() == old_toml
        assert json.loads((home / ".nanomon/mcp-setup.json").read_text())["decision"] == "dismissed"
        # Preserve invalid JSON, a custom server, and a disabled Codex entry.
        paths[2].write_text("{invalid")
        paths[3].write_text('{"mcpServers":{"nanomon":{"url":"https://example.invalid"}}}')
        (codex_dir / "fixture-entry.json").write_text(json.dumps({
            "name": "nanomon", "enabled": False,
            "transport": {"type": "stdio", "command": str(executable), "args": ["mcp"]}}))
        before_toml = toml.read_bytes()
        result = run("install")
        assert "invalid config; untouched" in result and "custom/disabled" in result
        assert paths[2].read_text() == "{invalid"
        assert json.loads(paths[3].read_text())["mcpServers"]["nanomon"]["url"] == "https://example.invalid"
        assert toml.read_bytes() == before_toml
        toml.write_text("INVALID TOML")
        result = run("install", "--client", "codex")
        assert "setup failed" in result and toml.read_text() == "INVALID TOML"
        custom = env.copy()
        custom["CLAUDE_CONFIG_DIR"] = str(base / "custom-profile")
        assert "custom client config directory" in run("install", "--client", "claude-code", environment=custom)
        assert not (base / "custom-profile").exists()
        print("MCP setup smoke passed: six clients, additive merge, backups, idempotence, dry-run, undo, conflicts, Codex CLI and no startup writes")
    if "--real-codex" in sys.argv:
        check_real_codex(source)


if __name__ == "__main__":
    main()
