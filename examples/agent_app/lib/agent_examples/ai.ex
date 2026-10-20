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
    pid = Aikido.whereis(Aikido.Ash.Runtime.option(resource, :instance), record.id)

    observe = fn state ->
      ai = state.agent.state.ai

      cond do
        ai.request_id != request_id -> :skip
        ai.status == :completed -> {:ok, ai.result}
        ai.status == :failed -> {:error, ai.error}
        true -> :skip
      end
    end

    Aikido.AgentServer.call_until(
      pid,
      fn ->
        Aikido.Ash.command(
          record,
          %{query: query, request_id: request_id},
          Keyword.put(Keyword.get(opts, :ash, []), :action, :ask)
        )
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
    pid = Aikido.whereis(Aikido.Default, team.id)

    observe = fn state ->
      case state.agent.state.team.tasks[task_id] do
        %{status: :completed, result: result} -> {:ok, result}
        %{status: :failed, result: reason} -> {:error, reason}
        _ -> :skip
      end
    end

    Aikido.AgentServer.call_until(
      pid,
      fn ->
        Aikido.Ash.command(
          team,
          %{
            member: member,
            task_id: task_id,
            payload: %{text: text},
            timeout_ms: timeout
          },
          Keyword.put(Keyword.get(opts, :ash, []), :action, :assign_task)
        )
      end,
      "aikido.ash.team.**",
      observe,
      timeout: timeout + 1_000
    )
  end
end
