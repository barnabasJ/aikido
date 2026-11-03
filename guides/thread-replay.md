# Optional Thread replay

Ordinary notification subscriptions and a storage agent that buffers and bulk
upserts notifications do not require replay. Replay is an explicit source and
consumer choice for retained history and missed-subscriber catch-up.

## Source opt-in and retention

Start a source through its native domain with the embedded Thread setting:

```elixir
MyDomain.source_start!(%{
  id: "source-1",
  thread: %{replay?: true}
}, scope: scope)
```

The application declares the domain, source agent and Thread mount as usual.
`replay?` defaults false. Ordinary appends take the native casting/stamping path
without computing hashes or retaining replay receipts. Follow and Prune reject
disabled mounts. A team separately opts into membership history with
`roster_history? true`; ordinary teams do not record that history.

Enabled replay preserves entry IDs, timestamps and causal references. It assigns
sequences within a generation and rejects conflicting reuse of an immutable ID.
Prune retains identity receipts to detect a conflict after its payload is removed.
Receipts grow until Clear or identity deletion. Configure retention deliberately;
this mode does not bound total source storage. A retry of the latest Clear is a
no-op even after appends; another accepted Clear gets a different generation.

Use permanent source retention when history must survive agent stop. Temporary
agents delete saved history on stop. Delivery resolves a running source and does
not silently activate an offline one. Restart a retained source through its
normal authorized domain action before requesting its history.

Existing retained threads can opt in through the native `configure_replay`
command. Supply a metadata patch; the action deep-merges it with existing user
metadata and builds receipts from the existing native entries. It preserves entry
IDs, timestamps, sequences, order and generation. Duplicate legacy IDs or broken
sequence order return a native invalid error without changing history; migration
never calls Clear or regenerates entries. The command is a write-configuration
authorization boundary; permission to Follow does not grant it.

Batch and Work carry the confirmed source Thread `metadata` map as data. The
source's native synchronization boundary confirms that metadata with the exact
entry range. Applications can route dynamically discovered sources using finite
namespaced data stamped from authenticated source attributes, while still checking
the current writer's actual SQL permissions. Metadata is not an actor or a grant.

## Confirmed source publication

A private Batch passes a native DurableServer synchronization boundary before
publication, independently of the source's periodic/automatic/explicit default.
The wrapper requests `sync: true` with a continuation; that continuation releases
the Batch after synchronization succeeds. A failed native sync terminates before
the continuation. An unchanged persisted projection can reuse the completed
save. An intervening Clear or Prune invalidating the exact generation/range
suppresses that stale delivery; normal authorized demand detects the new head
or explicit gap.

The native snapshot path must retain the opted-in journal. Applications that
customize checkpoint/restore or externalize/reinstate must preserve those fields
if they require replay after recovery. A separate SQL data layer does not persist
the running source automatically. These guarantees concern the configured storage
backend; they do not make local EKV storage survive disk or machine loss.

Each fresh Follow is authorized under the consumer's actual scope. Append,
retry and restoration advertise availability metadata instead of replaying
private payloads under an old permission decision. Applications decide whether
activity metadata itself is private. Private Batch/Gap/Available/Rejected replies
require runtime-verified delivery provenance. Supplying a source reference,
request ID or caller context flag through ordinary typed ingress cannot establish
that provenance. Arbitrary code running inside the BEAM is trusted runtime code.

## Consumer and SQL boundary

Mount `Aikido.Thread.Consumer.Slice` once on an ordinary storage agent and route
`Aikido.Thread.Consumer.Signals.Work` to an application action. That action returns
an AsyncTask directive for the application's scoped database transaction. Emit
`Committed` only after that transaction commits, or `Failed` on failure. The slice
does not write SQL or infer database success.

A credit covers one source request or a batch awaiting application commit. The
configured window covers all sources in the current consumer incarnation. Credits
contain addresses and ranges, not entry payloads. Use immutable entry identity
for idempotent SQL upserts: consumer snapshot recovery may replay a committed
batch. Source retention gaps are explicit and require an explicit recovery cursor
choice. Resetting a cursor is rejected while a request/write credit is outstanding.

Set `cancel_on_owner_exit?: true` on storage AsyncTask descriptors to retire their
native work processes when the originating agent exits. This preserves native
scope/tracer context. It cannot withdraw an external query already accepted by a
database. Database transaction locks and pool limits remain the application's
concurrency contract; the consumer does not promise a cross-incarnation bound on
remote SQL execution.

An application middleware that projects a completed model turn into Thread can
invoke its existing native `next` continuation for Append against the proposed
context in the same outer turn. Combine the returned notification/directive
descriptors. On Append failure return the original context and discard both
sets of effects. Queuing Append as a later self-signal creates a separate turn
and does not provide that atomic terminal-history contract.

## Explicit drain and shutdown

`drain_journals` is an optional consumer command. It requests a fresh authorized
head from every known live source, writes the confirmed suffix through the
existing global window, and checks the source again after its last commit. It
then pauses demand and emits `aikido.thread.consumer.drained`, correlated by the
drain command's signal ID. Native `drained_request_id` records the completed ID;
`drain_request_id` identifies the in-progress request. Verify that state when
awaiting a completion rather than accepting an unrelated result signal.

Use `Aikido.AgentServer.call_until` to subscribe before triggering the native
domain command. A gap, authorization failure, unavailable source or failed SQL
write produces `aikido.thread.consumer.drain_blocked` and pauses new demand.
It never reports Drained for an offline source. Existing writes can still finish;
use the caller's normal timeout if external work does not settle. After resolving
the failure, explicitly retry its source and use `continue_journals` to resume.
A second drain or resume cannot replace an active drain.

For an immediate graceful catch-up, quiesce producers while they remain active,
then await the consumer's Drained result before stopping it. This command is not
a producer lifecycle controller. Normal Team reverse-dependency shutdown may
stop a producer first; in that case retain its permanent snapshot and the
consumer's cursors, then explicitly restart the source through its authorized
native domain before retrying catch-up. That is eventual recovery, not successful
drain during downtime. An unavailable SQL sink must not make ordinary agent stop
wait forever or manufacture a successful drain.

## Explicit public route names

Unrelated public targets cannot share one owning command name, even when an
explicit declaration overrides one target. Declare a distinct name for each
signal/target pair so the native command owns its correct argument schema and
policy:

```elixir
route "counter.changed", {CounterSlice, :change}, name: :counter_change
route "other.changed", {OtherSlice, :change}, name: :other_change
```

The verifier rejects an ambiguous override. Alternate concrete signal spellings
for one target retain their individual predicates and owning admission metadata.
Private aliases remain private; public wildcard routes remain unsupported.
