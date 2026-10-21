defmodule Aikido.Team.Extension.Transformers.Build do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @commands [
    :start,
    :reconcile,
    :add_member,
    :remove_member,
    :ensure_member,
    :stop_member,
    :send,
    :broadcast,
    :assign_task
  ]

  def before?(Aikido.Agent.Extension.Transformers.Build), do: true
  def before?(_), do: false

  def transform(dsl) do
    if Aikido.Agent.Extension in Spark.extensions(dsl),
      do: resolve_team_configuration(dsl),
      else: {:ok, dsl}
  end

  defp resolve_team_configuration(dsl) do
    entities = Transformer.get_entities(dsl, [:team])
    members = Enum.filter(entities, &match?(%Aikido.Team.Member{}, &1))
    workers = Enum.filter(entities, &match?(%Aikido.Team.Worker{}, &1))
    instance = Transformer.get_option(dsl, [:agent], :instance)
    limit = Transformer.get_option(dsl, [:team], :max_members, 128)
    definitions = Map.new(members, &{&1.name, Map.from_struct(&1)})
    raw = Transformer.get_option(dsl, [:team], :topology, %{})

    config = %{
      resource: Transformer.get_persisted(dsl, :module),
      instance: instance,
      inherit: Transformer.get_option(dsl, [:team], :inherit, []),
      state_path: Transformer.get_option(dsl, [:agent], :path, :state),
      topology: %Aikido.Team.Topology{nodes: Map.merge(raw, definitions)},
      max_members: limit,
      timeout: Transformer.get_option(dsl, [:team], :operation_timeout, 5_000),
      workers: Map.new(workers, &{&1.name, Map.from_struct(&1)})
    }

    add_team_slice_and_commands(dsl, config)
  end

  defp add_team_slice_and_commands(dsl, config) do
    Code.ensure_compiled!(Aikido.Team.Slice)

    dsl
    |> mount_team_slice()
    |> Transformer.persist(:aikido_team_config, config)
    |> add_team_commands()
    |> then(&{:ok, &1})
  end

  defp mount_team_slice(dsl) do
    dsl
    |> Transformer.persist(:aikido_team_slice, Aikido.Team.Slice)
    |> Transformer.add_entity([:agent], %Aikido.Agent.SliceMount{
      path: :team,
      module: Aikido.Team.Slice,
      options: []
    })
  end

  defp add_team_commands(dsl) do
    Enum.reduce(@commands, dsl, fn command, dsl ->
      Transformer.add_entity(dsl, [:agent], %Aikido.Agent.Route{
        name: if(command == :start, do: :configure_topology, else: command),
        public?: true,
        type: "aikido.ash.team.#{command}",
        action: {Aikido.Team.Slice, command}
      })
    end)
  end
end
