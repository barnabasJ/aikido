# Baseline provenance

The worktree began at `cc2d11f5` with the source checkout's tracked and untracked
working changes copied intact. The source checkout was not reset or modified.
The two relevant chats were inspected before implementation:

- “Refactor Jido Around Ash”, `01a14916-0cc0-7d42-bd63-34fa00948039`
- “Replace Jido with Aikido”, `01a17769-86dd-76c0-9b6f-582cfe6db431`

The copied source already contained bounded handoff regeneration. Later intended
library corrections were present in the isolated
`/home/joba/sandbox/jido/tmp/handoff-regeneration-integration` checkout rather than
all being applied to the dirty source checkout. That integration's committed
head was `e67b452416295ceb347c014ea7748b75e561db73`, with the reviewed native warning
candidate and initialized Ash constraints correction applied as working changes.

Only the following library work and its tests/example updates were reconciled:

- Native lazy AI client defaults and compile-time module validation.
- Provider input-pressure shape tracking and retaining current user input across
  a handoff; transient input fields are excluded from durable snapshots.
- Failure at the iteration limit when executable tool work remains.
- Pure result-aware tool-loop comparison keys, successful-cycle history, typed
  third-cycle warning metadata, initialized native embedded dump/cast constraints
  and the controlled resilience example.
- The previously reviewed AshLua Git source and exact resolved native graph.

No Logseq application migration changes were imported. Existing source work,
including the handoff `with` binding, was retained. AST comparisons across `lib/`
and `test/` isolated semantic gaps from formatting differences. Initial copies
and SHA-256 receipts are retained locally under `tmp/jido-adapter-baseline/`.
The reviewed warning artifacts were `tool-cycle-warning-r1` and
`tool-cycle-warning-constraints-r2`; the latter patch hash was
`ac8360c141eb00fae84c7b25559a8b5fd0a8973e40aa1c60d33bfc11dacbde5a`.

Verification in this worktree, using Elixir 1.20.4 / OTP 29.1.1 with four schedulers:

- Focused warning/loop/handoff tests: **49 passed**.
- First full library run: **1,060/1,061 passed**; it identified the copied
  maximum-iteration implementation gap. The failure was preserved in
  `/tmp/aikido-full-baseline-tests.log` before restoring the reviewed correction.
- Full library after reconciliation: **1,094 passed**, logged at
  `/tmp/aikido-full-baseline-tests-r2.log`.

The root Aikido build, adapter build and adapter dependency graph are isolated
from the source/integration checkouts. Dependency warnings from the host's newer
Elixir compiler are recorded in the logs. No push or publication was requested.

Adapter verification: **11 tests passed**, Spark formatting check passed, and
`MIX_ENV=test mix compile --warnings-as-errors` passed. A fresh VM loaded and
called the example's generated resource from its saved BEAM without recompiling.
Logs are `/tmp/aikido-adapter-{tests-final,format-final,compile-final,fresh-vm}.log`.
The separate playground suite was not rerun here; no playground-wide result is
claimed. Its AshLua pin and lock were kept consistent with the native graph.

Work is on `codex/jido-v3-ash-adapter`. At the user’s request, the preserved
baseline and experimental adapter are committed separately for branch publication.
Local benchmark result files remain outside these commits.
