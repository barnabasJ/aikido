# Multipart input verification and gate attribution

This receipt supplements the earlier queue-storage review and its initial
verification status. It does not claim the final candidate passed every gate.

## Reviewed source

The reviewed freeze contains 37 source, test and documentation paths, based on
`4ff6cbd4d274ffa3b03513caec8cb1c799598ae0`. The combined reviewed patch has
SHA-256 `cc076854b989137a6319e81434c44c5b2efcd29c01942ee84d90d69438d5e14f`.
This additive receipt is the only file outside that freeze in the publication.
The ineffective MapSet trial was removed; `team/member_stop.ex` remains
byte-identical to the base. No dependency or checker suppression was added.

The retained changes provide native ReqLLM multipart user input, exact authored
text, typed queue snapshot compatibility, native Task result cleanup, and the
two independently reviewed quality prerequisites: compile before formatting
and the mechanical inherited-attribute condition inversion.

## Candidate evidence

- The earlier combined source patch
  `97e5f541674709c498fd993dbb9a5b6a42f26d829bec0ce20797e82ccae81d3d`
  passed the full SDK suite: 1,383 passed, no failures, seed 766743. This predates
  the final Task and text-fidelity overlays; it is not a full-suite result for
  the final freeze.
- The text-fidelity overlay passed six selected native stories
  (01, 02, 05, 06, 07 and 15), with nine excluded. The final native Task cleanup
  passed its owned-success lifecycle case, with ten excluded.
- Strict compilation, formatting and Credo passed in the preserved candidate
  quality run. Argus failed with three warnings; the quality alias therefore
  did not reach Dialyzer.
- Separate native Dialyzer follow-ups cleared the Task warning but retained
  the MapSet warning. The failed MapSet trial was subsequently removed without
  another checker run. There is no fresh all-green final-freeze receipt.

## Actual target comparison

A separate, unmodified detached worktree at exact base
`4ff6cbd4d274ffa3b03513caec8cb1c799598ae0` used Elixir 1.20.1, OTP 29.0.2,
`+S 4:4`, `MIX_ENV=dev`, initially absent project build/dependency directories,
and native dependency/PLT validation. Its lockfile matched the candidate:
SHA-256 `edf85d6ce291978937cfdd7ccd02da9fd3142d4091865cce29a4b258f387b9ce`.
Pinned checkers were Argus 0.24.0 and Dialyxir 1.4.7.

| Native command | Exit | Wall time |
| --- | --- | --- |
| `mix deps.get` | 0 | 4.45 s |
| `mix compile --warnings-as-errors` | 0 | 114.45 s |
| `mix argus --all --fail-above 0` | 1 | 69.44 s |
| `mix dialyzer` | 2 | 252.27 s |

Exact base reproduced all four remaining diagnostics under review:

- `argus.blocking`: `Aikido.AgentServer.handle_call/3`, line 997, with 14 caller
  modules.
- `argus.shutdown`: `Aikido.AgentServer.terminate/2`, line 1422.
- `argus.unsafe_input`: the Spark interface-name builder
  `Aikido.Domain.Extension.Transformers.Build.public_action_interface/2`,
  line 36.
- `call_without_opaque`: `Aikido.Team.MemberStop.missing_owner_ancestor?/5`,
  line 49, using the public `MapSet.member?/2` API.

The baseline Argus diagnostic blocks differ only in six displayed source lines
for the AI `ask_sync` witness moving from base line 136 to candidate line 137.
All other diagnostic lines match. Base additionally reports the older Task
opaque-guard warning at `async_task.ex:135`, including Dialyxir's formatting
exception and legacy warning. No fix was backported to affect this comparison.

Independent exact-checker-source review and the actual baseline measurements
attribute the four remaining diagnostics to pre-existing checker artifacts.
This establishes attribution, not passing gates or an automatic release waiver.
No ignores, checker patches, tests or source changes were used to obtain the
baseline result. Both worktrees retained their exact reviewed source identities.

## Retained local evidence

The originating worktree retains commands, raw logs, source hashes and receipts
under `tmp/multimodal-verification/`, including `final-source-manifest.json`,
`FINAL-37-FREEZE.md`, `FULL-ROUND.md`, `DIALYZER.md`, and
`base4ff-gates/{run.sh,RECEIPT.md,manifest.json}`. The baseline manifest SHA-256
is `8e137aebe7670aa2f86fdac137da339d39ebbc9de97e38ad1c2e8b6339d24bb2`.
These local raw artifacts are not part of the package. The build slot was
returned after all baseline checker processes were confirmed terminal.

## Publication mechanics

The first commit attempt stopped in the shared `commit-msg` hook before creating
any commit. That hook hardcodes a change to the shared checkout and invokes
Mix there; dependency checks failed in that unrelated checkout. It only checks
Conventional Commit syntax, not tests or quality gates. Root independently
reviewed it and approved `core.hooksPath=/dev/null` for this single
administrative commit, whose message follows the Conventional Commit contract.
The hook, source configuration and checker configuration were left unchanged.
No dependency fetch or build was performed to work around the hook failure.
