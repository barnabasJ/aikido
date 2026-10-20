defmodule Aikido.Ash.SignalRoutes do
  @moduledoc false
  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def expand(dsl, section) do
    entities = Transformer.get_entities(dsl, [section])

    Enum.reduce_while(entities, {:ok, dsl, []}, fn entity, {:ok, dsl, expanded} ->
      case expand_entity(dsl, section, entity) do
        {:ok, dsl, entries} -> {:cont, {:ok, dsl, expanded ++ entries}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, dsl, expanded} ->
        dsl = Transformer.remove_entity(dsl, [section], fn _ -> true end)

        {:ok,
         Enum.reduce(expanded, dsl, &Transformer.add_entity(&2, [section], &1, type: :append))}

      error ->
        error
    end
  end

  def arguments(module) do
    Enum.map(Aikido.Signal.Info.schema(module), fn attribute ->
      options =
        attribute
        |> Map.from_struct()
        |> Map.take(Keyword.keys(Ash.Resource.Actions.Argument.schema()))
        |> Map.drop([:name, :type, :public?])
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Keyword.put(:public?, true)

      {:ok, argument} = Builder.build_action_argument(attribute.name, attribute.type, options)
      argument
    end)
  end

  def valid_definition?(module) do
    is_atom(module) && Code.ensure_loaded?(module) &&
      Spark.Dsl.is?(module, Aikido.Signal.Definition)
  end

  def valid_implementation?(module) do
    is_atom(module) && match?({:module, _}, Code.ensure_compiled(module)) &&
      Spark.implements_behaviour?(module, Ash.Resource.Actions.Implementation)
  end

  defp expand_entity(dsl, section, %{type: types} = entity) when is_list(types) do
    cond do
      public?(entity) && not is_nil(entity.name) ->
        error(
          section,
          "Public signal lists infer one command name per signal; declare separate routes to give commands explicit names"
        )

      types == [] ->
        error(section, "A route requires at least one signal definition")

      !implementation_reference?(entity.action) ->
        error(section, "Signal lists require a native Ash action implementation module")

      true ->
        with {:ok, definitions} <- definitions(types, section),
             {:ok, dsl, target, implementation} <-
               handler(dsl, section, definitions, entity.action, public?(entity)) do
          entries =
            Enum.map(definitions, fn module ->
              Map.merge(entity, %{
                type: Aikido.Signal.Info.signal_type!(module),
                action: target,
                signal_module: module,
                implementation: implementation,
                public?: public?(entity),
                name: entity.name || handler_name(module)
              })
            end)

          {:ok, dsl, entries}
        end
    end
  end

  defp expand_entity(dsl, section, %{type: type} = entity)
       when is_struct(entity, Aikido.Ash.Agent.Route) or
              is_struct(entity, Aikido.Ash.Slice.Route) do
    with {:ok, definition, type} <- definition(type, section),
         {:ok, dsl, target, implementation} <-
           handler(dsl, section, definition, entity.action, public?(entity)) do
      name = entity.name || route_name(definition, target)

      entity = %{
        entity
        | type: type,
          signal_module: definition,
          implementation: implementation,
          action: target,
          public?: public?(entity),
          name: name
      }

      {:ok, dsl, [entity]}
    end
  end

  defp expand_entity(dsl, _section, entity), do: {:ok, dsl, [entity]}

  defp public?(%{public?: value}) when is_boolean(value), do: value
  defp public?(%{type: type}) when is_binary(type), do: !String.contains?(type, "*")
  defp public?(_), do: true

  defp route_name(definition, _) when not is_nil(definition), do: handler_name(definition)
  defp route_name(_, {_, action}), do: action
  defp route_name(_, action), do: action

  defp definitions(types, section) do
    Enum.reduce_while(types, {:ok, []}, fn type, {:ok, modules} ->
      case definition(type, section) do
        {:ok, module, _type} when not is_nil(module) -> {:cont, {:ok, modules ++ [module]}}
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, error(section, "Signal lists require signal definition modules")}
      end
    end)
  end

  defp definition(type, _section) when is_binary(type), do: {:ok, nil, type}

  defp definition(module, section) when is_atom(module) do
    with {:module, _} <- Code.ensure_compiled(module),
         true <- valid_definition?(module) do
      {:ok, module, Aikido.Signal.Info.signal_type!(module)}
    else
      _ -> error(section, "#{inspect(module)} must use Aikido.Signal")
    end
  end

  defp definition(value, section),
    do:
      error(
        section,
        "Expected a signal definition module or string pattern, got #{inspect(value)}"
      )

  defp handler(dsl, section, definition, target, public?) do
    if implementation_reference?(target) do
      with {:ok, dsl, action} <- generate(dsl, section, definition, target, public?) do
        {:ok, dsl, {Transformer.get_persisted(dsl, :module), action}, target}
      end
    else
      {:ok, dsl, target, nil}
    end
  end

  defp implementation_reference?(target) when is_atom(target),
    do: String.starts_with?(Atom.to_string(target), "Elixir.")

  defp implementation_reference?(_), do: false

  defp generate(dsl, section, definition, implementation, public?) do
    name =
      handler_name(if is_list(definition), do: implementation, else: definition || implementation)

    with {:ok, payload} <- payload_arguments(definition, section) do
      generate_action(dsl, section, definition, implementation, name, payload, public?)
    end
  end

  defp payload_arguments(definitions, section) when is_list(definitions) do
    labels = Enum.map(definitions, &handler_name/1)
    types = Enum.map(definitions, &Aikido.Signal.Info.signal_type!/1)

    if length(Enum.uniq(labels)) != length(labels) || length(Enum.uniq(types)) != length(types) do
      error(section, "Union signal definitions require unique names and signal types")
    else
      variants =
        Enum.zip_with(labels, definitions, fn label, module -> {label, [type: module]} end)

      {:ok, [argument!(:data, :union, allow_nil?: false, constraints: [types: variants])]}
    end
  end

  defp payload_arguments(nil, _section), do: {:ok, [argument!(:data, :term, [])]}
  defp payload_arguments(definition, _section), do: {:ok, arguments(definition)}

  defp generate_action(dsl, section, definition, implementation, name, payload, public?) do
    if Enum.any?(payload, &(&1.name == :state)) do
      error(section, "Signal payload field :state conflicts with the reducer state argument")
    else
      description =
        with module when is_atom(module) and not is_nil(module) <- definition,
             {:ok, description} <- Aikido.Signal.Info.signal_description(module) do
          description
        else
          _ -> nil
        end

      options = [
        returns: Aikido.Types.ActionResult,
        arguments: [state_argument(dsl, section) | payload],
        run: {implementation, []},
        public?: public? && section == :slice
      ]

      options = if description, do: Keyword.put(options, :description, description), else: options

      with {:ok, generated} <- Builder.build_action(:action, name, options),
           {:ok, dsl} <- add_handler(dsl, section, generated) do
        dsl =
          Transformer.persist(
            dsl,
            :aikido_generated_handlers,
            Map.put(
              Transformer.get_persisted(dsl, :aikido_generated_handlers, %{}),
              name,
              implementation
            )
          )

        dsl =
          if is_list(definition) do
            variants =
              Map.new(definition, &{Aikido.Signal.Info.signal_type!(&1), handler_name(&1)})

            Transformer.persist(
              dsl,
              :aikido_union_reducers,
              Map.put(Transformer.get_persisted(dsl, :aikido_union_reducers, %{}), name, variants)
            )
          else
            if definition do
              Transformer.persist(
                dsl,
                :aikido_flat_reducers,
                Enum.uniq([name | Transformer.get_persisted(dsl, :aikido_flat_reducers, [])])
              )
            else
              dsl
            end
          end

        {:ok, dsl, name}
      end
    end
  end

  defp add_handler(dsl, section, generated) do
    case Ash.Resource.Info.action(dsl, generated.name) do
      nil ->
        {:ok, Transformer.add_entity(dsl, [:actions], generated)}

      existing ->
        if Map.take(existing, [:type, :returns, :arguments, :run]) ==
             Map.take(generated, [:type, :returns, :arguments, :run]) do
          updated = %{existing | public?: existing.public? || generated.public?}

          {:ok,
           Transformer.replace_entity(dsl, [:actions], updated, &(&1.name == generated.name))}
        else
          error(
            section,
            "Generated handler #{inspect(generated.name)} conflicts with an existing native action"
          )
        end
    end
  end

  defp state_argument(dsl, section) do
    attributes =
      (Ash.Resource.Info.attributes(dsl) ++ Transformer.get_entities(dsl, [section, :schema]))
      |> Enum.uniq_by(& &1.name)
      |> Enum.reject(&(section == :agent && &1.name == :id))

    fields =
      Enum.map(attributes, fn attribute ->
        {attribute.name,
         [
           type: attribute.type,
           constraints: attribute.constraints,
           allow_nil?: attribute.allow_nil?
         ]}
      end)

    constraints = [fields: fields, preserve_nil_values?: true]

    if section == :slice do
      argument!(:state, :struct,
        allow_nil?: false,
        constraints:
          Keyword.put(constraints, :instance_of, Transformer.get_persisted(dsl, :module))
      )
    else
      argument!(:state, :map, allow_nil?: false, constraints: constraints)
    end
  end

  defp argument!(name, type, options) do
    {:ok, argument} = Builder.build_action_argument(name, type, options)
    argument
  end

  defp handler_name(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

  defp error(section, message),
    do: {:error, Spark.Error.DslError.exception(message: message, path: [section])}
end
