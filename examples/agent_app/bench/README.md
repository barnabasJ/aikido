# Recursive quicksort benchmarks

The [published-AshLua verification](results/research-team-published-lua-2026-10-25.json)
completed with AshLua 0.2.3 and the saved z.ai coding-plan credential in 162.817 s.
Every squad started empty: five agents completed four delegations, including
an independent background result and a researcher three levels below the root.
The retained task and membership records confirm completion and worker retirement;
the final synthesis returned the matching observed word counts. These records,
rather than the model's description of which squads remain available, establish
the actual lifecycle state.

The retained [real-provider research run](results/research-team-larger-budget-2026-10-25.json)
also completed with the updated 16,384-token output budget and ten-minute model
attempt timeout: 18 recorded agents, 41 tasks across the tree, 11 root model turns,
zero active agents and a final synthesis. It exercised nested squads, background
results and stopped-worker history. Its final response reports recovering from
truncated responses by requesting compact replacements; completion does not mean
every individual model call succeeded on its first attempt.

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

The inspector-specific benchmark uses the actual Playground collector with fresh
eight-shard stores. Run `mix run --no-start bench/inspector_cost.exs --benchee`, or
use `--profile` for call-time attribution. With the complete nested agent resource
serialized through native Ash types and initialized contracts reused, 1,024-agent
averages were 642.35 ms without inspection, 639.38 ms for root state, 1.04 s for
full recursive state and 653.53 ms for recursive signal identities. Full state
capture still costs about 62% more than the no-inspector baseline. These
five-second sampling windows on eight schedulers are diagnostics, not stable
performance gates; the small root-only advantage is within run variation. See
the [current Benchee output](results/inspector-native-ash-resource-2026-10-25.log).
The preceding [plain-map/sorting measurements](results/inspector-benchee-sortkeys-2026-10-25.log)
and [profile](results/inspector-profile-current-2026-10-25.log) explain the earlier
projection improvements.

The same native snapshot format also completed two consecutive 100,000-agent
runs through the Playground with recursive state inspection: 111.071 s and
127.722 s, with every sorted value checked. All 100,000 agents completed and
the 99,999 children retired in each run; the fresh-root restart took 3.351 s and 3.715 s. Each restart
left one root and one snapshot, zero child survivors and zero I/O tasks. Final
stop left zero agents, snapshots, tasks and retained tree histories. See the
[full lifecycle measurements](results/quicksort-native-ash-resource-100k-2026-10-25.jsonl).
These are runtime rechecks of persistence and inspection; the preceding browser
verification remains recorded separately.

During this continuous workload native passive checkpointing reported transient
starvation. At final stop every shard reported all WAL frames checkpointed and
no starvation. Seven WAL files still occupied roughly 3 GB each; SQLite can reuse
that allocated space after a complete checkpoint. File occupancy alone does not
mean agents or uncheckpointed writes remain. The report retains both frame
progress and file sizes; it does not claim the WAL files immediately shrink.

The earlier measurements below used Elixir 1.19.5 / OTP 28.5.0.4 on a Ryzen
5950X with 32 schedulers. They cover up to 4,096 agents and are workload-specific,
not CI thresholds. The separate 100,000-agent reports above use eight schedulers.

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

That benchmark configuration reused the root identity and identified each worker by its pivot value.
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
That attempt did not establish stable full-size timing.

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

The full-size verification below completed after disk headroom became available.
The earlier
disk-full incident also stopped the old preview runtime; its eight SQLite shards
passed integrity checks and the preview was restored without wiping its store or
relaxing safe deserialization. One old idle test root was stopped through the
normal domain action after its application modules loaded. Provider storage was
untouched. At the time, workspace ZFS snapshots retained about 50 GB of historical blocks;
autosnapshots can retain old WAL blocks even after the database checkpoints them.
No filesystem snapshots were deleted. Offline diagnostic compaction preserved
logical-data hashes and passed integrity checks for all 32 shards; it is not a
substitute for runtime verification.

The preview-store audit after those browser tests had zero live agents, I/O tasks
and histories, and 205 MB of BEAM-accounted memory. It also found 11,728 saved
temporary children under the different, older failed tree
`01a16407-8d30-7991-8d67-4d8549307509`: 10,747 marked running and 981 marked stopped
gracefully despite no live processes. These are saved snapshots, not EKV Paxos
metadata. None belonged to the two newly verified browser runs. With explicit
owner approval, all 11,728 were subsequently deleted through the native domain
delete action. The [cleanup verification](results/quicksort-preview-cleanup-2026-10-22.json)
recorded zero remaining saved snapshots, live agents, tasks and histories.
Provider credential storage was untouched.


### Ten consecutive 100,000-agent runs

The [full sustained verification](results/quicksort-ten-native-restart-100k-2026-10-22.json)
completed ten independently shuffled 100,000-agent sorts through the actual
Playground command and Restart paths, using one VM, one root identity and one
unchanged native eight-shard EKV store. No diagnostic maintenance flags, store
resets or VM restarts were used. Every sorted value and every worker exit was
verified; all one million agent activations completed without unexpected exits.

| Run | Sorting | Restart, including native checkpoint | BEAM memory after restart |
| --- | ---: | ---: | ---: |
| 1 | 96.9s | 2.5s | 276 MB |
| 2 | 111.1s | 4.9s | 347 MB |
| 3 | 120.7s | 2.4s | 340 MB |
| 4 | 192.1s | 3.5s | 330 MB |
| 5 | 145.0s | 3.4s | 345 MB |
| 6 | 112.9s | 6.7s | 322 MB |
| 7 | 126.1s | 3.3s | 339 MB |
| 8 | 113.7s | 5.5s | 317 MB |
| 9 | 121.1s | 4.8s | 348 MB |
| 10 | 126.8s | 8.7s | 292 MB |

The first five sorts had a median of 120.65 seconds; the last five had a median
of 121.14 seconds. Individual timings varied under host I/O pressure, including
the slower fourth run; this is evidence against progressive degradation in this
workload, not a promise of identical elapsed times.

Every restart returned to 434 processes, five ports, one idle root, one saved
root, zero I/O tasks and zero retained histories. After initial module loading,
the atom count stayed at 50,420. Post-restart BEAM memory stayed at 276–348 MB;
OS RSS fluctuated between 2.04 and 2.72 GB. Sampled peak BEAM memory ranged from
3.77 to 4.74 GB. Final stop left zero live agents, saved snapshots, I/O tasks and
histories, with 432 application processes and five ports. All eight database
shards passed read-only integrity checks after the benchmark VM exited.

Native consensus keys plateaued at 100,002 after warmup; database files stayed
at about 1.14 GB logically. WAL file lengths stayed around 29 GB across runs 2–9,
rather than accumulating another run's writes each time; run 10 ended at 17 GB.
All eight native checkpoints completed at every restart. These are logical file
lengths, not outstanding uncheckpointed data or allocated disk blocks. After VM
exit, the retained WAL files occupied about 3.86 GB of filesystem blocks and the
database files about 384 MB on this compressed filesystem. Passive checkpointing
allows reuse and does not promise immediate file truncation. Native EKV metadata
and reusable storage remain; completed agent snapshots and live processes do not.
The bounded key set assumes the same repeated input values.


### Starting after process recovery

The playground resolves Stop by the stable agent ID, rather than assuming its
cached PID is still current. Quicksort's Start button uses the same monitored
teardown path as Restart whenever a previous browser run exists. Teardown also
stops surviving processes under that root's identity prefix; recovered descendants
may no longer have their original live parent monitors. A replacement root is
started only after those processes exit. Other browser-owned trees are excluded.
Regression tests cover a stale cached PID, an existing replacement root, a
detached descendant, preservation of another root and a subsequent successful sort.


### Current execution isolation and crash cleanup

Quicksort Restart now creates a fresh root ID for each sorting execution.
Children use the normal `parent_id/branch_name` derivation, so `L` below a root
and `R` below that child have IDs `<root>/L` and `<root>/L/R`. Workflow callers
can still supply an explicit root ID when recovering the same workflow execution.
Quicksort retains its input-dependent pivot selection; changing root namespaces
isolates differently shaped sorting trees without requiring a locally sorted pivot.

Teardown removes both live descendants and saved crash checkpoints for the old
Quicksort root before creating the next execution. Cleanup reads only the old tree's deterministic identities, reconstructed from
its input and recorded display history, plus any live descendants. Bounded
concurrent native deletes check resource ownership; already deleted partitions
are skipped. It does not enumerate the durable store or inspect other runs'
snapshots. Other root namespaces and resources are excluded.

In the existing eight-shard preview store, a full saved-agent scan took 7,960 ms
with only two saved agents. After a browser-driven 10,000-agent sort, targeted
restart took 358 ms: one live old root before teardown, zero old-tree processes
after teardown, and a fresh replacement root. All 10,000 sorted values were
verified. This is a single restart measurement, not a sustained throughput claim. The missing-parent recovery path honors
`:stop` instead of retaining a parentless worker. Activation errors identify
agents by stable ID, and the UI displays the underlying reason without recursively
printing each parent's error wrapper.

The earlier ten-run timing report used the former reused-root configuration.
It remains evidence for that recorded configuration, not bounded metadata usage
with fresh roots. Fresh executions intentionally allocate new native consensus
keys; stopping agents deletes their snapshots and processes, not all EKV metadata.
The sustained harness now checks that each replacement root has a different ID.


The [existing-store recovery check](results/quicksort-fresh-root-recovery-2026-10-22.json)
verified the previously failing 10,000-value input after crash-checkpoint cleanup,
then completed two fresh-root 10,000-agent runs in 13.1 and 9.9 seconds. A further
browser-driven run completed and verified every value in 9.4 seconds. The retired
root namespaces had zero live processes and saved snapshots, the formerly
conflicting process was dead, and no I/O tasks remained. The two current completed
roots and their UI histories remain available for inspection.

## Recursive inspector capture cost

To isolate inspector capture from browser rendering, run three rotated rounds of
identical 1,024-agent sorts with no observer, root state, child identities and full
child state. Every run verifies the complete sorted result. Use a new store path:

```sh
AIKIDO_DURABLE_DIR=/tmp/aikido-inspector-cost-new ERL_FLAGS='+S 8:8' \
  mix run --no-start bench/inspector_cost.exs --benchee
```

Omit `--benchee` for three rotated rounds with JSONL timings. Benchee excludes
root activation and cleanup via its iteration hooks. Its five-second window gives
only a few samples per scenario; increase it for precise comparisons.

This probe starts the example application, including its endpoint, but makes no
AI requests. The isolated store is left at the supplied path for inspection.
Activation and root cleanup are outside the sorting timer. This measures capture
in the signal pipeline; it excludes the playground collector's diffs and browser
rendering. Stop other workloads for comparable results.

On 2026-10-25, three rounds before the projection change averaged 0.99s without
an inspector and 6.88s with full child state. After bounding traversal before
redaction, removing duplicate state projection and precomputing private names,
three rounds averaged 1.06s and 2.55s respectively. These are diagnostic samples
on this workstation, not performance guarantees. Full state capture still has
measurable cost; observing child identities alone averaged 1.10s after the change.

A separate five-second Benchee run after the change averaged 1.03s without an
inspector, 1.04s for root state, 1.10s for child identities and 2.49s for full
child state. The browser then completed 4,096 agents in 9.804s with full recursive
inspection and retained child messages. Browser timings include UI collection;
they should not be directly compared with the isolated capture benchmark.

### Further capture profiling and large runs, 2026-10-25

Add `--profile` to the capture probe to use OTP's `tprof` across agent processes.
It reports function costs separately from Benchee's elapsed sorting time. The
profile found repeated schema discovery for plain maps and terms; these now skip
Ash/Spark resource discovery while preserving constrained-map fields and native
resource sensitivity. Private-name checks reuse one string conversion and a set.

The latest five-second [Benchee comparison](results/inspector-benchee-fastmaps-2026-10-25.log)
averaged 1.18s without inspection, 1.17s for root state, 1.21s for child identities
and 1.54s for full recursive state. Full capture still has a measured cost. These
short diagnostic windows are not throughput guarantees.

A later fresh eight-shard run with retained application telemetry measured
0.62s without inspection, 0.63s for root state, 0.64s for recursive identities
and 1.17s for full recursive state. See the
[telemetry-enabled comparison](results/inspector-benchee-telemetry-2026-10-25.log).
Full state projection remains substantially more expensive than signal-only
inspection; these results do not establish that its remaining overhead is solved.

The single-shard 100,000-agent retry exposed storage pressure delaying native
DurableServer heartbeats. Its heartbeat watchdog stopped the lifecycle manager;
the resulting child exit reached Quicksort as `:normal`. The previous benchmark
also masked its primary failure with a cleanup timeout. The harness now observes
terminal state after every signal, preserves primary failures, logs phase
boundaries, and records spawn gaps, retirement time and local supervisor counts.
Its [failure log](results/quicksort-diagnostic-100k-2026-10-25.log) is retained.

With **eight native EKV shards**, two consecutive 100,000-agent runs through the
actual Playground collector and Restart path passed in one VM and one store:

| Run | Sorting | Last child retirement after result | Restart |
| --- | ---: | ---: | ---: |
| 1 | 119.33s | 0.294s | 3.14s |
| 2 | 128.36s | 0.268s | 3.07s |

Each run verified all sorted values and all 100,000 process identities, observed
zero remaining children and returned to one root, one snapshot, zero I/O tasks
and zero old display histories. Final stop left zero agents and saved snapshots.
All eight post-exit integrity checks passed. See the
[summary](results/quicksort-eight-shards-100k-2026-10-25.json) and
[raw reports](results/quicksort-eight-shards-100k-2026-10-25.jsonl).

All restart WAL checkpoints completed. Logical WAL file sizes totalled about
19.6GB and 19.9GB after the runs: checkpointed files retain reusable high-water
space and do not count saved agent snapshots. Native consensus metadata for fresh
identities is also separate from retained agent state. Two runs do not establish
indefinite memory or metadata stability.

Two subsequent browser runs on an isolated eight-shard preview completed all
100,000 partitions in **131.58s** and **134.73s**, with full recursive inspection
enabled. The browser showed deep descendant signals and retained the completed
tree. After each run the native supervisor and membership both returned to one
root, with one saved agent snapshot and zero I/O tasks. Restart produced a fresh
root ID and was observed ready within 7.6 seconds (an observation upper bound).
Final stop left zero local agents and zero agent snapshots; all eight live-store
SQLite integrity checks passed. Native WAL maintenance returned each shard's
WAL to 64 MiB after quiescence, without manual truncation. See the
[browser observations](results/quicksort-browser-100k-2026-10-25.json).

After moving explicit graceful cleanup before the final durable save, another
two consecutive browser runs completed 100,000 agents in **121.301s** and
**125.082s**, using the actual Playground elapsed metric. Both returned to one
root and one saved snapshot. The second complete result was checked against
every integer from 1 through 100,000 in the browser. Recursive history retained
deep child IDs, and totals recorded zero processing and directive exceptions.
Final stop left zero local agents, memberships, I/O tasks and agent snapshots;
all eight live-store integrity checks passed and native WAL maintenance again
settled at 64 MiB per shard. The isolated preview exited cleanly and its generated
store was removed after verification. Native logs included 11 transient WAL
checkpoint-starvation warnings during writes; they cleared at quiescence, with
no heartbeat or eviction errors. See the
[current cleanup verification](results/quicksort-browser-current-cleanup-100k-2026-10-25.json).

New playground stores default to eight shards. Existing stores retain their
detected shard count; an incompatible explicit override fails before startup.
To reproduce the large run, use a fresh disk-backed `AIKIDO_DURABLE_DIR` with
`AIKIDO_EXAMPLES_EKV_SHARDS=8`. Do not change the shard count of an existing store:
it changes key placement. The heartbeat watchdog remains enabled.
