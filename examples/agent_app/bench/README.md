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
propagates unrecoverable failures instead of waiting forever. A later live run
still encountered native storage timeouts near 26,000 agents despite the larger
task budget. These changes do not establish reliable 100,000-agent activation.

Completed agents intentionally remain alive in this example for inspection until
the root stops. Multiple browser-owned roots are independent. The benchmarks and
regression tests confirm complete descendant cleanup on a normal stop, including
preserving another independently owned root. Existing runtime tests cover parent
death during activation. These checks do not prove the earlier live roots were
orphans, nor do they establish cleanup behavior under every overload condition.
