# Profiling the 120 Hz tail

Measured offscreen on 2026-11-14/15 UTC, Apple M3 Ultra, arm64 macOS
27.0 (26A428), Zig 0.17.0. This follows [the ranking experiment](performance.md).
**Neither this benchmark nor Lean establishes sustained on-screen 120 FPS.**

## What was measured

The existing nine-page fixture still uses 3,000 fake processes, 100 fake bundles,
full histories, pointer motion and periodic deterministic data changes. No app
window, native process action, updater, real application icon, clipboard, or
user configuration is touched. A separate native sampler test reads system
statistics without opening windows or emitting process identities.

Optional `trace` captures frame/build/layout/paint, Metal encode/GPU and render
wall time, process-wide CPU time, faults and context switches. It retains the
first 32 misses per page/run, the true worst wall frame and worst deadline miss.
Summary counts cover **all** frames, not just captured traces. CPU counters
include all threads in the process, not just the calling thread.

`render_residual_ms = max(0, render wall − encode CPU − GPU duration)` is an
accounting remainder, **not a direct GPU queue measurement**. It includes waits,
scheduling, setup/cleanup and instrumentation overhead. New traces separately
report `instrumentation_gap_ms` between frame and render timing brackets;
the resource-counter instrumentation can itself be descheduled. A stage label
identifies the largest observed component, not the cause of a stall. Printed timings are
rounded to 0.0001 ms; summary counts use unrounded values. New traces also emit
an exact `work_over_budget` predicate; historical captures predate that field.

`paced` adds absolute 120 Hz deadline sleeps. A late frame skips elapsed slots
rather than spinning or emitting catch-up bursts. Cheap work can miss a deadline
if it starts late. This is a benchmark-only submission clock, not a replacement
application loop, display-link measurement, or display-presentation timestamp.
The application's demand-driven rendering and two-second sampling stay intact.

## Render tails remain

| Capture | Frames | Work >8.333 ms | Deadline misses | Skipped slots | Worst run p95 wall |
|---|---:|---:|---:|---:|---:|
| Initial unpaced | 54,000 | 21 | — | — | 2.3275 ms |
| Initial paced | 10,800 | 26 | 46 | 85 | 3.9828 ms |
| Final unpaced control | 54,000 | 33 | — | — | 2.3296 ms |
| Final paced control | 10,800 | 26 | 39 | 64 | 3.3375 ms |

All raw runs, including their outliers, are in `benchmarks/tail-{render,paced}-*.jsonl`.
These fixtures do **not** perform native sampling; they are render controls, not
before/after evidence for the temperature optimization below. Their differences
must not be attributed to that change. Roughly ±5% variation is noise here.

The initial worst frame took **44.3822 ms**: frame generation 0.2355 ms,
GPU 0.2175 ms and render residual 43.8984 ms, with zero page faults and five
involuntary switches. Of its 21 over-budget frames, 17 were residual-dominated
and four frame-generation-dominated. The final unpaced worst was 59.3186 ms,
including 35.7392 ms frame wall but only 0.6880 ms process CPU during that phase.
This is consistent with waiting/descheduling, not 35 ms of paint computation;
the exact driver/scheduler cause remains unidentified.

The final paced run still had 39 deadline misses, and worst run p99 wall
**14.2557 ms**. Per-page effective submission rate ranged 114.18–120.03 Hz;
this is not displayed FPS. A scheduling-priority experiment was rejected:
the harness already runs at interactive QoS class 33. Requesting that same
class again is not a justified optimization. The request code was removed;
`tail-qos-*.jsonl` retains those exploratory runs. No application QoS is changed.

## Actual improvement: temperature I/O leaves the UI thread

Native phase timing exposed a different, repeatable stall: synchronous HID
temperature collection occupied most of each two-second GUI sample. Warm
process collection was commonly 4–5 ms, while temperature reads took tens of
milliseconds. Skipping names that contribute to no temperature removes only
5 of 77 event requests on this machine; that alone cannot remove the stall.

The GUI now uses one persistent, event-driven temperature worker:

- It owns its HID client/services and performs no AppKit/UI work. Each batch
  rereads labels and values; no cached labels, readings or reduced sample rate.
- At most one request is outstanding. Busy requests coalesce; an idle worker
  blocks on an event. There is no polling, new timer, or continuous frame loop.
- A release/acquire slot publishes a completed scalar snapshot on the main
  queue. Queued wakes carry non-reused registry ids, never owner pointers, and
  coalesce to at most one queued wake per worker. A frame never waits for HID.
  The main-thread registry is bounded to 32 live workers (normally one); resource
  exhaustion reports unavailable temperatures rather than blocking/falling back.
- Main-thread publication updates the window/menu-bar readout when needed.
  Until first completion, temperatures remain unavailable; later frames may
  show the last completed reading while a refresh is pending. The internal
  system model records its completion timestamp and pending state.
- Pausing freezes displayed readings. A pending batch may finish, but does not
  alter those readings until resume. No further requests start while paused.
- Teardown marks the worker stopped, wakes and joins it, then retires its id
  before freeing state. Already queued wakes find no owner, even if its address
  is reused. There is no pipe/FD cancellation lifetime to manage. A running HID
  read can delay teardown; a stuck OS service has no bounded-latency guarantee.
- Failure leaves temperatures unavailable, rather than blocking frames or
  retry-polling. **MCP explicitly retains synchronous temperature sampling**;
  its request freshness, read-only stdio boundary and idle behavior are unchanged.

### Same-binary native A/B/B/A

Ten native samples per process, about two seconds apart, pumping the headless
main loop between samples. Both modes use the same filtered selector; only
GUI-style temperature scheduling differs. There were 1,379–1,423 real processes.
Ordering/refill is included; no rendering is included. All 40 samples are in
`benchmarks/sampling-{sync,async}-{A,B}.jsonl`, including four cold samples.
Warm statistics use all nine remaining samples in each run, not the best run.

| Mode / run | Warm median main wall | Warm maximum | Warm samples >8.333 ms | Cold main wall |
|---|---:|---:|---:|---:|
| Synchronous A | 80.2418 ms | 127.0320 ms | 9/9 | 97.9507 ms |
| Worker A | 5.4595 ms | 13.3726 ms | 1/9 | 16.4580 ms |
| Worker B | 5.1903 ms | 30.8211 ms | 1/9 | 17.6508 ms |
| Synchronous B | 82.3178 ms | 97.0013 ms | 9/9 | 767.0564 ms |

Pooled warm median: **81.8437 → 5.3890 ms**, about **15.2× lower main-thread
sampling latency (93.4% reduction)**. This is not a 15× CPU-work, rendering, or
whole-application improvement. Native sensor work still took about 74–75 ms
median in the worker; warm main-thread temperature request/publication overhead
was about 0.004 ms. All 18 warm worker samples had available temperature data;
the two cold worker samples correctly had no completed temperature yet.

**Two of 18 warm worker samples still exceeded the entire frame budget**:
13.3726 and 30.8211 ms. Process collection took 11.9265 and 23.6024 ms in those
samples; the latter had only 11.6170 ms process CPU across the whole sample,
so not all of that wall delay is CPU work. Cold collection also exceeds budget,
including the unusually slow 767 ms synchronous sample retained above.

An earlier pipe-notified prototype measured 80.2004 → 6.0642 ms pooled warm
median, with **five of 18** worker samples over budget (worst 11.1780 ms).
Its complete A/B/B/A is retained as `sampling-pipe-*.jsonl`, not silently dropped.
The final id-based protocol avoids pipe/source cancellation lifetimes and uses
no heap-owned queued callback context. Neither version eliminates sampling
outliers. An even earlier exploratory batch with no warm misses is not evidence
of a guaranteed bound. Sampling wall excludes page generation/rendering, so a
sub-budget sample is not proof that the combined frame meets its deadline.

The next concrete CPU target is process collection. Render completion/wake-up
tails, live resize/scroll, cold fonts/icons, and real presentation still need
separate work before claiming sustained 120 FPS. Do not weaken sampling,
availability reporting, or UI correctness to erase benchmark misses.

## Proof and implementation boundary

In the parent nanoui checkout,
`lean-proofs/NanoUI/NanomonTemperatures.lean` adds **20 checked theorems**:
ordered-fold filtering equivalence, ignored-read identity, busy coalescing,
ready-slot preservation, whole-snapshot publication, no exposed publication
or new request after stop, pause/resume behavior, join-before-free safety, and
retired-id lookup/non-reuse properties.
The fold theorem assumes the same supplied per-sensor observations and does
not reassociate additions. It does not assert physically simultaneous reads.

The worker model treats a released/acquired snapshot as one value. Zig atomics,
main-queue serialization, id/pointer integer round trips, join guarantees, and
the native-to-model correspondence are
not verified compiler translations. Differential Zig tests compare all output
float bits, sensor precedence, invalid labels, missing/boundary/nonfinite
values, request order and fresh label reads. Deterministic threaded tests use
injected data (no real sensors) to exercise blocked readers, coalescing,
main-thread notifications, idle behavior, repeat requests, pause/resume,
failure, registry/counter exhaustion, stale wakes, and teardown with the context
actually freed before queued work runs. Lean proves neither hardware liveness
nor FPS. All **52 app tests** pass in Debug and ReleaseFast.

ReleaseSafe and the MCP/optional six-client setup smoke checks pass. App builds
for Linux arm64/x86_64 and Windows, and Linux arm64/Windows test binaries pass
cross-compilation. Parent native/portable test steps and Linux/Windows/iOS
simulator builds pass (framework steps were cache hits). Linux runtime execution
is blocked by the unavailable Docker daemon; Android builds are blocked by the
missing SDK/NDK. Changed-file formatting, diff checks and the 600-line checks pass.

## Reproduce (macOS, hidden/offscreen only)

```sh
cd apps/nanomon
zig build bench-bin -Doptimize=ReleaseFast
zig-out/bin/nanomon-bench 2000 3 cached trace 2> render.jsonl
zig-out/bin/nanomon-bench 1200 1 cached paced 2> paced.jsonl
# Optional final page filter:
zig-out/bin/nanomon-bench 1200 1 cached paced disk 2> disk.jsonl
# Native A/B/B/A; sampling-async uses the GUI worker, sampling is synchronous:
zig-out/bin/nanomon-bench sampling 2> sync-A.jsonl
zig-out/bin/nanomon-bench sampling-async 2> async-A.jsonl
zig-out/bin/nanomon-bench sampling-async 2> async-B.jsonl
zig-out/bin/nanomon-bench sampling 2> sync-B.jsonl
zig build test
zig build test -Doptimize=ReleaseFast
cd ../../lean-proofs && lake build && lake exe nanoui-spec-report
```

Frame counts/repeats/mode retain the bounds documented in `performance.md`.
Tracing adds instrumentation overhead. Native runs observe a changing machine;
repeat them and keep every sample rather than expecting identical temperatures,
process counts or tails. Snapshot age in native output is measured at sample
submission, usually before the new worker result; `-1` means none completed yet.
`temperature_ms` is main-thread phase wall; `sensor_read_ms` is the last complete
sensor batch (background work in async mode), not its CPU time.
