# Recursive quicksort benchmarks

Run from `examples/agent_app`:

```sh
mix bench.quicksort --quick --sizes 32
mix bench.quicksort --suite view
mix bench.quicksort --suite tree --sizes 128,1024,4096 --profile
```

Benchee is a development dependency. The command uses `mix run --no-start` and
starts only the dependencies needed for the benchmark. It does not start the
web endpoint, read credentials, make model requests or use the preview's agent
store. Stop other workloads for comparable results.

The tree suite measures the actual example resource, its native Ash reducer
routes, real DurableServer processes, native EKV persistence and Ash notifications.
It compares one and eight native EKV shards without changing consistency or
checkpoint guarantees. Inputs are reproducibly shuffled unique integers, so
`N` values must produce `N` agents and the complete sorted result.

Each iteration has an isolated runtime and a fresh, disk-backed EKV directory
under `_build`. Root activation happens in `before_each`; the timed operation
sorts the tree and awaits all completed-node notifications. `after_each` monitors
every agent, stops the root, awaits every process exit, checks for surviving
agents, stops the runtime and removes its owned directory. Activation and cleanup
are reported separately. This avoids accumulating trees across Benchee iterations.

The JSONL output defaults to `_build/quicksort-bench.jsonl`; choose a path with
`--output`. Each successful tree run records activation/sorting/cleanup durations,
inter-notification gaps, logical checkpoint sizes, SQLite/WAL file sizes at
completion, VM memory after cleanup and surviving-agent count. WAL size is a file
occupancy snapshot, not cumulative disk traffic. Logical record sizes use the
native stored term representation; they exclude SQLite page/index overhead.

`--profile` performs additional, untimed runs with OTP call-time profiling on
native snapshot and EKV backend callbacks. These run in this isolated benchmark VM;
profiling changes timing. Accumulated call times overlap and are not additive.
The normal Benchee measurements then run with profiling disabled. Memory and
reductions phases are disabled because per-process figures omit the agent and
backend processes doing most of the work. Large sorts can take longer than the
sampling window and therefore produce very few samples. Use longer measurement
windows when drawing statistical conclusions. `--quick` is a smoke test.

The view suite compares the previous full-scan projection against the production
incremental projection for 1,000, 10,000 and 100,000 retained nodes. It asserts that
both produce the same counts and visible nodes before timing. Counters are updated
when notifications arrive; presentation visits at most 80 list rows and 127 diagram
nodes. Preparation of benchmark inputs and incremental counters is outside timing;
this measures projection, not HTML generation, browser layout or event ingestion.

## Observations on this workstation

Elixir 1.19.5 / OTP 28.5.0.4, Ryzen 5950X, 32 schedulers. These observations are
workload-specific and are not CI thresholds or a validated 100,000-agent run.

| Persisted tree | EKV shards | Median sorting | Median cleanup | Survivors after stop |
| --- | ---: | ---: | ---: | ---: |
| 1,024 agents | 1 | 1.88s | 0.80s | 0 |
| 1,024 agents | 8 | 1.80s | 0.23s | 0 |
| 4,096 agents | 1 | 7.94s | 3.31s | 0 |
| 4,096 agents | 8 | 7.15s | 0.95s | 0 |

These medians include the separate profile/preflight and benchmark iterations
(three to four runs at these sizes); the profile runs carry instrumentation.
The three-second Benchee timing window alone produced only one measured sample
per 4,096-agent scenario. Treat the numbers as a diagnosis, not a precise speedup.

In a separate 1,024-agent run, native stored records occupied about 1.43MB of
logical terms, while the WAL occupied about 206MB at completion. The native profile
recorded 5,119 snapshot calls, 3,072 conditional puts and 1,024 claims before
cleanup. Small state does not imply few writes: startup, ownership and state
transitions all participate in the native storage protocol. SQLite page writes,
CAS bookkeeping and WAL checkpoint behavior amplify the stored payload volume.

For 100,000 retained nodes, the repeated view benchmark measured approximately
202ms per full-scan projection versus 0.13ms for the incremental projection.
This comparison isolates view preparation; it does not make activation faster.

The stalled preview also logged `:max_children` spawn/notification failures while
its old runtime still had a 1,000-task limit. Its configured 20,000-task limit now
loads on a full preview restart. Rejected and failed agent activations now send a correlated failure signal to
the parent. The example retries pending partitions with bounded backoff, and
propagates unrecoverable failures instead of waiting forever. The task budget alone is not sufficient: storage shard count, activation deadlines
and telemetry module lookups also affect throughput. The full browser verification
below covers the resulting configuration.

Completed children are now stopped after their parent records the sorted result.
The retained graph lives separately in the UI history; the root remains available
until it is stopped. Multiple browser-owned roots are independent. The benchmarks and
regression tests confirm complete descendant cleanup on a normal stop, including
preserving another independently owned root. Existing runtime tests cover parent
death during activation. These checks do not prove the earlier live roots were
orphans, nor do they establish cleanup behavior under every overload condition.

## Full browser verification

Two independently shuffled 100,000-value inputs completed in the browser on
2026-10-22 with eight native EKV shards, a 30-second activation caller budget,
20,000 available I/O tasks and 100ms display batching. Persistence remained enabled.
The machine used Elixir 1.19.5, OTP 28.5.0.4, 32 schedulers and 62 GiB RAM.

| Check | Run 1 | Run 2 |
| --- | ---: | ---: |
| Browser time to sorted result | 64.899s | 69.473s |
| Spawned / completed / registered agents | 100,000 | 100,000 |
| Every rendered result value equals `1..100000` | yes | yes |
| Count retained immediately after reconnect | 100,000 | 100,000 |
| Child-start failures / retries / callback exceptions | 0 / 0 / 0 | 0 / 0 / 0 |
| Monitored exits with `{:shutdown, :delete}` | 100,000 | 100,000 |
| Cleanup observation window | 46.716s | 56.802s |
| Sampled peak BEAM memory, decimal GB | 11.486 | 11.560 |
| Largest sampled mailbox | 2,404 | 2,169 |

Cleanup observation starts when monitors are installed, just before pressing Stop.
It includes that short browser interaction interval. Both runs left zero live
agents, zero saved agent records and zero I/O tasks. The second run used the same
VM and store after the first tree was removed. No completed agents were retired
early to reduce the process count.

[The recorded counters and operation timings](results/quicksort-100k-2026-10-22.json)
include five-second process/mailbox samples and native signal/directive telemetry.
Samples can miss instantaneous peaks. BEAM memory excludes some native allocations
and filesystem caches; it is not a whole-machine RSS measurement. This is a local
stress check rather than a performance guarantee for every host.

The profiles identified three distinct pressure points:

- One EKV writer accumulated more than 13,000 requests. Eight native shards
  distributed the writes; the largest recorded shard queues in the final runs
  were 2,404 and 2,169. The scheduler run queue peaked at 13.
- Repeated Spark host checks on a runtime name triggered failed module loading.
  The code server accumulated nearly 7,000 requests. Checking the exported Spark
  host marker first avoids these lookups for ordinary runtime names.
- Progress rendering overwhelmed a WebSocket sender with roughly 5,000 messages
  and 638 MB. Coalescing display updates at 100ms intervals removed that backlog
  from the dominant sampled queues while retaining every node's terminal state.

A five-second activation caller deadline could expire even when a child became
ready afterward. The example now supplies a native 30-second caller deadline;
backend storage deadlines and strict checkpoints remain in force. Failure/retry
signals are counted directly, so a successful final answer cannot hide recovered
activation failures in these two runs.

Most reducer callbacks took less than 1ms. The second run had one `quicksort.sorted`
callback lasting 106.4ms. Mean directive callback times were approximately 68–79µs
for Notify, 68–70µs for SpawnAgent and 35–36µs for Emit; their supervised work and
storage synchronization occur outside those callback durations. Concurrent totals
must not be added together as a wall-clock breakdown.

EKV still reported transient WAL checkpoint lag during writes. Native checkpoint
statistics after cleanup showed `complete?: true`, `busy: 0`, equal log/checkpointed
frame counts and `starved?: false` on all eight shards. The reports were not muted.
There were no failed activations, retries or callback exceptions in either final
run. Regression tests additionally cover capacity rejection, parent death during
activation, late readiness, stale retries, retry exhaustion, repeated/reordered
progress, independent roots and reconnect history.

### Consecutive runs and restart teardown

The two 100,000-agent validations above waited for every monitored descendant to
exit between runs. They did not establish the timing of the original UI restart:
that returned after stopping the root, while descendant deletion continued.
The UI now waits asynchronously for the previous tree's monitored processes to
exit before it starts a fresh root. The restart button explicitly displays the release phase. Completed child
workers are released while their recorded nodes remain available for inspection.

A later failed run in the same preview left 46,699 live agents. Stopping its root
terminated all 46,699 with `{:shutdown, :delete}` in 22.020 seconds. Afterward there
were zero registered agents and zero I/O tasks. BEAM-accounted memory fell from
about 5.9 GB to 0.57 GB; OS RSS fell from about 14.6 GB to 6.3 GB. These are different
measurements: RSS also includes allocator capacity, native allocations and shared
file mappings. EKV retains native tombstones and Paxos metadata beyond logical
agent deletion. The measurements establish that process teardown completes, but
do not prove that teardown overlap explains every slowdown across repeated runs.

With monitored UI restarts, three consecutive 10,000-agent browser runs against
that same existing eight-shard store took 6.508s, 7.057s and 6.643s (random trees,
depths 32, 35 and 29). Between the second and third runs, native membership
contained only the new idle root, with zero I/O tasks and 0.49 GB BEAM-accounted
memory. The third result was checked against every value in `1..10000` in the
browser. This smaller regression check does not replace a repeat of the larger
stress test or isolate storage retention from host memory pressure.


## Sustained lifecycle check

Run ten consecutive full-size inputs in one VM and one unchanged EKV directory:

```sh
AIKIDO_EXAMPLES_EKV_SHARDS=8 AIKIDO_DURABLE_DIR=_build/quicksort-repeated \
  mix run bench/quicksort_repeated.exs --runs 10 --size 100000
```

This uses the actual playground command and restart paths. Each run verifies every
sorted value, records every agent readiness and exit, waits for child retirement,
then restarts the root and checks that the old history is absent. JSONL records
include BEAM memory, OS RSS/PSS, processes, ports, atoms, tasks, registered agents,
saved identities, native WAL stats and SQLite row/page counts. The directory is
not reset between runs. Unlike the isolated Benchee suite, this deliberately
measures accumulation. It starts the example application and its local settings
repository, but does not read provider keys or make AI requests.

EKV's deletion tombstones and retained Paxos promises are measured separately
from saved agents. Zero agent records does not mean zero physical metadata.
The example supervises its EKV store explicitly so its native DurableServer
backend can use a 60-second storage budget. The example uses native EKV GC at
30-second intervals; library defaults and durability semantics are unchanged.

### Repeated-run findings (2026-10-22)

The [ten-run control](results/quicksort-ten-uuid-control-2026-10-22.json)
completed all ten 100,000-agent sorts in one VM and store. Completed workers retired,
and each post-run sample had one idle root, one saved agent and no I/O tasks.
However, fresh identities added 100,000 Paxos keys per run, reaching 1,000,002;
sort times ranged from 101.8 to 193.0 seconds. This was not stable storage usage.

Restart now reuses the root identity and identifies each worker by its pivot value.
For a repeatedly shuffled fixed input range, the worker key set is bounded. UI
histories use distinct per-run topics, so delayed old notifications cannot change
the replacement graph. Tests cover ten shuffled runs and restarting active work.

The [subsequent full-size attempt](results/quicksort-six-stable-identities-2026-10-22.json)
confirmed the key count plateaued at 100,002. Its first six completed sorts took
87.6, 125.2, 171.4, 177.1, 223.6 and 221.2 seconds. Post-run BEAM memory remained
273–348 MB, with one root, one saved agent and no I/O tasks, but native WAL files
grew to about 24 GB of allocated disk space. The attempt ended when the workspace
filesystem filled; it did not complete ten runs and has no final cleanup sample.
Offline WAL checkpoints recovered space while preserving database records.
Stable full-size timing is still unresolved.

The repeated-run harness now checks available disk space before each run and
stops its isolated VM if less than 2 GB remains. It never deletes saved records
or resets the store between iterations. `--profile` records native EKV call-time
counters; nested totals overlap and cannot be summed into elapsed time.
`--truncate-wal` is an explicit diagnostic: it requests SQLite WAL truncation
between completed runs and records success or busy results. This maintenance is
not part of the normal playground restart path and must not be presented as a
production performance fix.

The [ten-run 10,000-agent diagnostic](results/quicksort-ten-truncate-10k-2026-10-22.json)
completed with explicit WAL maintenance enabled. Sorting took 8.1–14.7 seconds;
post-run BEAM memory stayed at 177–187 MB, with 434 processes, five ports, one
root, one saved agent, no I/O tasks and no retained histories. Final stop left
zero agents, saved agents, tasks and histories (432 processes). The store already
contained the keys from an earlier failed diagnostic; those records were not
reset. The new run's key set plateaued by iteration two. Some checkpoint attempts
returned busy. These smaller measurements do not prove normal full-size restart
stability, nor do they isolate elapsed time from host disk/GC contention.

A [ten-run control without explicit maintenance](results/quicksort-ten-normal-10k-2026-10-22.json)
then used that same existing store. Every 10,000-agent sort and descendant exit
was verified. Each post-run sample had 434 processes, five ports, one root, one
saved agent, zero I/O tasks and zero histories. Final stop again left zero live
and saved agents. Post-run BEAM memory ranged from 174 to 191 MB. Sorting took
8.3–19.5 seconds, while logical WAL occupancy increased from 3.5 GB to 22.9 GB.
This confirms normal-path lifecycle cleanup at that size, but not stable disk
usage or full-size timing. After the benchmark VM exited, offline WAL checkpoints
reclaimed log space without deleting records. These maintenance operations were
outside the timed runs and are not hidden in the reported restart path.

### Native checkpoint at restart

The [serialized native checkpoint diagnostic](results/quicksort-ten-native-checkpoint-10k-2026-10-22.json)
called `EKV.WALCheckpointer.checkpoint/2` for each shard at the quiet run boundary.
All eight shards completed their passive checkpoints in all ten iterations. WAL
occupancy stayed at about 3.2–3.5 GB rather than growing across iterations.

The actual `Quicksort.Restart` path now waits for the old tree to exit and asks
EKV's own checkpointer to finish each shard before starting the new root. This
runs in the external restart task, serializes with EKV's background checkpointer,
and preserves stored data. No direct SQL maintenance is part of this path.
Other application roots remain alive; concurrent writes can still make a passive
checkpoint incomplete, so this does not promise a globally quiescent store.

[Ten runs through that updated normal path](results/quicksort-ten-restart-checkpoint-10k-2026-10-22.json)
used one VM and the unchanged existing store, without diagnostic maintenance flags.
Every result and worker exit was verified. Sorting took 9.8–15.1 seconds;
restart, including checkpointing, took 1.2–4.4 seconds. Post-run BEAM memory was
167–189 MB, with one root, one saved agent, no I/O tasks and no histories.
Logical WAL occupancy stayed between 2.5 and 3.0 GB. Final stop left zero live
and saved agents, tasks and histories. Native consensus metadata remains;
its key count is bounded for these repeated input values.

Two browser runs on the restored port-4042 preview sorted and verified all
10,000 values in 15.730s and 12.191s, with a native-checkpoint restart between them.
The final browser restart cleared the history, and its idle root was stopped.
All 79 example tests and the repository quality checks passed.

Full-size verification of this change is pending disk headroom. The earlier
disk-full incident also stopped the old preview runtime; its eight SQLite shards
passed integrity checks and the preview was restored without wiping its store or
relaxing safe deserialization. One old idle test root was stopped through the
normal domain action after its application modules loaded. Provider storage was
untouched. The workspace's ZFS snapshots retain about 50 GB of historical blocks;
autosnapshots can retain old WAL blocks even after the database checkpoints them.
No filesystem snapshots were deleted. Offline diagnostic compaction preserved
logical-data hashes and passed integrity checks for all 32 shards; it is not a
substitute for the pending full-size runtime verification.

The preview-store audit after those browser tests had zero live agents, I/O tasks
and histories, and 205 MB of BEAM-accounted memory. It also found 11,728 saved
temporary children under the different, older failed tree
`01a16407-8d30-7991-8d67-4d8549307509`: 10,747 marked running and 981 marked stopped
gracefully despite no live processes. These are saved snapshots, not EKV Paxos
metadata. They remain in place; complete cleanup of the whole preview store has
not been established. None belonged to the two newly verified browser runs.
