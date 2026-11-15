# 120 Hz performance and proof-backed rankings

## Result

**Follow-up:** [slow-frame profiling and the temperature worker](tail-latency.md)
finds a real native-sampling stall and cuts pooled warm main-thread sampling
median from **81.84 to 5.39 ms**. Two of 18 warm worker samples still exceeded
8.333 ms (worst 30.82 ms); neither that result nor the render-only results below guarantees
120 FPS. The original measurements below remain as historical ranking evidence.

The measured **p95 render time fits the 8.333 ms budget** on an Apple M3
Ultra, but rare frames still miss it (details below). This is not a claim of a guaranteed 120 FPS on-screen frame rate: the
benchmark has no window, compositor, display/vsync or live system sampler.
No idle animation/polling was added. Monitoring still samples every two seconds;
input and existing animations drive intermediate frames at the display's pace.

The retained optimization memoizes the small CPU/memory/disk top-process lists.
Its isolated selection work is **148–158× faster**, including one cold miss per
240 frames. However, the original selection costs only 4–6 microseconds with
3,000 processes. Most full-frame differences are **below the 5% noise threshold**;
the larger disk-page difference is confounded by slow reference runs. This is
not a 150× application speedup. No overall FPS gain is claimed.

## Reproduce without a window

Use Zig 0.17.0 on macOS and the pinned nanoui dependency, not a different local
framework revision (which would confound the comparison):

```sh
zig build bench-bin -Doptimize=ReleaseFast
zig-out/bin/nanomon-bench 600 5 compare 2> pages.jsonl
zig-out/bin/nanomon-bench rankings 2> rankings.jsonl
zig build test
```

`bench` is also a run step: `zig build bench -Doptimize=ReleaseFast -- 600 5`.
Arguments are measured frames, repetitions, and `compare` (default), `reference`,
or `cached`. `compare` alternates reference/cache order per repetition in the
**same binary**, avoiding code-layout/toolchain changes between implementations.
The reference path calls the unmodified insertion selector without memoization.

Every page uses its real view, 3,000 synthetic processes across 100 fake bundles,
full 1,800-sample histories, the 1h range, 1100×760 points at 2×, a simulated
120 Hz time step (unpaced, not real-time presentation), 30 warm-up frames and
continuous pointer movement. Ordering/filtering/grouping
is refreshed every 240 frames, with deterministic CPU/history changes to
exercise the ensuing bar animations. Preparing fake samples is outside the
timing; ordering and the resulting frames are included. No native sampling,
agent setup, real icons,
process control, network requests, updater, or real user configuration is used.
Frames always build/layout/paint; they are not retained idle frames.

`cpu_ms` covers frame generation; `encode_ms` and `gpu_ms` measure Metal work.
`wall_ms` includes frame generation **and waiting for Metal completion**. It is
not simply the sum of the phase medians. Percentiles and over-budget counts use
actual per-frame durations, not reciprocals of an averaged FPS. The microbench
alternates uncached/cached order over seven runs, retains their median, consumes
results through an optimizer barrier, and includes invalidation every 240 calls.

## Recorded run

2026-11-14 UTC, Apple M3 Ultra, arm64 macOS 27.0 (26A428), Zig 0.17.0,
ReleaseFast/LLVM, nanoui 0.12.0 at
`a3871f920d4d5c08bdd816bd6de7d1a03bd44f32`. Raw per-run measurements are in
`benchmarks/120hz-pages.jsonl` and `benchmarks/120hz-rankings.jsonl`.

CPU/wall medians below are medians of five run medians. The p95 column is the
**worst run's p95**, not an aggregate percentile. All units are milliseconds.

| Page | CPU reference | CPU cached | Wall cached | Worst p95 wall |
| --- | ---: | ---: | ---: | ---: |
| Overview | 0.1755 | 0.1724 | 1.1987 | 1.4493 |
| Processes | 0.1876 | 0.1872 | 1.2739 | 1.5862 |
| CPU | 0.2440 | 0.2429 | 1.2775 | 1.5372 |
| Memory | 0.2359 | 0.2360 | 1.2685 | 1.6447 |
| GPU | 0.2182 | 0.2190 | 1.0485 | 2.0654 |
| Disk | 0.2686 | 0.2443 | 1.3217 | 2.2896 |
| Network | 0.2203 | 0.2209 | 1.2345 | 2.1951 |
| Apps | 0.1173 | 0.1177 | 1.2139 | 1.4291 |
| About | 0.0282 | 0.0275 | 0.5522 | 1.1953 |

**10 / 27,000 cached-path frames exceeded 8.333 ms (0.037%)**. The reference
path had 23 over-budget frames; this difference is not attributed to the cache.
The worst cached run's p99 was **15.2791 ms** on the GPU page. These unattributed
tail stalls are the next profiling target, not something a median or Lean proof
can dismiss. Unchanged pages serve as noise controls, not ranking-cache gains.
Real sampling stalls, cold font/icon loading, resize/scroll workloads, other
hardware and presentation latency need separate measurements; this does not
establish a worst-case latency bound or guarantee sustained on-screen 120 FPS. The cache adds a fixed 36-process capacity,
not unbounded history, threads, timers or allocations.

## Correctness and its boundary

`src/top_processes.zig` preserves the original insertion selector, including
stable ties, missing counters and IEEE comparisons. Each of three cache entries
is keyed by the **exact requested capacity** (up to 12); larger requests use the
original algorithm. A prefix of a larger result is deliberately not substituted
because NaN comparisons can make that differ from the original bounded selector.

`App.order` invalidates all entries after sampling/refill and on reordering,
including dirty/paused frames. Cached process strings are borrowed and must
never be reused after source mutation. New source-mutation paths must invalidate
before the next ranking request; do not mutate the sampler behind the app.

In the parent nanoui checkout, `lean-proofs/NanoUI/NanomonRankings.lean` proves eleven
cache-protocol properties, including equivalence to recomputation, exact keys,
miss/hit invariant preservation, bounded fallback, and validity for arbitrary
finite traces of requests and source replacements. Run:

```sh
cd ../../lean-proofs
lake build
```

These are checked mathematical proofs parameterized by the unchanged selector,
**not a verified translation of Zig or a proof of frame rate**. Zig differential
tests bind that contract to all three metrics, capacities 0–13, ties, unknowns,
NaNs/infinities, reordered/mutated/removed processes, late refills and paused
updates. Offscreen tests compare exact rendered bytes and graph hover state on
all three affected pages at two widths. CI builds Lean with warnings as errors
(so `sorry` is not accepted) and runs the Zig tests on macOS and Linux.

A canvas batching shortcut was not adopted: it would require additional proofs
and tests for the layout nodes' per-cell snapping, clipping and resize behavior.
No rendering behavior or monitoring semantics were weakened to chase a number.
