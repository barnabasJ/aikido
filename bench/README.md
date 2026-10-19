# Benchmarks

Run in the development environment with Benchee:

```sh
mix deps.get
mix bench                       # all suites
mix bench actions               # native Ash reducer execution
mix bench context               # incremental estimates versus a full recount
mix bench --quick               # short smoke run of every scenario
```

Normal runs measure throughput/latency for five seconds per scenario after two
seconds of warmup, followed by one second each for memory and reductions.
The quick mode uses 0.1 seconds for each phase; use it to verify the suite runs,
not to draw performance conclusions. The full suite takes roughly two minutes.
Benchee prints environment information, statistics and comparisons to the console.
Its [configuration reference](https://benchee.hexdocs.pm/Benchee.Configuration.html)
describes the measurements and available settings.

`actions` compares the same memory update with and without input construction
and casting inside the measured function, using 1, 100 and 10,000 existing keys.
Both paths execute the native Ash action, validate its result and return state;
this measures reducer and input-handling costs, not AgentServer delivery.

`context` appends the same message to histories of 10, 100 and 1,000 messages,
comparing incremental token accounting with recounting the resulting history.
Both paths include the cost of appending to ReqLLM's context list. Token estimates
are heuristic; these benchmarks do not measure a provider tokenizer.

Benchmark jobs are compiled inside module functions rather than interpreted by
`Code.eval_file/1`. Inputs are prepared once outside the measured functions. Each
iteration starts from the same immutable input, so state and history do not grow
during sampling.
Every suite checks its results before timing. These suites perform no model calls,
network requests, process-backed agent commands or persistence writes.

Run comparisons on the same machine and runtime versions, with other workloads
stopped. Benchee's per-process memory/reduction statistics do not include work
performed by other processes. There are no CI performance thresholds yet.

Add another suite as `bench/<name>.exs`, defining a module with `run/1` that accepts
the Benchee settings, and register its name and module in `bench/run.exs`.
