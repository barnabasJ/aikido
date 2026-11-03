# Run only against the immutable 6adfbb35 source worktree. Agent records and
# entries are created through normal native domain commands, never injected.
{:ok, _} = Application.ensure_all_started(:aikido)

Application.put_env(
  :aikido,
  :ash_domains,
  Enum.uniq([AikidoTest.LegacyCheckpoint.Domain | Application.get_env(:aikido, :ash_domains, [])])
)

Code.require_file(Path.expand("../../support/legacy_checkpoint/agents.ex", __DIR__))

alias AikidoTest.LegacyCheckpoint.Domain
[output] = System.argv()
output = Path.expand(output)
File.mkdir_p!(output)

{:ok, supervisor} =
  Supervisor.start_link(
    [
      {Aikido,
       name: Aikido.Default,
       durable: [
         data_dir: Path.join(output, "runtime-#{Ash.UUIDv7.generate()}"),
         scope_adapter: AikidoTest.LegacyCheckpoint.AnonymousAuthority
       ]}
    ],
    strategy: :one_for_one
  )

for {name, resource, start, append, stop} <- [
      {"plain", AikidoTest.LegacyCheckpoint.Plain, :plain_start!, :plain_append!, :plain_stop!},
      {"opaque", AikidoTest.LegacyCheckpoint.Opaque, :opaque_start!, :opaque_append!,
       :opaque_stop!}
    ] do
  agent = apply(Domain, start, [%{id: "legacy-#{name}"}])

  entries = [
    %{id: "#{name}-first", at: 123, payload: %{text: "first original entry"}},
    %{id: "#{name}-second", at: 456, payload: %{text: "second original entry"}}
  ]

  for entry <- entries, do: apply(Domain, append, [agent, %{entry: entry}])
  {:ok, runtime} = Aikido.AgentServer.state(agent.pid, &{:ok, &1})
  thread = runtime.agent.state.thread

  if Map.has_key?(thread, :generation),
    do: raise("Fixture generator must use pre-replay 6ad source")

  if Enum.map(thread.entries, & &1.id) != Enum.map(entries, & &1.id),
    do: raise("Native append failed")

  options = [
    agent_module: resource,
    id: agent.id,
    aikido: runtime.aikido,
    partition: runtime.partition,
    durable_server: runtime.durable_server,
    durable_key: runtime.durable_key,
    sync: runtime.sync
  ]

  envelope =
    Aikido.Durable.AgentServer.dump_state(%{
      runtime: runtime,
      options: options,
      permanent: true
    })

  File.write!(Path.join(output, "#{name}.json"), Jason.encode!(envelope))

  File.write!(
    Path.join(output, "#{name}-entries.json"),
    Jason.encode!(Enum.map(thread.entries, &Map.take(&1, [:id, :seq, :at, :kind, :payload])))
  )

  apply(Domain, stop, [agent])
end

Supervisor.stop(supervisor)
IO.puts("Generated native old-version snapshots in #{output}")
