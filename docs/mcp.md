# nanomon for agents (MCP)

`nanomon mcp` is a **read-only, headless stdio MCP server** for macOS and
Linux. It uses the same native sampler as nanomon's window: no scraping,
webview, separate monitoring daemon, admin rights or cloud service.

Available in v0.1.10 and newer. The v0.1.9 release binaries do not contain
MCP or agent setup; upgrade before configuring a client.

## Build and connect

```sh
zig build -Doptimize=ReleaseSafe
# An MCP client starts the resulting executable with the argument `mcp`.
# Running it directly waits for newline-delimited JSON-RPC on stdin:
./zig-out/bin/nanomon mcp
```

### One-click setup after installing

Move the app/binary to its permanent location first (on macOS, drag it to
Applications and launch it there). On the first normal GUI launch, nanomon
shows **Connect agents** with the detected client names and a data-sharing
notice. **Connect detected clients** registers it in their user configs;
**Not now** remembers the dismissal. The sidebar's **Agent connections…**
button lets you retry later, including when a new client is installed.

A DMG's drag-and-drop copy cannot execute an installer hook. This first-launch
consent is intentional: connecting exposes local machine/process metadata
to the clients and potentially their model providers, so it is not silently
enabled just by downloading or copying an app. Startup, app updates, MCP
sessions and `--nanoui-*` development checks never install connections.
Removing a connection does not make a later launch silently restore it.

### Terminal or installer setup

```sh
./zig-out/bin/nanomon mcp install --dry-run
./zig-out/bin/nanomon mcp install
./zig-out/bin/nanomon mcp status
./zig-out/bin/nanomon mcp uninstall
# Explicitly target a client, even without an existing profile:
./zig-out/bin/nanomon mcp install --client cursor
```

For an installed Mac app, replace `./zig-out/bin/nanomon` with
`/Applications/nanomon.app/Contents/MacOS/nanomon`. Installer scripts can run
`mcp install` **after** placing the binary at its final path; it is an explicit
opt-in command, not something the server invokes. Running from a disk image,
App Translocation or Zig's build cache is rejected to avoid broken commands.
`mcp help` lists all commands and client keys. Setup supports macOS and Linux.

Default detection looks only for existing user configs/profile directories
(or a Codex CLI on PATH), never projects. It does not launch agents to find
them. Supported targets, relative to `$HOME`:

| `--client` | User config |
| --- | --- |
| `claude-code` | `.claude.json` (also detected by `.claude/`) |
| `claude-desktop` | `Library/Application Support/Claude/claude_desktop_config.json` on macOS; `.config/Claude/claude_desktop_config.json` on Linux |
| `cursor` | `.cursor/mcp.json` |
| `gemini` | `.gemini/settings.json` |
| `windsurf` | `.codeium/windsurf/mcp_config.json` |
| `codex` | `.codex/config.toml`, through the official Codex CLI |

Setup is deliberately conservative:

- Only the `nanomon` server entry changes. Other servers and settings are
  preserved, including exact numeric values; JSON is reformatted with two
  spaces. Rerunning an already-connected setup is a no-op for its config.
- Existing changed files get private sibling backups named
  `<filename>.nanomon-backup-<random>`. New JSON files/backups are mode `0600`
  and newly created profile directories `0700`. Existing JSON files are also
  replaced with private files. Backups may contain credentials from other
  servers: keep them private or delete them once no longer needed.
- Invalid/non-object/over-1-MiB configs, JSON with comments, symlinked config
  files/directories, and custom or disabled `nanomon` entries are skipped,
  not repaired or replaced. Per-client results explain skips; other clients
  can still connect. Keep clients from editing settings during setup: JSON
  uses atomic replacement and stale-content checks, not a cross-app lock.
- Ownership is conservative: the JSON entry must contain only this exact
  executable's `command` and `args: ["mcp"]`. A moved executable or a customized
  entry needs manual review/removal; setup will not take it over. Uninstall
  removes only matching entries, never whole client configs or other servers.
- Codex is inspected/edited with bounded `codex mcp get/add/remove` commands,
  never hand-appended TOML or a login shell. Its existing CLI must support
  `mcp get nanomon --json`. Common native install locations are also checked
  when a Codex profile exists, because GUI PATHs can be minimal. A wrapper
  requiring a missing runtime may need terminal setup instead. Codex dry runs
  execute **no command** and say they would check/update rather than guessing
  whether an entry already exists. Explicit `status` uses its read command.
- A set `CODEX_HOME` or `CLAUDE_CONFIG_DIR` skips that client instead of writing
  to the wrong profile. Configure custom locations manually.
- `--dry-run` writes nothing, creates no directories/backups/preferences and
  launches no child process. Successful CLI installs and CLI uninstalls remember
  the explicit choice in `.nanomon/mcp-setup.json` so subsequent GUI launches
  do not repeat the offer.
  This preference contains no monitoring data. Manual setup remains available.

Restart connected clients afterward; their own tool-approval policies still
apply. Nothing grants an agent extra OS permissions or process-control tools.

### Manual connection

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
GUI [automatic updates](updates.md) do not restart an existing MCP process or
change client configs; restart the client's server to use a newly installed
binary. The MCP entry point never starts an updater.
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
python3 tools/check-mcp-setup.py
# Optional, if Codex is installed: real CLI, still only a temporary HOME.
python3 tools/check-mcp-setup.py --real-codex
```

The tests cover negotiation, the read-only catalog, malformed requests,
argument limits, filtering, pagination, escaping, unavailable counters,
history gaps, real samples, an actual stdio client, idle behavior and EOF.
The smoke client removes `DISPLAY`/`WAYLAND_DISPLAY` on Linux and never
starts a window on macOS. Setup tests use only temporary homes and fake
clients, covering first-launch consent, additive merge, exact numbers, limits,
backups, idempotence, dry-run, undo, opt-out, symlinks, conflicts and delegated
Codex commands. They never configure real agents. All run in CI.
