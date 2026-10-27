defmodule AgentExamples.AI do
  @moduledoc "External caller helpers shared by a single AI agent and an AI team."

  @doc "Explicit configuration for offline examples and tests."
  def offline(attributes \\ %{}) do
    Map.merge(
      %{
        model: "offline",
        client: AgentExamples.AI.ScriptedClient,
        tool_options: [otp_app: :agent_examples]
      },
      attributes
    )
  end

  def ask(record, query, opts \\ []) do
    request_id = Ash.UUIDv7.generate()
    timeout = Keyword.get(opts, :timeout, 30_000)
    deadline_at = System.system_time(:millisecond) + timeout
    resource = Map.get(record, :resource) || record.__struct__
    ash_opts = caller_ash_options(opts)

    pid = lookup_agent_pid(resource, record.id)
    observe = &select_ai_result(&1, request_id)

    Aikido.AgentServer.call_until(
      pid,
      fn ->
        resource
        |> Ash.ActionInput.for_action(
          :ask,
          %{
            agent: record.id,
            query: query,
            request_id: request_id,
            metadata: Map.put(Keyword.get(opts, :metadata, %{}), :aikido_deadline_at, deadline_at)
          },
          ash_opts
        )
        |> Ash.run_action(ash_opts)
      end,
      "**",
      observe,
      traced_wait_options(ash_opts, timeout)
    )
  end

  @doc "Delegate a task in foreground or background mode, or background an existing task by ID."
  def delegate(team, member, text, opts \\ []) do
    if opts[:task_id] do
      background_existing_task(team, opts)
    else
      now = System.system_time(:millisecond)
      deadline = delegation_deadline(opts, now)

      if deadline <= now do
        {:error, :timeout}
      else
        dispatch_delegation(
          team,
          member,
          text,
          Ash.UUIDv7.generate(),
          deadline,
          deadline - now,
          opts
        )
      end
    end
  end

  defp delegation_deadline(opts, now) do
    case {opts[:deadline_at], opts[:timeout]} do
      {nil, nil} -> now + 240_000
      {deadline, nil} -> deadline
      {nil, timeout} -> now + timeout
      {deadline, timeout} -> min(deadline, now + timeout)
    end
  end

  defp background_existing_task(team, opts) do
    resource = Map.get(team, :resource) || team.__struct__
    ash_opts = caller_ash_options(opts)

    Aikido.AgentServer.call_until(
      lookup_agent_pid(resource, team.id),
      fn ->
        resource
        |> Ash.ActionInput.for_action(
          :background_task,
          %{agent: team.id, task_id: opts[:task_id]},
          ash_opts
        )
        |> Ash.run_action(ash_opts)
      end,
      "aikido.ash.team.**",
      &select_task_result(&1, opts[:task_id]),
      traced_wait_options(ash_opts, 5_000)
    )
  end

  defp dispatch_delegation(team, member, text, task_id, deadline, timeout, opts) do
    mode = Keyword.get(opts, :mode, :foreground)
    resource = Map.get(team, :resource) || team.__struct__
    ash_opts = caller_ash_options(opts)
    requester = Keyword.get(opts, :requester, :self)

    dispatch = fn ->
      resource
      |> Ash.ActionInput.for_action(
        :assign_task,
        %{
          agent: team.id,
          member: member,
          task_id: task_id,
          payload: %{text: text},
          timeout_ms: timeout,
          mode: mode,
          requester: requester,
          notify: if(mode == :background, do: requester),
          worker_lifecycle: Keyword.get(opts, :worker_lifecycle, :keep),
          metadata: %{aikido_deadline_at: deadline}
        },
        ash_opts
      )
      |> Ash.run_action(ash_opts)
    end

    if mode == :background do
      with {:ok, _receipt} <- dispatch.() do
        {:ok, %{task_id: task_id, member: member, mode: :background}}
      end
    else
      Aikido.AgentServer.call_until(
        lookup_agent_pid(resource, team.id),
        dispatch,
        "aikido.ash.team.**",
        &select_task_result(&1, task_id),
        traced_wait_options(ash_opts, timeout + 1_000)
      )
    end
  end

  defp caller_ash_options(opts) do
    ash_opts = Keyword.get(opts, :ash, [])

    ash_opts
    |> Keyword.get(:scope, %{})
    |> Ash.Scope.to_opts(Keyword.delete(ash_opts, :scope))
  end

  defp traced_wait_options(ash_opts, timeout) do
    ash_opts
    |> Keyword.take([:tracer])
    |> Keyword.put(:timeout, timeout)
  end

  defp lookup_agent_pid(resource, id) do
    case Aikido.Durable.lookup(
           Aikido.durable_supervisor_name(Aikido.Agent.Info.agent_instance!(resource)),
           id
         ) do
      {:ok, pid} -> pid
      :error -> nil
    end
  end

  defp select_ai_result(runtime, request_id) do
    ai = runtime.agent.state.ai

    cond do
      ai.request_id != request_id -> :skip
      ai.status == :completed -> {:ok, ai.result}
      ai.status == :failed -> {:error, ai.error}
      true -> :skip
    end
  end

  defp select_task_result(runtime, task_id) do
    team = runtime.agent.state.team

    case team.tasks[task_id] || Map.get(team.pending_tasks, task_id) do
      %{status: :completed, result: result} -> {:ok, result}
      %{status: :failed, result: reason} -> {:error, reason}
      %{mode: :background} -> {:ok, %{task_id: task_id, mode: :background}}
      _ -> :skip
    end
  end
end
