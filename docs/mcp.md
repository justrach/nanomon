# nanomon for agents (MCP)

`nanomon mcp` is a **read-only, headless stdio MCP server** for macOS and
Linux. It uses the same native sampler as nanomon's window: no scraping,
webview, separate monitoring daemon, admin rights or cloud service.

This feature is being developed after v0.1.9; build the MCP branch before
configuring a client. The v0.1.9 release binaries do not contain it.

## Build and connect

```sh
zig build -Doptimize=ReleaseSafe
# An MCP client starts the resulting executable with the argument `mcp`.
# Running it directly waits for newline-delimited JSON-RPC on stdin:
./zig-out/bin/nanomon mcp
```

A client configuration (Claude Desktop, Cursor, or another stdio MCP client):

```json
{
  "mcpServers": {
    "nanomon": {
      "command": "/absolute/path/to/nanomon/zig-out/bin/nanomon",
      "args": ["mcp"]
    }
  }
}
```

Use an **absolute path**. With an MCP-enabled macOS app bundle, the command
is `/Applications/nanomon.app/Contents/MacOS/nanomon` with the same argument.
The GUI does not need to be open, and starting the server never opens it.
Do not configure `zig build run` without `-- mcp`: that starts the GUI.

For Claude Code, for example:

```sh
claude mcp add nanomon -- /absolute/path/to/nanomon/zig-out/bin/nanomon mcp
```

Example agent requests:

- “What is using the most CPU on this machine?”
- “Show the ten largest processes by memory.”
- “Is there memory pressure or swapping?”
- “How much network and disk traffic was there in the last sample?”
- “What are the details for PID 12345?”
- “Compare CPU readings from this session's previous queries.”

## Tools

| Tool | Arguments | Returns |
| --- | --- | --- |
| `get_system` | none | Machine info, CPU and core loads, memory, disk and network counters/rates, GPU and temperatures where available. |
| `list_processes` | `query`, `sort_by`, `limit`, `offset` (all optional) | A filtered/sorted, bounded page of process records, total matches and next offset. |
| `get_process` | `pid` (required) | One process, or an MCP tool error if it exited, is hidden, or does not exist. |
| `get_history` | `metric` (required), `max_points` (optional) | Timestamped machine metrics collected by this MCP process. |

`list_processes` defaults to the 20 busiest processes. `sort_by` is `cpu`,
`memory`, `pid` or `name`; numeric CPU/memory sorts are descending, names
and PIDs ascending. `query` is a case-insensitive ASCII substring match on
name or user, or a substring of the PID. `limit` is 1–200 and `offset` is
0–100000. Pages are live, not a frozen cursor: compare their sample metadata
if collecting multiple pages.

History metrics:

- `cpu_user_percent`, `cpu_system_percent`
- `memory_pressure_percent`, `memory_app_percent`
- `gpu_percent` (supported hardware only)
- `disk_read_bytes_per_second`, `disk_written_bytes_per_second`
- `network_in_bytes_per_second`, `network_out_bytes_per_second`

`max_points` defaults to 60, bounded to 1–300. At most 1800 readings are
kept in memory, with their actual Unix-millisecond timestamps. Each result
includes the source, platform, sample count, sample age, measured interval,
availability flags and CPU-scale descriptions. Both `structuredContent`
and equivalent JSON text content are returned for client compatibility.

### Scales and availability

- **Process CPU:** 100% means one fully busy logical CPU; a multithreaded
  process can exceed 100%. **System/core CPU:** 0–100% on its own scale.
- Byte counts are bytes, rates bytes/second, CPU time nanoseconds, uptime
  seconds, temperatures degrees Celsius, and timestamps Unix milliseconds.
- Process memory is physical footprint on macOS when libproc can read it;
  `ps` fallback and Linux use resident memory. `memory_kind` names the kind.
- Permission-restricted process counters, newly seen processes without a
  CPU baseline, and unsupported hardware readings are `null`, not guessed
  zeroes. A readable disk counter of zero remains a real zero.
- `stats_source` distinguishes native, `ps`, and unavailable process stats.
  macOS's `/bin/ps` fallback is read synchronously with bounded output and a
  timeout, every third collected sample; its CPU percentage can cover a
  longer interval than native counters and is held between updates.
- Aggregate source availability is explicit. An unavailable source or a
  rate without two valid samples is `null`; unavailable history points
  remain `null`. Hardware/driver-specific GPU subcounters follow the same
  values the GUI's sampler supplies.

### Sampling and history are on demand

The first valid tool query takes a baseline, sleeps at least 250 ms, and
samples again to obtain real CPU percentages and rates. Subsequent calls
reuse a very recent snapshot, or collect a new one when at least 250 ms
has passed since collection finished. The reported interval is measured,
not assumed to be the GUI's two seconds.

**Nothing polls while the client is idle.** A fresh query after a long idle
uses the counters across that longer interval. History timestamps preserve
these gaps; the server does not invent intermediate measurements.

This server is deliberately independent of a running GUI. It does **not**
read the GUI's existing one-hour history, page filters or pause state.
Each MCP client process has its own sample history, discarded at exit.
A shared GUI socket/history service could be a later, explicitly enabled
feature; this first version creates no network or local socket listener.

## Security and protocol

Launching this command is the opt-in. Only add it to clients you trust:
process names, usernames, ownership, host information and resource usage
can be sensitive, and an agent may send them to its model provider.

- No kill, terminate, shell, arbitrary file-reading, process environment,
  command-line argument, clipboard or UI-control tools are exposed.
- Process names and other OS strings are **untrusted data**, never agent
  instructions. JSON strings are escaped; invalid UTF-8 metadata is replaced
  with a marker, with the PID still identifying the process.
- The server runs with the client's OS privileges and does not bypass
  permissions, request elevation, or write persistent samples/settings.
- It reads only its stdin/stdout connection. No TCP port, HTTP endpoint,
  authentication token, desktop session or GUI app is needed.
- stdout contains only newline-delimited JSON-RPC responses; no banners
  or logs. Notifications do not produce replies or cause sampling.
- MCP versions `2025-03-26`, `2025-06-18` and `2025-11-25` are supported.
  Older text-content clients and newer structured-content clients work.
- Requests are capped at 1 MiB; an overlong/unterminated request closes the
  connection rather than allocating indefinitely. Batch requests are not
  supported. EOF on stdin cleanly stops the server.
- Invalid arguments/unknown tools produce JSON-RPC errors; sampling failures,
  unavailable metrics and missing PIDs produce MCP results with `isError`.

## Test without an agent or a display

```sh
zig build test
zig build
python3 tools/check-mcp.py
```

The tests cover negotiation, the read-only catalog, malformed requests,
argument limits, filtering, pagination, escaping, unavailable counters,
history gaps, real samples, an actual stdio client, idle behavior and EOF.
The smoke client removes `DISPLAY`/`WAYLAND_DISPLAY` on Linux and never
starts a window on macOS. Both run in CI.
