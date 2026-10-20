defmodule Aikido.Ash.Transformers.Agent do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer
  alias Ash.Resource.Builder

  @impl true
  def before?(Aikido.Ash.Transformers.Team), do: false
  def before?(Aikido.Ash.Transformers.AI), do: false
  def before?(_), do: true

  @impl true
  def transform(dsl) do
    dsl = Transformer.eval(dsl, [], quote(do: @behaviour(Aikido.Agent)))
    resource = Transformer.get_persisted(dsl, :module)
    team_slice = Transformer.get_persisted(dsl, :aikido_team_slice)
    entities = Transformer.get_entities(dsl, [:agent])
    mounts = Enum.filter(entities, &match?(%Aikido.Dsl.Agent.SliceMount{}, &1))
    declared_signals = Enum.filter(entities, &match?(%Aikido.Ash.Agent.Signal{}, &1))
    {dsl, declared_signals} = resolve_local_actions(dsl, declared_signals, resource)
    inherited = inherited_signals(mounts, declared_signals)
    signals = declared_signals ++ inherited
    dsl = Enum.reduce(inherited, dsl, &Transformer.add_entity(&2, [:agent], &1))

    declared = Transformer.get_entities(dsl, [:agent, :schema])
    dsl = Enum.reduce(declared, dsl, &Transformer.add_entity(&2, [:attributes], &1))
    attributes = Ash.Resource.Info.attributes(dsl)

    state_fields = for attribute <- attributes, attribute.name != :id, do: attribute.name

    with :ok <- ensure_embedded_mounts(mounts),
         {:ok, dsl} <-
           Builder.add_new_attribute(dsl, :id, :string,
             primary_key?: true,
             allow_nil?: false,
             public?: true,
             default: &Ash.UUIDv7.generate/0
           ),
         {:ok, dsl} <- add_mounts(dsl, mounts, team_slice),
         {:ok, dsl} <- add_lifecycle_actions(dsl),
         {:ok, dsl} <- add_signals(dsl, signals, mounts) do
      declared_routes =
        for route <- entities, match?(%Aikido.Dsl.Agent.Route{}, route) do
          case route.action do
            name when is_atom(name) ->
              name =
                if Ash.Resource.Info.action(dsl, name),
                  do: name,
                  else: String.to_atom("__aikido_reduce_#{name}")

              %{route | action: {resource, name}}

            {_resource, _action} ->
              route
          end
        end

      routes =
        declared_routes ++
          for signal <- signals, !mounted_signal?(signal, mounts) do
            %Aikido.Dsl.Agent.Route{type: signal.type, action: signal.target, priority: 0}
          end

      accepted = for attribute <- attributes, attribute.writable?, do: attribute.name

      with {:ok, dsl} <-
             Builder.add_new_action(dsl, :create, :__aikido_initialize_state__,
               accept: Enum.uniq([:id | accepted]),
               public?: false
             ) do
        {:ok,
         dsl
         |> Transformer.persist(:aikido_agent_routes, routes)
         |> Transformer.persist(:aikido_state_fields, state_fields)}
      end
    end
  end

  # Mount types and their schemas are inputs to attribute/action generation.
  # Reject unusable resources here rather than passing invalid types to Ash.
  defp ensure_embedded_mounts(mounts) do
    if Enum.any?(mounts, &invalid_resource_slice?/1),
      do: error("Resource slices must be embedded Ash resources with Aikido.Ash.Slice"),
      else: :ok
  end

  # A local reducer and its public command may share a declared name. Keep the
  # native reducer private and generate the command under the public name.
  defp resolve_local_actions(dsl, signals, resource) do
    {signals, {dsl, _aliases}} =
      Enum.map_reduce(signals, {dsl, %{}}, fn signal, {dsl, aliases} ->
        local =
          case signal.target do
            name when is_atom(name) -> name
            {^resource, name} -> name
            _ -> nil
          end

        if local do
          name = Map.get(aliases, local, local)

          {dsl, name, aliases} =
            case Ash.Resource.Info.action(dsl, name) do
              %{type: :action, returns: Aikido.ActionResult} = action when name == signal.name ->
                internal = String.to_atom("__aikido_reduce_#{name}")
                reducer = %{action | name: internal, public?: false}

                next =
                  dsl
                  |> Transformer.remove_entity([:actions], &(&1.name == name))
                  |> Transformer.add_entity([:actions], reducer)

                {next, internal, Map.put(aliases, local, internal)}

              _ ->
                {dsl, name, aliases}
            end

          resolved = %{signal | target: {resource, name}}
          dsl = Transformer.replace_entity(dsl, [:agent], resolved, &(&1 == signal))
          {resolved, {dsl, aliases}}
        else
          {signal, {dsl, aliases}}
        end
      end)

    {dsl, signals}
  end

  defp inherited_signals(mounts, declared) do
    for mount <- mounts,
        Spark.Dsl.is?(mount.module, Ash.Resource),
        Aikido.Ash.Slice in Spark.extensions(mount.module),
        route <- Spark.Dsl.Extension.get_entities(mount.module, [:slice]),
        is_atom(route.action),
        action = Ash.Resource.Info.action(mount.module, route.action),
        match?(%{public?: true}, action),
        !Enum.any?(declared, &(&1.name == action.name)) do
      %Aikido.Ash.Agent.Signal{
        name: action.name,
        type: route.type,
        target: {mount.module, action.name}
      }
    end
    |> Enum.uniq()
  end

  # Mounted slices already own these routes and state paths. Exposing their
  # public actions must not install a second route against the agent's own state.
  defp mounted_signal?(signal, mounts) do
    Enum.any?(mounts, fn mount ->
      mount.module
      |> Aikido.Dsl.Slice.Info.signal_routes()
      |> Enum.any?(&(elem(&1, 0) == signal.type && elem(&1, 1) == signal.target))
    end)
  end

  defp invalid_resource_slice?(mount) do
    !Spark.Dsl.is?(mount.module, Ash.Resource) ||
      !Ash.Resource.Info.embedded?(mount.module) ||
      Aikido.Ash.Slice not in Spark.extensions(mount.module)
  end

  defp add_mounts(dsl, mounts, team_slice) do
    Enum.reduce_while(mounts, {:ok, dsl}, fn mount, {:ok, dsl} ->
      type = if Spark.Dsl.is?(mount.module, Ash.Resource), do: mount.module, else: :map

      case Builder.add_new_attribute(dsl, mount.path, type,
             public?: true,
             writable?:
               mount.module != team_slice &&
                 !(Transformer.get_persisted(dsl, :aikido_ai?, false) &&
                     mount.path in [:ai, :work])
           ) do
        {:ok, dsl} -> {:cont, {:ok, dsl}}
        error -> {:halt, error}
      end
    end)
  end

  defp add_signals(dsl, signals, mounts) do
    # The verifier checks duplicate declarations; generation must not bind a
    # second command to the handler generated for the first one.
    signals
    |> Enum.uniq_by(& &1.name)
    |> Enum.reduce_while({:ok, dsl}, fn signal, {:ok, dsl} ->
      case add_signal(dsl, signal, mounts) do
        {:ok, dsl} -> {:cont, {:ok, dsl}}
        error -> {:halt, error}
      end
    end)
  end

  defp add_signal(dsl, signal, _mounts) do
    case Enum.find(Transformer.get_entities(dsl, [:actions]), &(&1.name == signal.name)) do
      nil ->
        fields = signal_fields(dsl, signal)

        arguments =
          if fields == [] do
            [
              %Ash.Resource.Actions.Argument{
                name: :data,
                type: Ash.Type.Map,
                default: %{},
                allow_nil?: false,
                public?: true
              }
            ]
          else
            Enum.map(fields, fn {name, options} ->
              build_argument!(
                name,
                options[:type],
                Keyword.take(options, [
                  :constraints,
                  :allow_nil?,
                  :default,
                  :description,
                  :sensitive?
                ])
              )
            end)
          end

        dsl =
          if fields != [],
            do:
              Transformer.persist(dsl, :aikido_flat_signal_inputs, [
                signal.name | Transformer.get_persisted(dsl, :aikido_flat_signal_inputs, [])
              ]),
            else: dsl

        Builder.add_new_action(dsl, :action, signal.name,
          returns: :map,
          run: {Aikido.Ash.Action, []},
          arguments: [reference_argument() | arguments]
        )

      %{type: :action, run: nil} = action ->
        updated = %{
          action
          | run: {Aikido.Ash.Action, []},
            arguments: [reference_argument() | action.arguments]
        }

        {:ok, Transformer.replace_entity(dsl, [:actions], updated, &(&1.name == signal.name))}

      _ ->
        error("Signal #{signal.name} requires a generic action without a run handler")
    end
  end

  defp build_argument!(name, type, options) do
    options = Enum.reject(options, fn {_key, value} -> is_nil(value) end)
    {:ok, argument} = Builder.build_action_argument(name, type, options)
    argument
  end

  defp reference_argument do
    build_argument!(:agent, :term,
      allow_nil?: false,
      description: "Stable agent ID, current PID, or a reference returned by start."
    )
  end

  defp add_lifecycle_actions(dsl) do
    arguments =
      dsl
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(& &1.writable?)
      |> Enum.map(fn attr ->
        build_argument!(
          attr.name,
          attr.type,
          Enum.reject(
            [
              constraints: attr.constraints,
              allow_nil?: attr.allow_nil?,
              default: attr.default,
              description: attr.description
            ],
            fn {_key, value} -> is_nil(value) end
          )
        )
      end)

    arguments =
      if Transformer.get_persisted(dsl, :aikido_team_slice) do
        Enum.reject(arguments, &(&1.name == :topology)) ++
          [
            build_argument!(:topology, :map,
              description:
                "Initial topology; omitted or nil uses the team DSL defaults. An empty map starts no members."
            )
          ]
      else
        arguments
      end

    Enum.reduce_while(
      [
        {:start, :map, arguments},
        {:inspect, :term, [reference_argument(), build_argument!(:fields, {:array, :atom}, [])]},
        {:stop, :map, [reference_argument()]},
        {:delete, :map, [reference_argument()]},
        {:list, {:array, :term},
         [
           build_argument!(:filter, :term, []),
           build_argument!(:sort, :term, default: []),
           build_argument!(:limit, :integer, constraints: [min: 0]),
           build_argument!(:offset, :integer, default: 0, constraints: [min: 0])
         ]}
      ],
      {:ok, dsl},
      fn {name, returns, arguments}, {:ok, dsl} ->
        case Builder.add_new_action(dsl, :action, name,
               returns: returns,
               run: {Aikido.Ash.Action, []},
               arguments: arguments
             ) do
          {:ok, dsl} -> {:cont, {:ok, dsl}}
          error -> {:halt, error}
        end
      end
    )
  end

  defp signal_fields(dsl, %{target: target}) do
    {resource, name} = target

    if resource == Transformer.get_persisted(dsl, :module) do
      dsl |> Ash.Resource.Info.action(name) |> Aikido.ActionRef.schema()
    else
      Code.ensure_compiled!(resource)
      Aikido.ActionRef.schema(target)
    end
  end

  defp error(message) do
    {:error, Spark.Error.DslError.exception(message: message, path: [:agent])}
  end
end
