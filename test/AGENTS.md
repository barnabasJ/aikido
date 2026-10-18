# AGENTS.md - Aikido Test Support Guide

## Intent
Provide stable, reusable testing patterns for pure agents, AgentServer runtime behavior, and multi-agent flows.

## Runtime Baseline
- Elixir `~> 1.19`
- OTP `28+` (release QA baseline)

## Commands
- `mix test`
- `mix test test/path/to/file_test.exs`
- `mix test --cover`
- `mix test --include example`

## Support Modules
- `AikidoTest.Case`: isolated Aikido instance per test (`aikido`, `aikido_pid` context)
- `AikidoTest.Eventually`: polling helpers/macros for non-state waits (`eventually`, `assert_eventually`, `refute_eventually`); for agent state changes use `Aikido.AgentServer.subscribe/4` or one of the `await_*` helpers
- `AikidoTest.Support.TestTracer`: lightweight span capture for runtime assertions
- `AikidoTest.TestAgents` and `AikidoTest.TestActions`: canonical fixtures for behavior-level tests

## Standards
- Prefer behavior assertions over implementation/log assertions
- Avoid `Process.sleep/1`; use eventual assertions and monitored process lifecycle checks
- Keep tests focused and deterministic (single behavior per test where practical)
- Use unique IDs/helpers to avoid test cross-talk

## High-Value Coverage
- `cmd/2` immutability and directive emission semantics
- AgentServer signal routing and runtime directive execution
- Parent-child lifecycle (`SpawnAgent`, `StopChild`) and state synchronization
- Slice-return action shapes — single slice via `path:`, multi-slice via `%Aikido.Agent.SliceUpdate{}`

## Release Hygiene
- Keep test fixtures aligned with current directive/slice-return/tool contracts
- Use Conventional Commits
- Update examples in `test/examples/` when behavior contracts change

## References
- `test/support/`
- `test/examples/`
- `../README.md`
- https://github.com/barnabasJ/aikido
