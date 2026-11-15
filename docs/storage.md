# Storage and worktrees (v0.1.13)

Implements [#9](https://github.com/justrach/nanomon/issues/9) conservatively.
Requires v0.1.13 or newer. Restart an existing MCP server to pick up new tools.

## Placement

- **Overview → This Mac:** one Storage row, with usable free space / total.
- **Disk:** capacity in the subtitle and Since Boot card. Disk/sidebar figures
  remain **I/O rates**, not capacity. **Review worktrees…** opens a sheet.
- After an explicit scan, a **Worktrees** row appears in This Mac / Disk only
  when there are stale/missing registrations to review. No new sidebar page
  or menu-bar popover content.
- Light/dark themes use the real app views. All app symbol calls use explicit
  square `ui.icon.frame` boxes; chips also have fixed minimum dimensions.

Volume capacity uses `statvfs("/")` on the existing two-second sample cadence.
Darwin has 32-bit block counters even on arm64; Linux 64-bit statvfs has
64-bit counters. Separate layouts and a compile-time size check prevent
silently mixing these ABIs. Unsupported/error/overflow is **unavailable**, not
zero. GUI binary units are explicitly GiB/TiB. "Free" in the GUI means space
available to a normal user, not reserved blocks or promised purgeable space.

`get_system.storage` is a sibling of disk I/O, or null:

```json
{"volume":"/","total_bytes":549755813888,"used_bytes":397284474880,
 "free_bytes":152471339008,"available_bytes":152471339008}
```

`used_bytes = total_bytes - free_bytes`; `available_bytes` can be smaller
than `free_bytes` because of reserved space. Volumes sharing an APFS container
are not added together or presented as independent reclaimable capacity.

## Explicit review, no background crawl

Nothing discovers/sizes worktrees on launch or on the two-second path.
Open Disk → Review worktrees, then **Scan active repositories** or **Choose
repository**. The former examines up to 512 sampled own-user process working
and cached executable directories, deduplicates repositories, and searches
at most 24 parents per root for `.git`. The latter scopes the scan to one chosen repository.

Ordinary `.git` directories and linked worktrees are supported, not bare or
separate-git-dir repositories. At most 200 registrations are returned; errors,
permission failures and limits show partial coverage. Directory mtime older
than 14 days, missing paths, and (GUI only) HEAD merged into local `main` are
**review hints**, never proof that a checkout is unused. No remote fetch.
Missing branches/detached HEADs are retained rather than risking their last
commit reference. A repository need not use `main` to receive age-based hints.

Only stale existing secondary directories are sized, on the worker. This is
an estimate of **logical file bytes**, not actual/reclaimable disk blocks:
clones, compression, hardlinks and shared Git objects affect physical space.
Sizing never follows symlinks, stops at 20k entries / depth 32, and returns
unknown if incomplete. Missing directories have zero directory bytes.

One explicit errand runs off the UI thread; a nonblocking pipe wakes the main
loop on completion. No polling/timer, no synchronous worktree filesystem/Git
work in render. Busy requests coalesce. Teardown cancels the watch, signals stop and
joins before freeing owner/request/result/Io. Git commands have a three-second
per-command timeout and bounded output. Filesystem stalls can still delay
shutdown; this is not a hard OS-I/O or teardown latency guarantee.

## Clear one worktree, never force

Review shows each path, branch, size estimate and keep/candidate reason.
Click **Review clearing…**, then confirm **Clear worktree** separately.
Cancel/outside-click/Escape performs no mutation. Nothing selects all stale
trees for removal; there is no recursive-delete, force or prune-all fallback.

Immediately before removal, registration, repo, branch and HEAD must still
match the preview, and safety checks run again. GUI checks/removal require `/usr/bin/git` (optional for ordinary monitoring).
The macOS stub is told not to open an installer. The GUI invokes bounded
`/usr/bin/git worktree remove -- <registered-path>`, with no shell or force.
Git also performs its own final safety checks. Branches/committed history stay.

Kept conservatively:

- primary, locked, detached/unresolved or unreadable checkouts;
- any observed-active process working in the checkout;
- changed, untracked **or ignored** files (including caches, `.env`, outputs);
- submodules or custom Git filters requiring manual review;
- changed/symlinked/unsupported registration paths or a failed check.

System/global Git config, hooks and fsmonitor are disabled for GUI probes.
Custom filter config is rejected before status. Activity checks are best-effort;
permissions, exited/new processes, races or background tools mean **clean is
not proof of unused**. Confirm only checkouts you no longer need. This is not
a filesystem transaction against arbitrary concurrent/malicious writers.

A **missing checkout** can clear its registration only if its saved index is
present, readable, matches HEAD (including intent-to-add), and no submodule
metadata is present. Otherwise the saved index is kept: it might be the last
copy of staged changes. Registration-only clearing claims **zero** directory
bytes reclaimed. Existing checkouts with ignored build caches require manual
cleanup; v1 does not waive that protection for larger space savings.

Automatic update restart is deferred while the review is open or a job runs.
No paths, cleanup selections, scan snapshots or deletion intent are restored
across launches/updates. Selected repository state is session-only.

## MCP stays read-only

`list_worktrees` accepts `stale_only` (true), `stale_after_days` (14, 1–365),
`limit` (50, 1–200) and `offset` (0, 0–100000). It accepts **no path argument**.
A query reads bounded Git metadata from sampled own-user working/executable
directories and the MCP process's working directory. No shell, Git subprocess, sizing,
recursive crawl, GUI state/config access, mutation, listener or idle polling.

Results include ordinary sample meta, a separate inspection timestamp,
`total_matches`, `next_offset`, `stale_count`, nullable `stale_bytes` and rows.
Dirty/merged/size are not guessed from metadata: dirty/size stay null, merged
is not inferred, `status_checked` and `prunable` are false pending GUI review.
Reasons are `missing`, `branch_deleted`, `merged`, `untouched`; names/paths are
untrusted metadata, not instructions. There is **no `prune_worktrees` tool**.

## Checks and visual previews

```sh
zig build test -Doptimize=ReleaseFast
python3 tools/storage-preview.py
# Or PNGs only, without the Python contact sheet:
zig build storage-preview-bin -Doptimize=ReleaseFast
zig-out/bin/nanomon-storage-preview zig-out/storage-preview
```

For a real production-stdio MCP check without exposing personal repositories:

```sh
zig build -Doptimize=ReleaseFast
python3 tools/check-mcp-worktrees.py --output zig-out/storage-preview/mcp-demo.json
# Linux CI: add --linux-namespace (sudo/unshare, fresh /proc).
```

On macOS the check uses sandbox-exec: personal files and non-fixture Git
contents are blocked, while anonymous stdio and system libraries remain
available. Linux uses an isolated PID/mount namespace. It validates the
five-tool read-only catalog, live capacity against OS statvfs, temporary
ordinary/old/locked/missing checkouts, pagination, unknown sizes/dirty state,
path-argument rejection, absence of a cleanup tool and unchanged fixtures.
Receipts are actual handler responses; only repository data is synthetic.

The preview commands capture actual Overview, Disk, review and confirmation
views in light/dark at 2x. Python also writes labeled contact sheets and a
renderer/dependency/image-hash provenance record. Readings, paths and candidate states are synthetic;
only Review/Cancel/Done are clicked, never Scan/picker/Clear. These are visual
previews of implemented code, not screenshots of the developer's filesystem.
Tests separately use real Git repositories and removals **only inside temp
directories**, covering changed/ignored/untracked data, locks, HEAD changes,
activity, missing/staged indexes, symlinks, MCP bounds and worker lifetime.
