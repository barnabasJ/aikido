defmodule Aikido.Ash.Transformers.Team do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer
  alias Ash.Resource.Builder
  alias Ash.Resource.Actions.Argument

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
  @events ~w(cleanup started stopped failed exited timeout operation.completed task.completed task.failed task.timeout)

  def before?(Aikido.Ash.Transformers.Agent), do: true
  def before?(_), do: false

  def transform(dsl) do
    entities = Transformer.get_entities(dsl, [:team])
    members = Enum.filter(entities, &match?(%Aikido.Ash.Team.Member{}, &1))
    workers = Enum.filter(entities, &match?(%Aikido.Ash.Team.Worker{}, &1))
    instance = Transformer.get_option(dsl, [:agent], :instance)
    limit = Transformer.get_option(dsl, [:team], :max_members, 128)
    definitions = Map.new(members, &{&1.name, Map.from_struct(&1)})
    raw = Transformer.get_option(dsl, [:team], :topology, %{})

    with :ok <- validate(dsl, entities, members, workers, raw),
         {:ok, topology} <-
           Aikido.Ash.Team.Topology.build(Map.merge(raw, definitions), instance, limit) do
      config = %{
        resource: Transformer.get_persisted(dsl, :module),
        instance: instance,
        inherit: Transformer.get_option(dsl, [:team], :inherit, []),
        state_path: Transformer.get_option(dsl, [:agent], :path, :state),
        topology: topology,
        max_members: limit,
        timeout: Transformer.get_option(dsl, [:team], :operation_timeout, 5_000),
        workers: Map.new(workers, &{&1.name, Map.from_struct(&1)})
      }

      build(dsl, config)
    else
      {:error, reason} -> error("Invalid team: #{inspect(reason)}")
    end
  end

  defp validate(dsl, entities, members, workers, raw) do
    names = Enum.map(members, & &1.name)
    worker_names = Enum.map(workers, & &1.name)
    instance = Transformer.get_option(dsl, [:agent], :instance)

    cond do
      Aikido.Ash.Agent not in Spark.extensions(dsl) ->
        {:error, "requires the Aikido.Ash.Agent extension"}

      names != Enum.uniq(names) ->
        {:error, "Team member names must be unique"}

      worker_names != Enum.uniq(worker_names) ->
        {:error, "Worker names must be unique"}

      Enum.any?(names, &Map.has_key?(raw, &1)) ->
        {:error, "Duplicate topology member"}

      Enum.any?(entities, &(Aikido.Ash.Runtime.option(&1.resource, :instance) != instance)) ->
        {:error, "All team members must use the team's Aikido instance"}

      true ->
        :ok
    end
  end

  defp build(dsl, config) do
    resource = Transformer.get_persisted(dsl, :module)
    action = Module.concat(resource, TeamAction)
    slice = Module.concat(resource, TeamSlice)
    routes = for command <- @commands, do: {"aikido.ash.team.#{command}", action}
    events = for event <- @events, do: {"aikido.ash.team.#{event}", action}

    routes =
      routes ++
        events ++ [{"aikido.agent.child.started", action}, {"aikido.agent.child.exit", action}]

    Module.create(
      action,
      quote do
        use Aikido.Action

        action do
          name "ash_team_action"

          schema do
          end
        end

        def run(signal, state, _opts, context) do
          Aikido.Ash.Team.Engine.handle(signal, state, context, unquote(Macro.escape(config)))
        end
      end,
      Macro.Env.location(__ENV__)
    )

    Module.create(
      slice,
      quote do
        use Aikido.Slice

        @persist {:aikido_slice_schema, Aikido.Ash.Team.State}

        slice do
          name "ash_team"
        end

        signal_routes do
          (unquote_splicing(
             for {type, target} <- routes do
               quote do: route(unquote(type), unquote(target))
             end
           ))
        end
      end,
      Macro.Env.location(__ENV__)
    )

    dsl =
      dsl
      |> Transformer.persist(:aikido_team_slice, slice)
      |> Transformer.add_entity([:agent], %Aikido.Dsl.Agent.SliceMount{
        path: :team,
        module: slice,
        options: []
      })

    dsl =
      Transformer.eval(
        dsl,
        [],
        quote do
          @doc false
          def __aikido_team_config__, do: unquote(Macro.escape(config))
        end
      )

    Enum.reduce_while(@commands, {:ok, dsl}, fn command, {:ok, dsl} ->
      dsl =
        Transformer.add_entity(dsl, [:agent], %Aikido.Ash.Agent.Signal{
          name: if(command == :start, do: :configure_topology, else: command),
          type: "aikido.ash.team.#{command}",
          target: action
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
      arg(:timeout_ms, :integer, constraints: [min: 1])
    ]

  defp arg(name, type, opts \\ []),
    do:
      struct(
        Argument,
        Keyword.merge([name: name, type: Ash.Type.get_type(type), public?: true], opts)
      )

  defp error(message),
    do: {:error, Spark.Error.DslError.exception(message: message, path: [:team])}
end
