# Changelog

## Unreleased

- Log a bounded, projected tool-runtime failure reason with the existing tool
  name and reference at error level. Preserve the opaque model-facing error
  envelope. Use native history redaction for structured credential/runtime
  fields and a safe fallback if diagnostic projection fails.

- Preserve durable scope refusals as native typed forbidden errors through the
  generated public start action. Expose only the operation and an atom refusal
  reason, replacing opaque reasons with a generic code and excluding the original
  startup stack or authority data. Direct durable activation errors retain their
  existing transport shape.

- Preserve optional nil callback fields across fresh bootstrap projection and
  paired codecs. Before final native create, omit nil only for embedded Function
  attributes whose declared default is nil and which allow nil. Retain native
  required/default validation and reject raw stored callback strings as input.

- Add opt-in `todo_continuation: :nudge_once`: remind once about unchanged open
  blocking work, then report a typed `CompletedUnclosed` error on a consecutive
  idle final answer. Actual tool dispatch and newly consumed messages reset the
  idle window. Relevant delegated work and activation hold todo completion until
  results arrive. Existing deadline and continuation budgets still apply.
- Allow native todo verifiers to return `Aikido.AiReact.TodoVerification` with
  corrective feedback and sensitive per-run opaque data. Legacy boolean verdicts
  remain supported; optional native `:data` arguments receive the prior value.
  Correlated verdicts alone adopt data; new runs and restoration clear it.
  Verifier action context includes the actual receiving agent's runtime identity
  without replacing native actor or tenant authority. The verified-assistant
  example demonstrates typed feedback, continuation data and bounded reminders.

- Restore durable caller authority through an application-owned scope adapter and
  opaque revocable credentials. Use unchanged DurableServer claim/init callbacks;
  fresh native initialization runs after the claim and saved agents bypass it.
  Apply paired path codecs before the first bootstrap write and retain only their
  transformed paths for decoding after authentication. Identity rebinds can adopt
  replacement credentials in the same native action as their identity changes.
  Validate saved identity against the actual claim; preserve custom native scope
  protocols and fresh Todo defaults without applying saved-run interruption.
  Reject unsafe checkpoint-only bootstrap input instead of persisting a fallback.
  Project nested typed bootstrap fields without creating embedded resources before
  the claim; retain opaque map and term data. Restore saved identities in anonymous
  pools without requiring a fresh agent module or fresh attributes.
  Encode declared portable callbacks with native Ash function codecs during fresh
  bootstrap, recording only actual conversions and reversing them before the
  owning path codec. Preserve codec-owned representations and reject stored
  capture strings supplied as fresh function input.

- Preserve topology startup and cleanup failures in a native typed error with the
  stable agent ID, instead of a generic unknown error. Forward the current caller's
  scope through explicit stops, team member cleanup and startup rollback.

- Require Ash 3.37.2 or later within 3.x for native calculated publication contracts.

- Add opt-in agent publications and subscriptions backed by native Ash PubSub,
  typed signals generated from explicit root and slice calculations, receiver-owned
  scope, lifecycle subscription cleanup, and a playground counter/observer example.

- Add sparse `ActionResult.changes` for mounted reducer attributes. Apply results
  through a real private native update, retaining the existing `state` input for
  compatibility. Collect native notifications until all routed updates succeed,
  then schedule publication after state adoption, ahead of reducer effects.

- Warn on the third completed successful cycle for periods one through four,
  using the existing bounded history and retaining configured terminal limits.
  Attach native typed run/turn/period metadata to the model warning so journals
  can project system notes without matching text. Period-one warnings move from
  the second identical batch to the third.

- Allow a pure MFA to select completed tool-batch comparison keys while retaining
  native bounded cycle detection, result adoption and exact comparisons by
  default. Fail explicitly when a configured comparison callback fails.

- Add opt-in bounded context-summary regeneration for empty, invalid or oversized
  handoff documents, retaining history and usage with fresh result correlation.
  Truncated summaries remain terminal; provider retries keep their existing policy.

- Fail an AI run at its configured turn limit when the last model response still requests executable tools. Retain the response history and usage, execute no further tools, and accept a genuine final answer at the limit.

- Run the existing synchronous before-model hooks when incoming text resumes a
  waiting AI run. Check the handoff budget after adopting delivered text and hook
  context, while retaining the run's request, deadline, caller and prepared tools.

- Validate configured AI clients after compilation through Spark and native Ash
  module casting. Materialize the default lazily and reject explicit nil without
  forcing consumer modules to compile a sibling client early.
- Change successful tool-loop fingerprints to include returned content alongside
  each call's name and arguments. This intentionally changes the previous
  input-only behavior: the same call with different output no longer adds a
  repeat warning or advances the cycle limit. Fresh call IDs and result arrival
  order do not change a batch fingerprint.
- Keep successful-cycle history and the prior signature unchanged after failed
  or mixed batches. Continue to count those batches under the independent
  consecutive-error limit.
- Cover the existing timeout-completion envelope and rejection of a late result
  for a completed call while a distinct next call is pending in the same request.
