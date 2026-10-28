defmodule Aikido.Durable.Codec do
  @moduledoc """
  Optional serialization callbacks for agent and slice state in DurableServer snapshots.

  `externalize/1` receives the value at the agent's own state path or the slice's
  mount path. `reinstate/1` reconstructs that value on activation. Modules without
  these callbacks retain their state unchanged. Both callbacks must be provided
  together, and the stored value must contain everything needed for restoration.

  An optional `reinstate/2` receives `%{fresh?: true}` for fresh bootstrap input
  and `%{fresh?: false}` for saved state. Use it to keep reversible input decoding
  separate from interrupted-run settlement; existing `reinstate/1` remains valid.

  Agent-wide snapshot customization uses `c:Aikido.Agent.checkpoint/2` and
  `c:Aikido.Agent.restore/2`. Path codecs run before checkpoint and after restore.
  """

  @callback externalize(term()) :: term()
  @callback reinstate(term()) :: term()
  @callback reinstate(term(), %{fresh?: boolean()}) :: term()
  @optional_callbacks reinstate: 2

  @doc false
  def transform_agent(agent, agent_module, callback)
      when callback in [:externalize, :reinstate] do
    state =
      Enum.reduce(paths(agent_module), agent.state, fn {module, path}, state ->
        if Map.has_key?(state, path) && paired?(module) do
          Map.update!(state, path, &transform_saved_path(module, &1, callback))
        else
          state
        end
      end)

    %{agent | state: state}
  end

  defp transform_saved_path(module, value, :reinstate),
    do: reinstate_value(module, value, false)

  defp transform_saved_path(module, value, :externalize), do: module.externalize(value)

  @doc false
  def externalize_initial(attributes, agent_module, prepared? \\ false) do
    paths = paths(agent_module)
    known = Enum.map(paths, &elem(&1, 1))

    attributes =
      if map_size(attributes) > 0 && !Enum.any?(Map.keys(attributes), &(&1 in known)),
        do: %{Aikido.Agent.Info.agent_path!(agent_module) => attributes},
        else: attributes

    with {:ok, attributes} <- retain_fields(attributes, known) do
      privacy = %{
        prepared?: prepared?,
        checkpoint?: function_exported?(agent_module, :checkpoint, 2)
      }

      Enum.reduce_while(paths, {:ok, attributes, []}, fn {module, path}, result ->
        externalize_supplied_path(module, path, agent_module, result, privacy)
      end)
    end
  end

  defp externalize_supplied_path(module, path, agent_module, {:ok, state, encoded}, privacy) do
    case Map.fetch(state, path) do
      {:ok, value} when is_map(value) and map_size(value) > 0 ->
        attributes = path_attributes(module, agent_module)

        case Aikido.Durable.BootstrapShape.project(value, attributes) do
          {:ok, value} ->
            externalize_initial_path(module, path, value, state, encoded, privacy, attributes)

          {:error, _} ->
            {:halt, {:error, {:invalid_bootstrap_path, module, path}}}
        end

      {:ok, value} when not is_map(value) and not is_nil(value) ->
        {:halt, {:error, {:invalid_bootstrap_path, module, path}}}

      _ ->
        {:cont, {:ok, state, encoded}}
    end
  end

  defp externalize_initial_path(module, path, value, state, encoded, privacy, attributes) do
    projection =
      cond do
        map_size(value) == 0 ->
          {:ok, value, encoded}

        paired?(module) ->
          {:ok, module.externalize(value), [path | encoded]}

        privacy.checkpoint? && !privacy.prepared? ->
          {:error, {:bootstrap_preparation_required, module, path}}

        true ->
          {:ok, value, encoded}
      end

    with {:ok, value, encoded} <- projection,
         {:ok, value, locations} <-
           Aikido.Durable.BootstrapCallbacks.externalize(value, attributes) do
      encoded = if locations == [], do: encoded, else: [{:callbacks, path, locations} | encoded]
      {:cont, {:ok, Map.put(state, path, value), encoded}}
    else
      {:error, {:bootstrap_preparation_required, _, _}} = error -> {:halt, error}
      {:error, _} -> {:halt, {:error, {:bootstrap_codec_failed, module, path}}}
    end
  rescue
    _error -> {:halt, {:error, {:bootstrap_codec_failed, module, path}}}
  end

  defp path_attributes(module, agent_module) do
    if module == agent_module do
      module
      |> Aikido.Agent.Info.state_fields()
      |> Enum.map(&Ash.Resource.Info.attribute(module, &1))
    else
      Ash.Resource.Info.attributes(module)
    end
  end

  defp retain_fields(value, fields) do
    fields = Enum.map(fields, &{&1, [type: :term, allow_nil?: true]})

    with {:ok, constraints} <- Ash.Type.init(:map, fields: fields, preserve_nil_values?: true) do
      Ash.Type.apply_constraints(:map, value, constraints)
    end
  end

  @doc false
  def reinstate_initial(attributes, agent_module, encoded) do
    Enum.reduce(paths(agent_module), attributes, fn {module, path}, state ->
      case Map.fetch(state, path) do
        {:ok, value} ->
          locations =
            Enum.find_value(encoded, [], fn
              {:callbacks, ^path, locations} -> locations
              _ -> nil
            end)

          case Aikido.Durable.BootstrapCallbacks.reinstate(value, locations) do
            {:ok, value} ->
              value = if path in encoded, do: reinstate_value(module, value, true), else: value

              case Aikido.Durable.BootstrapCallbacks.normalize_optional_nil(
                     value,
                     module,
                     path_attributes(module, agent_module)
                   ) do
                {:ok, value} -> Map.put(state, path, value)
                {:error, _} -> raise ArgumentError, "Cannot normalize bootstrap callbacks"
              end

            {:error, _} ->
              raise ArgumentError,
                    "Cannot restore bootstrap callbacks at #{inspect(module)} #{inspect(path)}"
          end

        :error ->
          state
      end
    end)
  end

  defp reinstate_value(module, value, fresh?) do
    if function_exported?(module, :reinstate, 2),
      do: module.reinstate(value, %{fresh?: fresh?}),
      else: module.reinstate(value)
  end

  defp paired?(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :externalize, 1) &&
      function_exported?(module, :reinstate, 1)
  end

  defp paths(agent_module) do
    mounts =
      agent_module
      |> Aikido.Agent.Info.slice_instances()
      |> Enum.map(&{&1.module, &1.path})

    own =
      case Spark.Dsl.Extension.get_opt(agent_module, [:agent], :path) do
        nil -> []
        path -> [{agent_module, path}]
      end

    own ++ mounts
  end
end
