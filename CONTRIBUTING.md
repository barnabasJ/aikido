# Contributing

Use Elixir 1.19 and OTP 28 or later. Install dependencies with `mix deps.get`.
The repository's `AGENTS.md` defines its architecture and implementation standards;
`test/AGENTS.md` covers async helpers.

## State and effects

Actions are pure: they return the next domain state and directives and never
perform side effects. All side effects belong in directives, including message
delivery, network and database I/O, process creation and timers. Directives
perform I/O without changing domain or runtime state. Return external
results as signals. Use Ash types for contracts and Spark.Options for configuration.
Preserve tagged tuple and structured error contracts at public boundaries.

## Layout

- `lib/aikido/agent/`, `slice/`, and `domain/`: native resource/domain extensions and agent commands.
- `lib/aikido/agent_server/`: runtime callbacks and effect execution.
- `lib/aikido/durable/`: DurableServer integration and snapshot handling.
- Feature folders such as `lib/aikido/fsm/`, `ai_react/`, and `team/`: each feature’s slice, extension, actions, signals, directives, and types.
- `lib/aikido/actions/` and `lib/aikido/directives/`: behavior shared by features.
- `test/`: pure, integration, and runtime tests with shared support helpers.
- `examples/agent_app/`: the runnable Phoenix/LiveView example application.
- `guides/`: the current Ash, teams, runtime, and partition guides.

## Verification

```bash
mix format
mix test
mix q
mix docs
```

For the example app:

```bash
cd examples/agent_app
mix deps.get
mix test
```

Prefer pure action tests before runtime integration tests. Use subscriptions,
monitors, and the shared wait helpers for asynchronous assertions. Add coverage
for behavior changes and failures.

## Benchmarks

Run `mix bench` for the Benchee suites, `mix bench actions` or `mix bench context`
for one suite, and `mix bench --quick` for a smoke run. See
[benchmark scope and methodology](bench/README.md) before comparing results.

## Changes and releases

Use Conventional Commits and keep ecosystem dependency ranges stable. Update
`CHANGELOG.md`, current guides, and runnable examples when behavior or APIs change.
Document public functions and modules where their contracts need explanation.
