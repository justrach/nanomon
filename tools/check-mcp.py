#!/usr/bin/env python3
"""Exercise the real stdio executable without initializing a desktop.

Only starts `nanomon mcp`: never the GUI. On Linux, explicitly unsets the
virtual display too, so a GTK dependency in the headless path is caught.
"""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time


def main():
    executable = str(Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/nanomon").resolve())
    env = os.environ.copy()
    env.pop("DISPLAY", None)
    env.pop("WAYLAND_DISPLAY", None)
    process = subprocess.Popen(
        [executable, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    pending = bytearray()

    def send(message):
        process.stdin.write((json.dumps(message) + "\n").encode())
        process.stdin.flush()

    def receive():
        deadline = time.monotonic() + 20
        while b"\n" not in pending:
            timeout = deadline - time.monotonic()
            assert timeout > 0 and selector.select(timeout), "MCP response timed out"
            chunk = os.read(process.stdout.fileno(), 65536)
            assert chunk, f"MCP exited early: {process.poll()}"
            pending.extend(chunk)
        line, _, rest = pending.partition(b"\n")
        pending[:] = rest
        return json.loads(line)

    def request(request_id, method, params=None):
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        send(message)
        reply = receive()
        assert reply["jsonrpc"] == "2.0" and reply["id"] == request_id, reply
        assert "error" not in reply, reply
        return reply["result"]

    def tool(request_id, name, args):
        result = request(request_id, "tools/call", {"name": name, "arguments": args})
        assert not result["isError"], result
        assert json.loads(result["content"][0]["text"]) == result["structuredContent"]
        return result["structuredContent"]

    try:
        handshake = request(1, "initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "nanomon-smoke", "version": "1"},
        })
        assert handshake["serverInfo"]["name"] == "nanomon"
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        catalog = request(2, "tools/list")["tools"]
        assert {t["name"] for t in catalog} == {
            "get_system", "list_processes", "get_process", "get_history",
        }
        assert all(t["annotations"]["readOnlyHint"] for t in catalog)
        system = tool(3, "get_system", {})
        assert system["meta"]["sample_count"] == 2
        assert system["meta"]["interval_seconds"] >= 0.25
        assert system["memory"]["total_bytes"] > 0
        assert 0 <= system["cpu"]["busy_percent"] <= 100.01
        processes = tool(4, "list_processes", {"query": "nanomon", "limit": 10})
        server = next(p for p in processes["processes"] if p["pid"] == process.pid)
        assert server["memory_bytes"] > 0 and server["cpu_time_ns"] > 0
        assert server["cpu_percent"] is not None
        detail = tool(5, "get_process", {"pid": process.pid})
        assert detail["process"]["pid"] == process.pid
        history = tool(6, "get_history", {"metric": "cpu_user_percent", "max_points": 300})
        assert len(history["points"]) >= 2
        assert history["points"][0]["value"] is None
        assert history["points"][-1]["value"] is not None
        # A notification must neither produce a reply nor trigger a sample.
        send({"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "get_system"}})
        assert request(7, "ping") == {}
        assert not pending
        # Nothing samples or appends history while the client is idle.
        before = tool(8, "get_history", {"metric": "cpu_user_percent", "max_points": 300})
        time.sleep(0.6)
        after = tool(9, "get_history", {"metric": "cpu_user_percent", "max_points": 300})
        assert after["meta"]["sample_count"] == before["meta"]["sample_count"] + 1
        assert len(after["points"]) == len(before["points"]) + 1
        send({"jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": {"name": "kill_process", "arguments": {"pid": process.pid}}})
        assert receive()["error"]["code"] == -32602
        # EOF is the shutdown mechanism; it must not leave any child running.
        process.stdin.close()
        assert process.wait(timeout=10) == 0
        assert not process.stdout.read(), "Unexpected stdout after shutdown"
        stderr = process.stderr.read().decode()
        assert not stderr, stderr
        empty = subprocess.run([executable, "mcp"], input=b"", capture_output=True, timeout=10, env=env)
        assert empty.returncode == 0 and not empty.stdout and not empty.stderr
        oversized = subprocess.run(
            [executable, "mcp"], input=b" " * ((1 << 20) + 64) + b"\n",
            capture_output=True, timeout=10, env=env,
        )
        assert oversized.returncode != 0 and not oversized.stdout, "Unbounded request was accepted"
        print("MCP stdio smoke passed: handshake, tools, live stats, history, read-only boundary, idle, EOF and input bound")
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()


if __name__ == "__main__":
    main()
