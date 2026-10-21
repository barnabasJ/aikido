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
    resource = Map.get(record, :resource) || record.__struct__
    ash_opts = Keyword.get(opts, :ash, [])

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
            metadata: Keyword.get(opts, :metadata, %{})
          },
          ash_opts
        )
        |> Ash.run_action(ash_opts)
      end,
      "**",
      observe,
      timeout: timeout
    )
  end

  @doc "Assign work from an external caller or a tool task, then await its correlated result."
  def delegate(team, member, text, opts \\ []) do
    task_id = Ash.UUIDv7.generate()
    timeout = Keyword.get(opts, :timeout, 20_000)
    resource = Map.get(team, :resource) || team.__struct__
    ash_opts = Keyword.get(opts, :ash, [])

    pid = lookup_agent_pid(resource, team.id)
    observe = &select_task_result(&1, task_id)

    Aikido.AgentServer.call_until(
      pid,
      fn ->
        resource
        |> Ash.ActionInput.for_action(
          :assign_task,
          %{
            agent: team.id,
            member: member,
            task_id: task_id,
            payload: %{text: text},
            timeout_ms: timeout
          },
          ash_opts
        )
        |> Ash.run_action(ash_opts)
      end,
      "aikido.ash.team.**",
      observe,
      timeout: timeout + 1_000
    )
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
    case runtime.agent.state.team.tasks[task_id] do
      %{status: :completed, result: result} -> {:ok, result}
      %{status: :failed, result: reason} -> {:error, reason}
      _ -> :skip
    end
  end
end
