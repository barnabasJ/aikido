# Model-based slice testing

The first AshQuint model covers ReAct's setup and streaming lifecycle. Each
model step supplies one typed signal to the compiled router, invokes the native
Ash reducer/adoption fold, and compares resulting state and directive descriptors.
It never executes directives or starts an agent server, provider, timer or worker.
Initialization uses the resource's native initialize action, and state changes
continue through native update actions; the adapter never patches state.

The projection checks status, tool preparation generation, model iteration,
retry attempt, accepted batch sequence, exact streamed content and directive
order/types. Descriptor assertions also check request correlation, generation,
conversation, model, options and tool payloads. Named scenarios cover duplicates,
stale readiness, stale attempts, cancellation followed by late batches, and a
fresh run after completion. Random traces add combinations of those transitions.

```sh
MIX_ENV=test mix test test/aikido/ai_react/quint_test.exs
MIX_ENV=test mix ash_quint.gen react_stream --check
MIX_ENV=test mix ash_quint.coverage react_stream
```

`ash_quint.exs` pins Quint, its backend, the seed and generation bounds. Commit
models, traces and their manifest together. Ordinary replays need neither Node
nor Quint. Generation needs Node/npx. Sensitivity testing verifies the adapter
notices corrupted expectations or skipped work; a staleness check rejects traces
whose model changed without regeneration.

AshQuint is currently pinned to a Git revision because the Hex package lookup
returned no release when added. It is enabled only in test and is a dev/test
dependency. No production code depends on its gates.

This is bounded model-based testing, not a proof of all ReAct behavior. Tool
execution, Lua hooks, handoffs, todo verification and concurrent effect delivery
are not yet represented by this model. Existing runtime tests remain responsible
for executing effects, cancellation cleanup, persistence and mailbox behavior.
Extend the model in small independently checked sections rather than copying
all reducer implementation details into a second engine.
