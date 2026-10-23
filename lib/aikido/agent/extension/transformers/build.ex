defmodule Aikido.Agent.Extension.Transformers.Build do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer
  alias Ash.Resource.Builder

  @impl true
  def before?(Aikido.Team.Extension.Transformers.Build), do: false
  def before?(Aikido.AI.Extension.Transformers.Build), do: false
  def before?(_), do: true

  @impl true
  def transform(dsl) do
    with {:ok, dsl} <- Aikido.Signal.Routes.expand(dsl, :agent) do
      expand_agent_resource(dsl)
    end
  end

  defp expand_agent_resource(dsl) do
    dsl = Transformer.eval(dsl, [], quote(do: @behaviour(Aikido.Agent)))
    resource = Transformer.get_persisted(dsl, :module)
    team_slice = Transformer.get_persisted(dsl, :aikido_team_slice)
    entities = Transformer.get_entities(dsl, [:agent])
    mounts = Enum.filter(entities, &match?(%Aikido.Agent.SliceMount{}, &1))

    declared_signals =
      Enum.filter(entities, &(match?(%Aikido.Agent.Route{}, &1) && &1.public?))

    {dsl, declared_signals, aliases} = resolve_local_actions(dsl, declared_signals, resource)
    inherited = inherited_signals(mounts, declared_signals)
    signals = declared_signals ++ inherited
    dsl = Enum.reduce(inherited, dsl, &Transformer.add_entity(&2, [:agent], &1))

    dsl = add_state_attributes(dsl)
    attributes = Ash.Resource.Info.attributes(dsl)

    with :ok <- ensure_embedded_mounts(mounts),
         {:ok, dsl} <- add_identity_attribute(dsl),
         {:ok, dsl} <- add_mounts(dsl, mounts, team_slice),
         {:ok, dsl} <- add_lifecycle_actions(dsl),
         {:ok, dsl} <- add_signals(dsl, signals),
         {:ok, dsl} <- add_initialization_action(dsl, attributes) do
      {:ok, persist_state_and_routes(dsl, attributes, entities, mounts, aliases)}
    end
  end

  defp add_state_attributes(dsl) do
    dsl
    |> Transformer.get_entities([:agent, :schema])
    |> Enum.reduce(dsl, &Transformer.add_entity(&2, [:attributes], &1))
  end

  defp add_identity_attribute(dsl) do
    Builder.add_new_attribute(dsl, :id, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      default: &Ash.UUIDv7.generate/0
    )
  end

  defp add_initialization_action(dsl, attributes) do
    accepted = for attribute <- attributes, attribute.writable?, do: attribute.name

    Builder.add_new_action(dsl, :create, :__aikido_initialize_state__,
      accept: Enum.uniq([:id | accepted]),
      manual: Aikido.Agent.Actions.Initialize,
      public?: false
    )
  end

  defp persist_state_and_routes(dsl, attributes, entities, mounts, aliases) do
    resource = Transformer.get_persisted(dsl, :module)

    routes =
      entities
      |> Enum.filter(&match?(%Aikido.Agent.Route{}, &1))
      |> Enum.map(&%{&1 | action: resolve_local_target(&1.action, aliases, resource)})
      |> Enum.reject(&mounted_signal?(&1, mounts))

    fields = for attribute <- attributes, attribute.name != :id, do: attribute.name

    dsl
    |> Transformer.persist(:aikido_agent_routes, routes)
    |> Transformer.persist(:aikido_state_fields, fields)
  end

  # Mount types and their schemas are inputs to attribute/action generation.
  # Reject unusable resources here rather than passing invalid types to Ash.
  defp ensure_embedded_mounts(mounts) do
    if Enum.any?(mounts, &invalid_resource_slice?/1),
      do: error("Resource slices must be embedded Ash resources with Aikido.Slice.Extension"),
      else: :ok
  end

  # A local reducer and its public command may share a declared name. Keep the
  # native reducer private and generate the command under the public name.
  defp resolve_local_actions(dsl, signals, resource) do
    {dsl, aliases} =
      Enum.reduce(signals, {dsl, %{}}, fn signal, {dsl, aliases} ->
        local = local_action_name(signal.action, resource)

        if local == signal.name && !Map.has_key?(aliases, local) do
          case Ash.Resource.Info.action(dsl, local) do
            %{type: :action, returns: Aikido.Types.ActionResult} = action ->
              internal = String.to_atom("__aikido_reduce_#{local}")
              reducer = %{action | name: internal, public?: false}

              next =
                dsl
                |> Transformer.remove_entity([:actions], &(&1.name == local))
                |> Transformer.add_entity([:actions], reducer)

              {next, Map.put(aliases, local, internal)}

            _ ->
              {dsl, aliases}
          end
        else
          {dsl, aliases}
        end
      end)

    {signals, dsl} =
      Enum.map_reduce(signals, dsl, fn signal, dsl ->
        resolved = %{signal | action: resolve_local_target(signal.action, aliases, resource)}
        {resolved, Transformer.replace_entity(dsl, [:agent], resolved, &(&1 == signal))}
      end)

    {persist_reducer_aliases(dsl, aliases), signals, aliases}
  end

  defp local_action_name(name, _resource) when is_atom(name), do: name
  defp local_action_name({resource, name}, resource), do: name
  defp local_action_name(_target, _resource), do: nil

  defp persist_reducer_aliases(dsl, aliases) do
    flat_reducers =
      Enum.map(
        Transformer.get_persisted(dsl, :aikido_flat_reducers, []),
        &Map.get(aliases, &1, &1)
      )

    union_reducers =
      Map.new(Transformer.get_persisted(dsl, :aikido_union_reducers, %{}), fn {name, variants} ->
        {Map.get(aliases, name, name), variants}
      end)

    dsl
    |> Transformer.persist(:aikido_flat_reducers, flat_reducers)
    |> Transformer.persist(:aikido_union_reducers, union_reducers)
  end

  defp resolve_local_target(name, aliases, resource) when is_atom(name),
    do: {resource, Map.get(aliases, name, name)}

  defp resolve_local_target({resource, name}, aliases, resource),
    do: {resource, Map.get(aliases, name, name)}

  defp resolve_local_target(target, _aliases, _resource), do: target

  defp inherited_signals(mounts, declared) do
    for mount <- mounts,
        Spark.Dsl.is?(mount.module, Ash.Resource),
        Aikido.Slice.Extension in Spark.extensions(mount.module),
        route <- Spark.Dsl.Extension.get_entities(mount.module, [:slice]),
        route.public?,
        {resource, name} = Aikido.Slice.Info.action_reference(mount.module, route.action),
        action = Ash.Resource.Info.action(resource, name),
        match?(%{public?: true}, action),
        command_name = route.name || inherited_name(route, resource, action.name),
        !Enum.any?(declared, &(&1.name == command_name)) do
      %Aikido.Agent.Route{
        name: command_name,
        type: route.type,
        action: {resource, action.name},
        signal_module: route.signal_module,
        implementation: route.implementation,
        public?: true
      }
    end
    |> Enum.uniq_by(&{&1.name, &1.action})
  end

  defp inherited_name(%{signal_module: module}, resource, action) when not is_nil(module) do
    if Map.has_key?(
         Spark.Dsl.Extension.get_persisted(resource, :aikido_union_reducers, %{}),
         action
       ),
       do: module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom(),
       else: action
  end

  defp inherited_name(_route, _resource, action), do: action

  # Mounted slices already own these routes and state paths. Exposing their
  # public actions must not install a second route against the agent's own state.
  defp mounted_signal?(signal, mounts) do
    Enum.any?(mounts, fn mount ->
      mount.module
      |> Spark.Dsl.Extension.get_entities([:slice])
      |> Enum.any?(fn route ->
        route.type == signal.type &&
          Aikido.Slice.Info.action_reference(mount.module, route.action) == signal.action
      end)
    end)
  end

  defp invalid_resource_slice?(mount) do
    !Spark.Dsl.is?(mount.module, Ash.Resource) ||
      !Ash.Resource.Info.embedded?(mount.module) ||
      Aikido.Slice.Extension not in Spark.extensions(mount.module)
  end

  defp add_mounts(dsl, mounts, team_slice) do
    Enum.reduce_while(mounts, {:ok, dsl}, fn mount, {:ok, dsl} ->
      case Builder.add_new_attribute(dsl, mount.path, mount.module,
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

  defp add_signals(dsl, signals) do
    # The verifier checks duplicate declarations; generation must not bind a
    # second command to the handler generated for the first one.
    signals
    |> Enum.uniq_by(& &1.name)
    |> Enum.reduce_while({:ok, dsl}, fn signal, {:ok, dsl} ->
      case add_signal(dsl, signal) do
        {:ok, dsl} -> {:cont, {:ok, dsl}}
        error -> {:halt, error}
      end
    end)
  end

  defp add_signal(dsl, signal) do
    case Enum.find(Transformer.get_entities(dsl, [:actions]), &(&1.name == signal.name)) do
      nil ->
        {arguments, shape} = signal_arguments(dsl, signal)

        dsl =
          if shape == :flat do
            Transformer.persist(dsl, :aikido_flat_signal_inputs, [
              signal.name | Transformer.get_persisted(dsl, :aikido_flat_signal_inputs, [])
            ])
          else
            dsl
          end

        description =
          with module when is_atom(module) and not is_nil(module) <- signal.signal_module,
               {:ok, description} <- Aikido.Signal.Info.signal_description(module) do
            description
          else
            _ -> nil
          end

        options = [
          returns: :map,
          run: {Aikido.Agent.Commands.Signal, []},
          arguments: [reference_argument() | arguments]
        ]

        options =
          if description, do: Keyword.put(options, :description, description), else: options

        Builder.add_new_action(dsl, :action, signal.name, options)

      %{type: :action, run: nil} = action ->
        updated = %{
          action
          | run: {Aikido.Agent.Commands.Signal, []},
            arguments: [reference_argument() | action.arguments]
        }

        {:ok, Transformer.replace_entity(dsl, [:actions], updated, &(&1.name == signal.name))}

      _ ->
        error("Signal #{signal.name} requires a generic action without a run handler")
    end
  end

  defp build_argument!(name, type, options) do
    {:ok, argument} = Builder.build_action_argument(name, type, options)
    argument
  end

  defp reference_argument do
    build_argument!(:agent, :term,
      allow_nil?: false,
      description: "Stable agent ID, current PID, or a reference returned by start."
    )
  end

  defp startup_arguments(dsl) do
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

    arguments
  end

  defp add_lifecycle_actions(dsl) do
    arguments =
      startup_arguments(dsl) ++
        [
          build_argument!(:sync, Aikido.Durable.SyncPolicy,
            description:
              "Synchronization policy; omitted children inherit their parent's policy and roots default to periodic sync."
          )
        ]

    Enum.reduce_while(
      [
        {:start, Aikido.Agent.Commands.Start, :map, arguments},
        {:inspect, Aikido.Agent.Commands.Inspect, :term,
         [reference_argument(), build_argument!(:fields, {:array, :atom}, [])]},
        {:stop, Aikido.Agent.Commands.Stop, :map, [reference_argument()]},
        {:delete, Aikido.Agent.Commands.Delete, :map, [reference_argument()]},
        {:list, Aikido.Agent.Commands.List, {:array, :term},
         [
           build_argument!(:filter, :term, []),
           build_argument!(:sort, :term, default: []),
           build_argument!(:limit, :integer, constraints: [min: 0]),
           build_argument!(:offset, :integer, default: 0, constraints: [min: 0])
         ]}
      ],
      {:ok, dsl},
      fn {name, implementation, returns, arguments}, {:ok, dsl} ->
        case Builder.add_new_action(dsl, :action, name,
               returns: returns,
               run: {implementation, []},
               arguments: arguments
             ) do
          {:ok, dsl} -> {:cont, {:ok, dsl}}
          error -> {:halt, error}
        end
      end
    )
  end

  defp signal_arguments(_dsl, %{signal_module: module}) when not is_nil(module),
    do: {Aikido.Signal.Routes.payload_action_arguments(module), :flat}

  defp signal_arguments(dsl, %{action: {resource, name}}) do
    action =
      if resource == Transformer.get_persisted(dsl, :module) do
        Ash.Resource.Info.action(dsl, name)
      else
        Code.ensure_compiled!(resource)
        Ash.Resource.Info.action(resource, name)
      end

    case Enum.find(action.arguments, &(&1.name == :data)) do
      nil ->
        arguments =
          action.arguments
          |> Enum.reject(&(&1.name == :state))
          |> Enum.map(&%{&1 | public?: true})

        if arguments == [],
          do: {[build_argument!(:data, :map, default: %{}, allow_nil?: false)], :whole},
          else: {arguments, :flat}

      data ->
        case Keyword.get(data.constraints, :fields, []) do
          [] ->
            {[%{data | public?: true}], :whole}

          fields ->
            arguments =
              for {name, options} <- fields do
                {type, options} = Keyword.pop!(options, :type)

                options =
                  Keyword.take(options, Keyword.keys(Ash.Resource.Actions.Argument.schema()))

                build_argument!(name, type, options)
              end

            {arguments, :flat}
        end
    end
  end

  defp error(message) do
    {:error, Spark.Error.DslError.exception(message: message, path: [:agent])}
  end
end
