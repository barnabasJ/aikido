defmodule Aikido.Slices.AiReact.Directives.LLMCall do
  @moduledoc """
  Side-effect directive: makes one call to `ReqLLM.Generation.generate_text/3`.

  Emitted by `Aikido.Slices.AiReact.Ask` (first turn) and `Aikido.Slices.AiReact.ToolResult`
  (subsequent turns, once all tool results in a batch have come back).
  The executor spawns a Task under the agent's task supervisor — the Task
  is the *only* place a blocking ReqLLM call lives, so the agent process
  stays free to handle other signals.

  Outcomes are reported back as signals to the originating agent:

    * `"ai.react.llm.completed"` with `%{turn: %Aikido.Slices.AiReact.Turn{}, request_id: id}`
      on success.
    * `"ai.react.failed"` with `%{reason: term, request_id: id}` on
      transport / API error.

  The directive struct carries everything the executor needs so it can
  run without re-reading slice state.
  """

  use Aikido.Directive

  typed_struct do
    field :mode, :atom,
      default: :normal,
      allow_nil?: false,
      constraints: [one_of: [:normal, :handoff, :resume]]

    field :handoff_id, :integer
    field :options, :term, default: %{}
    field :iteration, :integer, default: 1
    field :model, :term, allow_nil?: false
    field :client, :module, allow_nil?: false, default: ReqLLM.Generation
    field :context, :term, allow_nil?: false
    field :tools, {:array, :term}, allow_nil?: false, default: []

    field :request_id, :string, allow_nil?: false
    field :llm_opts, {:array, :tuple},
      constraints: [items: [fields: [key: [type: :atom], value: [type: :term]]]],
      default: []
  end

  alias Aikido.AgentServer
  alias Jido.Signal
  alias Aikido.Slices.AiReact.Directives.LLMCall
  alias Aikido.Slices.AiReact.Turn
  alias ReqLLM.Context

  @impl true
  def exec(%LLMCall{} = directive, input_signal, state) do
    agent_pid = self()
    task_sup = Aikido.task_supervisor_name(state.aikido)
    source = "/agent/#{state.id}"

    {:ok, _pid} =
      Task.Supervisor.start_child(task_sup, fn ->
        run_and_dispatch(
          directive,
          agent_pid,
          source,
          Aikido.SignalCtx.ctx(input_signal),
          task_sup
        )
      end)

    :ok
  end

  defp run_and_dispatch(%LLMCall{} = d, agent_pid, source, scope, supervisor) do
    options = Aikido.AI.Options.resolve(d.options)

    llm_opts = Keyword.put(d.llm_opts, :tools, d.tools)
    llm_opts = if d.mode == :handoff, do: Keyword.delete(llm_opts, :tool_choice), else: llm_opts
    messages = Context.to_list(d.context)

    result =
      Aikido.AI.Execution.run(
        agent_pid,
        d.request_id,
        supervisor,
        fn notify, attempt ->
          if options.streaming && d.mode != :handoff do
            Aikido.AI.Streaming.call(
              d.client,
              d.model,
              messages,
              llm_opts,
              fn text, thinking ->
                signal =
                  Signal.new!(
                    "ai.react.stream",
                    %{
                      request_id: d.request_id,
                      iteration: d.iteration,
                      attempt: attempt,
                      text: text,
                      thinking: thinking
                    },
                    source: source
                  )
                  |> Aikido.SignalCtx.put_ctx(scope)

                AgentServer.cast(agent_pid, signal)
              end,
              notify,
              options.stream_batch_bytes,
              options.stream_batch_ms
            )
          else
            d.client.generate_text(d.model, messages, llm_opts)
          end
        end,
        timeout: options.model_timeout_ms,
        progress_timeout:
          if(options.streaming && d.mode != :handoff,
            do: options.progress_timeout_ms,
            else: options.model_timeout_ms
          ),
        retries: options.model_max_retries,
        backoff: options.retry_backoff_ms
      )

    signal =
      case result do
        {:ok, response} ->
          data =
            handoff_data(
              %{
                turn: Turn.from_response(response),
                request_id: d.request_id,
                iteration: d.iteration
              },
              d
            )

          Signal.new!(
            if(d.mode == :handoff,
              do: "ai.react.context_handoff.completed",
              else: "ai.react.llm.completed"
            ),
            data,
            source: source
          )

        {:error, reason} ->
          Signal.new!(
            failure_type(d),
            handoff_data(%{reason: reason, request_id: d.request_id}, d),
            source: source
          )
      end

    AgentServer.cast(agent_pid, Aikido.SignalCtx.put_ctx(signal, scope))
  rescue
    exception ->
      AgentServer.cast(
        agent_pid,
        Signal.new!(
          failure_type(d),
          handoff_data(%{reason: exception, request_id: d.request_id}, d),
          source: source
        )
        |> Aikido.SignalCtx.put_ctx(scope)
      )
  end

  defp failure_type(%{mode: :handoff}), do: "ai.react.context_handoff.failed"
  defp failure_type(_), do: "ai.react.failed"
  defp handoff_data(data, %{mode: :handoff, handoff_id: id}), do: Map.put(data, :handoff_id, id)
  defp handoff_data(data, _), do: data
end
