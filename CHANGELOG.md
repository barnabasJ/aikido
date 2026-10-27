# Changelog

## Unreleased

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
