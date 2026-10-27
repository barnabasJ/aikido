defmodule AgentExamples.Telemetry.SystemSnapshot do
  @moduledoc "Reads actual local agent processes and a bounded sample of their current work."
  @sample_limit 40

  def read do
    observations = AgentExamples.Telemetry.Observations.snapshot()
    pool = Aikido.durable_supervisor_name(Aikido.Default)

    Map.merge(observations, %{
      runtime: runtime_processes(pool),
      beam_processes: :erlang.system_info(:process_count),
      beam_memory: :erlang.memory(:total),
      run_queue: :erlang.statistics(:run_queue),
      sample_limit: @sample_limit
    })
  end

  defp runtime_processes(pool) do
    local = DurableServer.Supervisor.count_children(pool).active
    membership = length(Aikido.Durable.members(pool))
    tasks = length(Task.Supervisor.children(Aikido.task_supervisor_name(Aikido.Default)))

    agents =
      pool
      |> DurableServer.Supervisor.which_children()
      |> Enum.flat_map(fn
        {_, pid, _, _} when is_pid(pid) -> [pid]
        _ -> []
      end)
      |> Enum.sort()
      |> Enum.take(@sample_limit)
      |> Task.async_stream(&sample_agent/1,
        max_concurrency: 8,
        timeout: 500,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, row} -> [row]
        _ -> []
      end)

    %{
      local_agents: local,
      registered_agents: membership,
      io_tasks: tasks,
      agents: agents,
      error: nil
    }
  catch
    :exit, _ ->
      %{
        local_agents: nil,
        registered_agents: nil,
        io_tasks: nil,
        agents: [],
        error:
          "The runtime supervisor is unavailable or did not respond. Inspect supervisor logs and the Processes page."
      }
  end

  defp sample_agent(pid) do
    case Aikido.AgentServer.state(pid, &{:ok, describe_work(&1, pid)}, timeout: 100) do
      {:ok, row} -> row
      {:error, _} -> busy_agent(pid)
    end
  catch
    :exit, _ -> busy_agent(pid)
  end

  defp busy_agent(pid),
    do: %{
      pid: pid,
      id: "Unavailable",
      resource: nil,
      parent: nil,
      status: :unavailable,
      iteration: nil,
      tools: [],
      tasks: nil,
      mailbox: mailbox(pid)
    }

  defp describe_work(runtime, pid) do
    own_path = Spark.Dsl.Extension.get_opt(runtime.agent_module, [:agent], :path)
    own = Map.get(runtime.agent.state, own_path, %{})
    ai = feature(runtime, Aikido.AiReact.Slice)
    team = feature(runtime, Aikido.Team.Slice)
    parent = Aikido.Ownership.parent(runtime)

    %{
      pid: pid,
      id: runtime.id,
      resource: runtime.agent_module,
      parent: parent && parent.id,
      status: Map.get(ai, :status, Map.get(own, :status, :ready)),
      iteration: Map.get(ai, :iteration),
      tools: Enum.map(Map.get(ai, :pending_tool_calls, []), &Map.get(&1, :name, "unnamed tool")),
      tasks:
        Enum.count(Map.get(team, :tasks, %{}), fn {_, task} -> task.status == :dispatched end),
      mailbox: mailbox(pid)
    }
  end

  defp feature(runtime, module) do
    Enum.find_value(runtime.agent.state, %{}, fn
      {_, %{__struct__: ^module} = slice} -> slice
      _ -> nil
    end)
  end

  defp mailbox(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} -> length
      nil -> nil
    end
  end
end
