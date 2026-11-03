These snapshots were generated using immutable Aikido commit
`6adfbb35e0aad41eed1afa7077a533541d37c9bd`. The generator starts ordinary agents
through their domain actions, appends original entries through native Thread
commands and calls the native DurableServer dump callback on the real runtime.
It asserts that the running Thread resource has no generation field.

The public fixture resources use an explicit anonymous preparation contract.
They have no application actor policies or secrets. The production restoration
path still authenticates through its configured ScopeAdapter before restoring
application checkpoints or applying new schema defaults.

Run `generate.exs` against the old checkout, passing a separate repository-local
output directory. It loads the shared fixture agent declarations from the current
checkout. The committed opaque fixture retains the old resource graph, including
physically absent replay fields. Do not replace it with a fixture constructed
under the new schema. `opaque-entries.json` independently records original entry
identity, sequence, timestamps, kinds and payloads.

The native typed envelope case is separate: embedded casting may already have
filled a newly declared dynamic-default attribute with nil. This fixture and the
opaque rematerialization change do not claim to recover that lost field-presence
information.
