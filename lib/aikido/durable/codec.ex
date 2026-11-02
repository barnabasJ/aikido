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

  defp transform_saved_path(module, value, :externalize),
    do: module.externalize(value)

  @doc false
  def externalize_initial(attributes, agent_module, prepared? \\ false) do
    paths = paths(agent_module)
    known = Enum.map(paths, &elem(&1, 1))

    privacy = %{
      prepared?: prepared?,
      checkpoint?: function_exported?(agent_module, :checkpoint, 2)
    }

    with {:ok, mounted} <- retain_fields(attributes, known),
         attributes =
           if(mounted == %{} && attributes != %{},
             do: %{Aikido.Agent.Info.agent_path!(agent_module) => attributes},
             else: mounted
           ),
         {:ok, attributes} <- normalize_initial_paths(attributes, paths, agent_module),
         :ok <- require_prepared_bootstrap(attributes, agent_module, privacy) do
      Enum.reduce_while(paths, {:ok, attributes, []}, fn {module, path}, result ->
        externalize_supplied_path(module, path, result, privacy)
      end)
    end
  end

  defp normalize_initial_paths(attributes, paths, agent_module) do
    Enum.reduce_while(paths, {:ok, attributes}, fn {module, path}, {:ok, state} ->
      case Map.fetch(state, path) do
        {:ok, value} when not is_nil(value) ->
          fields = Enum.map(path_attributes(module, agent_module), & &1.name)

          with {:ok, value} <- Ash.Type.cast_input(:map, value),
               {:ok, value} <- retain_fields(value, fields) do
            {:cont, {:ok, Map.put(state, path, value)}}
          else
            _ -> {:halt, {:error, {:invalid_bootstrap_path, module, path}}}
          end

        _ ->
          {:cont, {:ok, state}}
      end
    end)
  end

  defp require_prepared_bootstrap(attributes, resource, privacy) do
    if privacy.checkpoint? && !privacy.prepared? && !paired?(resource) &&
         Enum.any?(attributes, fn {_path, value} -> value not in [nil, %{}] end) do
      {:error,
       {:bootstrap_preparation_required, resource, Aikido.Agent.Info.agent_path!(resource)}}
    else
      :ok
    end
  end

  defp externalize_supplied_path(module, path, {:ok, state, encoded}, privacy) do
    case Map.fetch(state, path) do
      {:ok, value} when not is_nil(value) ->
        with {:ok, value, encoded} <- encode_initial_path(module, path, value, encoded, privacy),
             {:ok, stored} <- Ash.Type.dump_to_embedded(:term, value),
             {:ok, value} <- Ash.Type.cast_from_embedded(:term, stored) do
          {:cont, {:ok, Map.put(state, path, value), encoded}}
        else
          {:error, {:bootstrap_preparation_required, _, _}} = error -> {:halt, error}
          _ -> {:halt, {:error, {:bootstrap_codec_failed, module, path}}}
        end

      _ ->
        {:cont, {:ok, state, encoded}}
    end
  rescue
    _error -> {:halt, {:error, {:bootstrap_codec_failed, module, path}}}
  end

  defp encode_initial_path(_module, _path, value, encoded, _privacy) when map_size(value) == 0,
    do: {:ok, value, encoded}

  defp encode_initial_path(module, path, value, encoded, privacy) do
    cond do
      paired?(module) ->
        {:ok, module.externalize(value), [path | encoded]}

      privacy.checkpoint? && !privacy.prepared? ->
        {:error, {:bootstrap_preparation_required, module, path}}

      true ->
        {:ok, value, encoded}
    end
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
    Enum.each(encoded, fn
      {:callbacks, _, _} ->
        raise ArgumentError,
              "Uninitialized snapshot uses retired callback bookkeeping. Delete the saved identity and start it again with its owning codec; initialized snapshots remain supported."

      _ ->
        :ok
    end)

    Enum.reduce(paths(agent_module), attributes, fn {module, path}, state ->
      if path in encoded,
        do: Map.update!(state, path, &reinstate_value(module, &1, true)),
        else: state
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
