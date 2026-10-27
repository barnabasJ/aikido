defmodule Aikido.Durable.Snapshot do
  @moduledoc """
  Serializes a complete agent through native Ash embedded types.

  The composed state schema comes from the agent and slice declarations. One
  native struct dump/cast traverses the complete agent and its mounted slices.
  An application codec that changes a path's shape owns
  that representation; its output uses Ash's opaque term type. Agent-wide
  checkpoint callbacks likewise remain application-owned contracts.

  Ash's term and embedded binary types encode the transport envelope. It is
  not a serialization of the live runtime or its process state. The same
  native casts restore legacy envelopes, including compressed terms.
  """

  @format "ash-embedded-v2"
  @agent_constraints (case Ash.Type.init(Aikido.Agent, []) do
                        {:ok, constraints} -> constraints
                      end)
  @options_constraints (case Ash.Type.init(Aikido.AgentServer.Options, []) do
                          {:ok, constraints} -> constraints
                        end)
  @boot_options [
    :agent_module,
    :id,
    :aikido,
    :partition,
    :durable_server,
    :durable_key,
    :on_parent_death,
    :skip_schedules,
    :debug,
    :middleware,
    :sync
  ]

  @doc "Retain restart configuration without duplicating initial state or caller scope."
  def boot_options(options), do: Keyword.take(options, @boot_options)

  @doc "Dump native state types before encoding the persistence transport envelope."
  def dump(saved) do
    resource = Keyword.fetch!(saved.options, :agent_module)

    options =
      Aikido.AgentServer.Options.new!(boot_options(saved.options))
      |> then(
        &transform!(
          :dump_to_embedded,
          Aikido.AgentServer.Options,
          &1,
          @options_constraints,
          :options
        )
      )
      |> Map.take(@boot_options)

    stored =
      saved
      |> Map.put(:options, options)
      |> Map.update!(:agent, fn
        {:agent, agent} ->
          opaque_paths = opaque_paths(agent, resource)
          constraints = agent_constraints(resource, opaque_paths)

          value =
            if custom_codec?(resource),
              do: agent,
              else: %{agent | state: Aikido.Agent.resource_attributes(agent)}

          dumped = transform!(:dump_to_embedded, :struct, value, constraints, :agent)
          {:ash_agent, %{state: dumped, opaque_paths: opaque_paths}}

        checkpoint ->
          checkpoint
      end)

    %{
      "format" => @format,
      "resource" => Atom.to_string(resource),
      "payload" =>
        stored
        |> then(&transform!(:dump_to_embedded, :term, &1, [], :payload))
        |> then(&transform!(:dump_to_embedded, :binary, &1, [], :payload))
    }
  end

  @doc "Load a typed envelope after loading the resource that declares its field types."
  def load(%{"format" => format, "resource" => resource_name, "payload" => payload})
      when format in [@format, "ash-embedded-v1"] do
    resource = String.to_existing_atom(resource_name)
    Code.ensure_loaded!(resource)
    paths = path_types(resource)
    load_declared_implementations(paths)

    payload
    |> decode_transport()
    |> Map.update!(:options, fn stored_options ->
      stored_options
      |> then(
        &transform!(
          :cast_from_embedded,
          Aikido.AgentServer.Options,
          &1,
          @options_constraints,
          :options
        )
      )
      |> Map.from_struct()
      |> Map.to_list()
      |> boot_options()
    end)
    |> Map.update!(:agent, fn
      {:ash_agent, agent} -> {:agent, load_agent(format, agent, resource, paths)}
      checkpoint -> checkpoint
    end)
  end

  def load(%{"payload" => payload}), do: decode_transport(payload)

  defp decode_transport(payload) do
    payload
    |> then(&transform!(:cast_from_embedded, :binary, &1, [], :payload))
    |> then(&transform!(:cast_from_embedded, :term, &1, [], :payload))
  end

  defp opaque_paths(agent, resource) do
    resource
    |> path_types()
    |> Enum.filter(fn {path, owner} ->
      {type, _constraints} = storage_type(owner, Map.get(agent.state, path))
      type == :term
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp agent_constraints(resource, opaque_paths) do
    snapshot = Ash.Resource.Info.action(resource, :__aikido_snapshot__)
    argument = Enum.find(snapshot.arguments, &(&1.name == :snapshot))

    resource_fields =
      Enum.map(argument.constraints[:fields], fn {name, options} ->
        if name in opaque_paths,
          do: {name, [type: :term]},
          else: {name, options}
      end)

    state_type = if custom_codec?(resource), do: :term, else: :struct

    state_constraints =
      if state_type == :term,
        do: [],
        else: Keyword.put(argument.constraints, :fields, resource_fields)

    Keyword.update!(@agent_constraints, :fields, fn fields ->
      Keyword.update!(fields, :state, fn options ->
        options
        |> Keyword.put(:type, Ash.Type.get_type(state_type))
        |> Keyword.put(:constraints, state_constraints)
      end)
    end)
  end

  defp load_agent(@format, %{state: state, opaque_paths: opaque_paths}, resource, _paths) do
    constraints = agent_constraints(resource, opaque_paths)
    agent = transform!(:cast_from_embedded, :struct, state, constraints, :agent)

    if custom_codec?(resource),
      do: agent,
      else: %{agent | state: Aikido.Agent.state_from_resource(agent.state)}
  end

  defp load_agent("ash-embedded-v1", stored, resource, paths) do
    state =
      Map.new(paths, fn {path, owner} ->
        case Map.fetch(stored["state"], Atom.to_string(path)) do
          {:ok, value} ->
            {type, constraints} = if value["opaque"], do: {:term, []}, else: declared_type(owner)
            {path, transform!(:cast_from_embedded, type, value["value"], constraints, path)}

          :error ->
            {path, nil}
        end
      end)
      |> Map.reject(fn {_path, value} -> is_nil(value) end)

    Aikido.Agent.new!(
      id: stored["id"],
      agent_module: resource,
      name: stored["name"],
      description: stored["description"],
      state: state
    )
  end

  defp path_types(resource) do
    own_path = Spark.Dsl.Extension.get_opt(resource, [:agent], :path)

    mounts =
      Enum.map(Aikido.Agent.Info.slice_instances(resource), &{&1.path, {:slice, &1.module}})

    paths = [{own_path, {:agent, resource}} | mounts]
    Enum.each(paths, fn {_path, {_kind, module}} -> Code.ensure_loaded!(module) end)
    Map.new(paths)
  end

  # Opaque attribute values may contain atoms declared in reducer modules (for
  # example a stable cron job ID). Load the resource's compiled contracts before
  # safe decoding, just as its embedded types must be loaded before casting.
  defp load_declared_implementations(paths) do
    Code.ensure_loaded!(Aikido.Signal)

    for {_path, {_kind, resource}} <- paths,
        action <- Ash.Resource.Info.actions(resource),
        {implementation, _options} <- List.wrap(Map.get(action, :run)) do
      Code.ensure_loaded!(implementation)
    end
  end

  defp storage_type({:slice, resource} = owner, value) do
    if custom_codec?(resource) && !is_struct(value, resource),
      do: {:term, []},
      else: declared_type(owner)
  end

  defp storage_type({:agent, resource} = owner, _value) do
    if custom_codec?(resource), do: {:term, []}, else: declared_type(owner)
  end

  defp declared_type({:slice, resource}), do: {resource, []}

  defp declared_type({:agent, resource}) do
    names = Aikido.Agent.Info.state_fields(resource)

    fields =
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.filter(&(&1.name in names))
      |> Enum.map(&{&1.name, [type: &1.type, constraints: &1.constraints]})

    {:map, [fields: fields, preserve_nil_values?: true]}
  end

  defp custom_codec?(resource),
    do:
      function_exported?(resource, :externalize, 1) && function_exported?(resource, :reinstate, 1)

  defp transform!(operation, type, value, constraints, path) do
    case apply(Ash.Type, operation, [type, value, constraints]) do
      {:ok, result} ->
        result

      error ->
        raise ArgumentError,
              "Cannot #{operation} snapshot path #{inspect(path)} with #{inspect(type)}: #{inspect(error)}"
    end
  end
end
