defmodule Aikido.Ash.Transformers.Team do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer
  alias Ash.Resource.Builder

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

  def before?(Aikido.Ash.Transformers.Agent), do: true
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
      |> Transformer.add_entity([:agent], %Aikido.Dsl.Agent.SliceMount{
        path: :team,
        module: slice,
        options: []
      })

    dsl = Transformer.persist(dsl, :aikido_team_config, config)

    Enum.reduce_while(@commands, {:ok, dsl}, fn command, {:ok, dsl} ->
      dsl =
        Transformer.add_entity(dsl, [:agent], %Aikido.Ash.Agent.Signal{
          name: if(command == :start, do: :configure_topology, else: command),
          type: "aikido.ash.team.#{command}",
          target: {slice, command}
        })

      case Builder.add_new_action(
             dsl,
             :action,
             if(command == :start, do: :configure_topology, else: command),
             returns: :map,
             arguments: arguments(command)
           ) do
        {:ok, dsl} -> {:cont, {:ok, dsl}}
        error -> {:halt, error}
      end
    end)
  end

  defp arguments(:send), do: [arg(:data, :map, default: %{})]
  defp arguments(:start), do: [arg(:topology, :map)]
  defp arguments(:reconcile), do: []

  defp arguments(:add_member),
    do: [
      arg(:member, :term, allow_nil?: false),
      arg(:resource, :atom),
      arg(:template, :atom),
      arg(:initial_state, :map, default: %{}),
      arg(:owner, :term),
      arg(:depends_on, {:array, :term}, default: []),
      arg(:activation, :atom, default: :eager, constraints: [one_of: [:eager, :lazy]])
    ]

  defp arguments(:remove_member),
    do: [arg(:member, :term, allow_nil?: false), arg(:cascade?, :boolean, default: false)]

  defp arguments(command) when command in [:ensure_member, :stop_member],
    do: [arg(:member, :term, allow_nil?: false)]

  defp arguments(:broadcast),
    do: [
      arg(:type, :string, allow_nil?: false),
      arg(:payload, :map, default: %{}),
      arg(:members, {:array, :term})
    ]

  defp arguments(:assign_task),
    do: [
      arg(:member, :term, allow_nil?: false),
      arg(:task_id, :string),
      arg(:type, :string, default: "harness.task"),
      arg(:payload, :map, default: %{}),
      arg(:timeout_ms, :integer, default: 30_000, constraints: [min: 1]),
      arg(:notify, :term),
      arg(:metadata, :map, default: %{})
    ]

  defp arg(name, type, opts \\ []) do
    {:ok, argument} = Builder.build_action_argument(name, type, opts)
    argument
  end
end
