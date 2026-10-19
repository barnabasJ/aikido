defmodule Aikido.Ash.Runtime do
  @moduledoc false
  alias Aikido.AgentServer

  def option(resource, key), do: Spark.Dsl.Extension.get_opt(resource, [:agent], key)

  def start(resource, input, context \\ %{}) do
    with {:ok, topology} <- startup_topology(resource, input.arguments[:topology]) do
      start_process(resource, input, topology, context)
    end
  end

  defp startup_topology(resource, definition) do
    if function_exported?(resource, :__aikido_team_config__, 0) do
      config = resource.__aikido_team_config__()

      Aikido.Ash.Team.Topology.build(
        definition || config.topology.nodes,
        config.instance,
        config.max_members
      )
    else
      {:ok, nil}
    end
  end

  defp start_process(resource, input, topology, context) do
    attributes =
      Map.new(Ash.Resource.Info.attributes(resource), fn attr ->
        {attr.name, Map.get_lazy(input.arguments, attr.name, fn -> default(attr.default) end)}
      end)

    record = struct(resource, attributes)

    runtime_options =
      input.context
      |> Map.get(:aikido_runtime_options, [])
      |> Keyword.take([:parent, :partition, :on_parent_death, :restart])
      |> Keyword.merge(id: record.id, initial_state: initial_state(resource, record))

    safe(fn ->
      with {:ok, pid} <-
             Aikido.start_agent(
               option(resource, :instance),
               resource.__aikido_runtime__(),
               runtime_options
             ) do
        pool = Aikido.durable_supervisor_name(option(resource, :instance))

        restored? =
          Process.whereis(pool) && Aikido.Durable.restored?(pool, record.id, runtime_options)

        result =
          if function_exported?(resource, :__aikido_team_config__, 0) && !restored?,
            do:
              Aikido.Ash.Team.start(
                resource,
                pid,
                topology.nodes,
                command_context(input, context)
              ),
            else: {:ok, :ready}

        case result do
          {:ok, _} ->
            {:ok, reference(resource, record.id, pid)}

          error ->
            Aikido.stop_agent(option(resource, :instance), pid)
            error
        end
      end
    end)
  end

  defp default(fun) when is_function(fun, 0), do: fun.()
  defp default({module, function, args}), do: apply(module, function, args)
  defp default(value), do: value

  def signal(resource, input, context \\ %{}) do
    definition =
      resource
      |> Spark.Dsl.Extension.get_entities([:agent])
      |> Enum.find(&(match?(%Aikido.Ash.Agent.Signal{}, &1) && &1.name == input.action.name))

    arguments = Map.delete(input.arguments, :agent)

    payload =
      if input.action.name in Spark.Dsl.Extension.get_persisted(
           resource,
           :aikido_flat_signal_inputs,
           []
         ), do: arguments, else: Map.get(arguments, :data, arguments)

    safe(fn ->
      with {:ok, {id, pid}} <- resolve(resource, input.arguments.agent),
           {:ok, signal} <- Jido.Signal.new(definition.type, payload, source: "/ash"),
           signal = Aikido.SignalCtx.put_ctx(signal, command_context(input, context)),
           {:ok, _} <- dispatch(resource, pid, signal) do
        {:ok,
         Map.merge(reference(resource, id, pid), %{signal_id: signal.id, status: :processed})}
      end
    end)
  end

  defp command_context(input, context) do
    input.context
    |> Map.drop([:private, :aikido_runtime_options, :aikido, :authorize?])
    |> Map.merge(Map.take(context, [:actor, :tenant, :tracer]))
  end

  defp dispatch(resource, pid, signal) do
    if function_exported?(resource, :__aikido_team_config__, 0) &&
         signal.type in ~w(aikido.ash.team.start aikido.ash.team.reconcile aikido.ash.team.add_member aikido.ash.team.remove_member aikido.ash.team.ensure_member aikido.ash.team.stop_member) do
      Aikido.Ash.Team.call(resource, pid, signal)
    else
      AgentServer.call(pid, signal, fn _ -> {:ok, :processed} end)
    end
  end

  def stop(resource, agent) do
    safe(fn ->
      with {:ok, {id, pid}} <- resolve(resource, agent),
           :ok <- Aikido.stop_agent(option(resource, :instance), pid) do
        {:ok, %{id: id, resource: resource, status: :stopped}}
      end
    end)
  end

  def delete(resource, agent) do
    safe(fn ->
      with {:ok, {id, target}} <- deletion_id(resource, agent),
           :ok <- delete_process(resource, target) do
        {:ok, %{id: id, resource: resource, status: :deleted}}
      end
    end)
  end

  defp deletion_id(resource, pid) when is_pid(pid) do
    with {:ok, {id, _pid}} <- resolve(resource, pid), do: {:ok, {id, pid}}
  end

  defp deletion_id(resource, %{id: id}), do: deletion_id(resource, id)
  defp deletion_id(_resource, id) when is_binary(id), do: {:ok, {id, id}}
  defp deletion_id(_resource, _), do: {:error, "Expected an agent ID, PID, or reference"}

  defp delete_process(resource, pid) when is_pid(pid) do
    with {:ok, {pool, key, partition}} <-
           AgentServer.state(pid, fn runtime ->
             {:ok, {runtime.lifecycle.pool, runtime.lifecycle.pool_key, runtime.partition}}
           end) do
      if pool do
        Aikido.Durable.delete(pool, key,
          agent: resource.__aikido_runtime__(),
          partition: partition
        )
      else
        Aikido.stop_agent(option(resource, :instance), pid)
      end
    end
  end

  defp delete_process(resource, id) do
    instance = option(resource, :instance)
    pool = Aikido.durable_supervisor_name(instance)

    if Process.whereis(pool) do
      Aikido.Durable.delete(pool, id, agent: resource.__aikido_runtime__())
    else
      with {:ok, {_id, pid}} <- resolve(resource, id), do: Aikido.stop_agent(instance, pid)
    end
  end

  def inspect_agent(resource, agent) do
    safe(fn ->
      with {:ok, {_id, pid}} <- resolve(resource, agent), do: snapshot(resource, pid)
    end)
  end

  defp reference(resource, id, pid), do: %{id: id, pid: pid, resource: resource}

  def list(resource, arguments \\ %{}) do
    safe(fn ->
      Enum.reduce_while(Aikido.list_agents(option(resource, :instance)), {:ok, []}, fn
        {_id, pid}, {:ok, records} ->
          case live_snapshot(resource, pid) do
            {:ok, record} -> {:cont, {:ok, [record | records]}}
            {:error, :different_resource} -> {:cont, {:ok, records}}
            {:error, :not_running} -> {:cont, {:ok, records}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end)
      |> case do
        {:ok, records} ->
          with {:ok, filter} <-
                 Ash.Filter.parse(resource, Map.get(arguments, :filter), %{eval?: true}),
               {:ok, records} <-
                 Ash.Filter.Runtime.filter_matches(
                   Ash.Resource.Info.domain(resource),
                   records,
                   filter
                 ) do
            records =
              records
              |> Ash.Actions.Sort.runtime_sort(Map.get(arguments, :sort, []))
              |> Enum.drop(Map.get(arguments, :offset, 0))

            {:ok, if(arguments[:limit], do: Enum.take(records, arguments.limit), else: records)}
          end

        error ->
          error
      end
    end)
  end

  defp resolve(resource, %{id: id}), do: resolve(resource, id)

  defp resolve(resource, id) when is_binary(id) do
    case Aikido.whereis(option(resource, :instance), id) do
      nil -> {:error, "Agent #{id} is not running"}
      pid -> resolve(resource, pid)
    end
  end

  defp resolve(resource, pid) when is_pid(pid) do
    AgentServer.state(pid, fn state ->
      if state.agent.agent_module == resource.__aikido_runtime__(),
        do: {:ok, {state.agent.id, pid}},
        else: {:error, :different_resource}
    end)
  end

  defp resolve(_resource, _), do: {:error, "Expected an agent ID, PID, or reference"}

  defp snapshot(resource, pid) do
    AgentServer.state(pid, fn state ->
      if state.agent.agent_module == resource.__aikido_runtime__() do
        {:ok, record(resource, state.agent)}
      else
        {:error, :different_resource}
      end
    end)
  end

  # Registry cleanup can lag process termination, including immediately after
  # destroy. A read enumerates live agents, so omit entries that have exited.
  defp live_snapshot(resource, pid) do
    snapshot(resource, pid)
  catch
    :exit, {reason, {GenServer, :call, _}} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :not_running}
  end

  defp record(resource, agent) do
    attributes =
      Map.new(Ash.Resource.Info.attributes(resource), fn attr ->
        value =
          cond do
            attr.name == :id ->
              agent.id

            attr.name in resource.__aikido_state_fields__() ->
              agent.state |> Map.get(option(resource, :path), %{}) |> Map.get(attr.name)

            true ->
              Map.get(agent.state, attr.name)
          end

        value =
          if is_map(value) && !is_struct(value) && Spark.Dsl.is?(attr.type, Ash.Resource),
            do: struct(attr.type, value),
            else: value

        {attr.name, value}
      end)

    struct(resource, attributes)
  end

  defp initial_state(resource, record) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Map.new(fn attr ->
      value = Map.get(record, attr.name)
      {attr.name, value}
    end)
    |> Map.delete(:id)
    |> then(fn attributes ->
      {own_state, slices} = Map.split(attributes, resource.__aikido_state_fields__())

      slices =
        if function_exported?(resource, :__aikido_ai__, 0) do
          configuration =
            Map.take(own_state, [
              :options,
              :tools,
              :tool_options,
              :tool_context,
              :hooks,
              :model,
              :client,
              :llm_opts,
              :system_prompt,
              :max_iterations
            ])

          tool_options =
            Keyword.put_new_lazy(configuration.tool_options, :otp_app, fn ->
              Spark.otp_app(resource) || Spark.otp_app(Ash.Resource.Info.domain(resource)) ||
                :aikido
            end)

          configuration = Map.put(configuration, :tool_options, tool_options)
          Map.put(slices, :ai, Map.merge(Map.get(slices, :ai) || %{}, configuration))
        else
          slices
        end

      Map.put(slices, option(resource, :path), own_state)
    end)
  end

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, "Agent runtime unavailable: #{inspect(reason)}"}
  end
end
