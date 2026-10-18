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
    resource = Transformer.get_persisted(dsl, :module)
    name = Transformer.get_option(dsl, [:agent], :name)
    path = Transformer.get_option(dsl, [:agent], :path, :state)
    middleware = Transformer.get_option(dsl, [:agent], :middleware, [])
    team_slice = Transformer.get_persisted(dsl, :aikido_team_slice)
    entities = Transformer.get_entities(dsl, [:agent])
    mounts = Enum.filter(entities, &match?(%Aikido.Dsl.Agent.SliceMount{}, &1))
    declared_signals = Enum.filter(entities, &match?(%Aikido.Ash.Agent.Signal{}, &1))
    {dsl, declared_signals} = resolve_local_actions(dsl, declared_signals, resource)
    inherited = inherited_signals(mounts, declared_signals)
    signals = declared_signals ++ inherited
    dsl = Enum.reduce(inherited, dsl, &Transformer.add_entity(&2, [:agent], &1))

    declared = Transformer.get_entities(dsl, [:agent, :schema])
    existing = Ash.Resource.Info.attributes(dsl)
    duplicates = Enum.map(declared ++ existing, & &1.name)

    if length(duplicates) != length(Enum.uniq(duplicates)) do
      raise Spark.Error.DslError,
        message: "Agent schema and resource attributes must have unique names",
        path: [:agent, :schema]
    end

    dsl = Enum.reduce(declared, dsl, &Transformer.add_entity(&2, [:attributes], &1))
    attributes = Ash.Resource.Info.attributes(dsl)

    state_fields = for attribute <- attributes, attribute.name != :id, do: attribute.name

    with :ok <- validate(path, mounts, signals),
         :ok <- validate_attributes(attributes, path, mounts),
         {:ok, dsl} <-
           Builder.add_new_attribute(dsl, :id, :string,
             primary_key?: true,
             allow_nil?: false,
             public?: true,
             default: &Aikido.Util.generate_id/0
           ),
         {:ok, dsl} <- add_mounts(dsl, mounts, team_slice),
         {:ok, dsl} <- add_lifecycle_actions(dsl),
         {:ok, dsl} <- add_signals(dsl, signals, mounts) do
      slices =
        Enum.map(mounts, fn mount ->
          module = mount.module

          quote do
            slice(unquote(mount.path), unquote(module),
              options: unquote(Macro.escape(mount.options))
            )
          end
        end)

      routes =
        for signal <- signals, !mounted_signal?(signal, mounts) do
          quote do
            route unquote(signal.type), unquote(Macro.escape(signal.target))
          end
        end

      runtime = Module.concat(resource, Runtime)

      block =
        quote do
          defmodule unquote(runtime) do
            import Aikido.Ash.Agent, only: []
            use Aikido.Agent, default_slices: false, middleware: unquote(Macro.escape(middleware))

            # Ash has already cast these attributes and applied their defaults.
            # Reuse the resource's contracts; do not create a second schema type.
            @persist {:aikido_agent_schema, unquote(resource)}
            @persist {:aikido_resource, unquote(resource)}

            @doc false
            def __aikido_resource__, do: unquote(resource)

            agent do
              name unquote(name)
              path unquote(path)
            end

            slices do
              (unquote_splicing(slices))
            end

            signal_routes do
              (unquote_splicing(routes))
            end
          end

          @doc false
          def __aikido_runtime__, do: unquote(runtime)

          @doc false
          def __aikido_state_fields__, do: unquote(state_fields)
        end

      {:ok, Transformer.eval(dsl, [], block)}
    end
  end

  defp validate_attributes(attributes, path, mounts) do
    reserved = [path | Enum.map(mounts, & &1.path)]

    if Enum.any?(attributes, &(&1.name in reserved)) do
      error("Resource attributes cannot collide with the agent state path or mounted slice paths")
    else
      :ok
    end
  end

  defp validate(path, mounts, signals) do
    paths = [path | Enum.map(mounts, & &1.path)]
    names = Enum.map(signals, & &1.name)

    cond do
      :id in paths ->
        error("The :id attribute is reserved for the agent identity")

      length(paths) != length(Enum.uniq(paths)) ->
        error("Agent state and slice paths must be unique")

      length(names) != length(Enum.uniq(names)) ->
        error("Agent signal action names must be unique")

      Enum.any?(mounts, &invalid_resource_slice?/1) ->
        error("Resource slices must be embedded Ash resources with Aikido.Ash.Slice")

      Enum.any?(signals, &String.contains?(&1.type, "*")) ->
        error("Public signals require a concrete type; mark wildcard slice actions public? false")

      Enum.any?(signals, &is_nil(&1.target)) ->
        error("Every signal must have a target action")

      true ->
        :ok
    end
  end

  # A local reducer and its public command may share a declared name. Keep the
  # native reducer private and generate the command under the public name.
  defp resolve_local_actions(dsl, signals, resource) do
    Enum.map_reduce(signals, dsl, fn signal, dsl ->
      case signal.target do
        name when is_atom(name) and not is_nil(name) ->
          case Ash.Resource.Info.action(dsl, name) do
            %{type: :action, returns: Aikido.ActionResult} = action ->
              internal = String.to_atom("__aikido_reduce_#{name}")
              reducer = %{action | name: internal, public?: false}
              dsl = Transformer.remove_entity(dsl, [:actions], &(&1.name == name))
              dsl = Transformer.add_entity(dsl, [:actions], reducer)
              resolved = %{signal | target: {resource, internal}}
              dsl = Transformer.replace_entity(dsl, [:agent], resolved, &(&1 == signal))
              {resolved, dsl}

            _ ->
              {signal, dsl}
          end

        _ ->
          {signal, dsl}
      end
    end)
    |> then(fn {signals, dsl} -> {dsl, signals} end)
  end

  defp inherited_signals(mounts, declared) do
    for mount <- mounts,
        Spark.Dsl.is?(mount.module, Ash.Resource),
        Aikido.Ash.Slice in Spark.extensions(mount.module),
        route <- Spark.Dsl.Extension.get_entities(mount.module, [:slice]),
        action = Ash.Resource.Info.action(mount.module, route.action),
        action.public?,
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
    Spark.Dsl.is?(mount.module, Ash.Resource) &&
      (!Ash.Resource.Info.embedded?(mount.module) ||
         Aikido.Ash.Slice not in Spark.extensions(mount.module))
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
    Enum.reduce_while(signals, {:ok, dsl}, fn signal, {:ok, dsl} ->
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
                Keyword.take(options, [:constraints, :allow_nil?, :default, :description])
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
        if Enum.any?(arguments, &(&1.name == :topology)) do
          raise Spark.Error.DslError,
            message: "Team resources reserve :topology for the startup graph",
            path: [:agent, :schema]
        end

        arguments ++
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
    {resource, name} = Aikido.ActionRef.normalize(target)

    if resource == Transformer.get_persisted(dsl, :module) do
      action = Ash.Resource.Info.action(dsl, name)

      case Enum.find(action.arguments, &(&1.name == :data)) do
        nil ->
          for argument <- action.arguments,
              argument.name != :state,
              do:
                {argument.name,
                 Map.take(argument, [:type, :constraints, :allow_nil?, :default, :description])
                 |> Map.to_list()}

        data ->
          Keyword.get(data.constraints, :fields, [])
      end
    else
      Code.ensure_compiled!(resource)
      Aikido.ActionRef.schema(target)
    end
  end

  defp error(message) do
    {:error, Spark.Error.DslError.exception(message: message, path: [:agent])}
  end
end
