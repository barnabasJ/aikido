defmodule Aikido.Ash.Team.Transformers.Build do
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

  def before?(Aikido.Ash.Agent.Transformers.Build), do: true
  def before?(_), do: false

  def transform(dsl) do
    if Aikido.Ash.Agent in Spark.extensions(dsl), do: expand(dsl), else: {:ok, dsl}
  end

  defp expand(dsl) do
    entities = Transformer.get_entities(dsl, [:team])
    members = Enum.filter(entities, &match?(%Aikido.Ash.Team.Member{}, &1))
    workers = Enum.filter(entities, &match?(%Aikido.Ash.Team.Worker{}, &1))
    instance = Transformer.get_option(dsl, [:agent], :instance)
    limit = Transformer.get_option(dsl, [:team], :max_members, 128)
    definitions = Map.new(members, &{&1.name, Map.from_struct(&1)})
    raw = Transformer.get_option(dsl, [:team], :topology, %{})

    config = %{
      resource: Transformer.get_persisted(dsl, :module),
      instance: instance,
      inherit: Transformer.get_option(dsl, [:team], :inherit, []),
      state_path: Transformer.get_option(dsl, [:agent], :path, :state),
      topology: %Aikido.Ash.Team.Topology{nodes: Map.merge(raw, definitions)},
      max_members: limit,
      timeout: Transformer.get_option(dsl, [:team], :operation_timeout, 5_000),
      workers: Map.new(workers, &{&1.name, Map.from_struct(&1)})
    }

    build(dsl, config)
  end

  defp build(dsl, config) do
    slice = Aikido.Ash.Team.State
    Code.ensure_compiled!(slice)

    dsl =
      dsl
      |> Transformer.persist(:aikido_team_slice, slice)
      |> Transformer.add_entity([:agent], %Aikido.Ash.Agent.SliceMount{
        path: :team,
        module: slice,
        options: []
      })

    dsl = Transformer.persist(dsl, :aikido_team_config, config)

    dsl =
      Enum.reduce(@commands, dsl, fn command, dsl ->
        Transformer.add_entity(dsl, [:agent], %Aikido.Ash.Agent.Route{
          name: if(command == :start, do: :configure_topology, else: command),
          public?: true,
          type: "aikido.ash.team.#{command}",
          action: {slice, command}
        })
      end)

    {:ok, dsl}
  end
end
