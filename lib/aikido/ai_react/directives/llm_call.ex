defmodule Aikido.AiReact.Directives.LLMCall do
  @moduledoc """
  Side-effect directive: makes one call to `ReqLLM.Generation.generate_text/3`.

  Emitted by `:tools_ready` after setup, and by model/tool result actions when
  another turn is needed. Each descriptor already contains its prepared tools.
  The executor spawns a Task under the agent's task supervisor — the Task
  is the *only* place a blocking ReqLLM call lives, so the agent process
  stays free to handle other signals.

  Outcomes are reported back as signals to the originating agent:

    * `"ai.react.llm.completed"` with `%{turn: %ReqLLM.Response{}, request_id: id}`
      on success.
    * `"ai.react.failed"` with `%{reason: term, request_id: id}` on
      transport / API error.

  The directive struct carries everything the executor needs so it can
  run without re-reading slice state.
  """

  use Aikido.Directive
  require Ash.Tracer

  typed_struct do
    field :mode, Aikido.AiReact.Types.RequestMode do
      description "Whether this request performs a normal turn, a handoff summary or a resumed turn."
      default :normal
      allow_nil? false
    end

    field :handoff_id, :integer do
      description "Identifier correlating a summary response with the pending context handoff."
    end

    field :deadline_at, :integer do
      description "Absolute Unix-millisecond deadline; this effect cannot extend the owning run's remaining budget."
      constraints min: 1
    end

    field :options, Aikido.AiReact.Options do
      description "Execution policy controlling model-call attempts, deadlines and streaming."
      default %Aikido.AiReact.Options{}
      allow_nil? false
    end

    field :iteration, :integer do
      description "Model turn number attached to the resulting response and stream signals."
      default 1
    end

    field :model, :term do
      description "Model identifier or configuration passed to the generation callback."
      allow_nil? false
    end

    field :client, :module do
      description "Module providing the generation callback for this model request."
      allow_nil? false
      default ReqLLM.Generation
    end

    field :context, :term do
      description "Native ReqLLM conversation passed to the generation callback."
      allow_nil? false
    end

    field :tools, {:array, :term} do
      description "Prepared tool descriptions supplied with the model request."
      allow_nil? false
      default []
    end

    field :request_id, :string do
      description "Run identifier used to correlate the model response with the owning slice."
      allow_nil? false
    end

    field :llm_opts, {:array, :tuple} do
      description "Provider generation options applied to this model request."
      constraints items: [fields: [key: [type: :atom], value: [type: :term]]]
      default []
    end
  end

  alias Aikido.AgentServer
  alias Aikido.Signal
  alias Aikido.AiReact.Directives.LLMCall
  alias ReqLLM.Context

  @impl true
  def exec(%LLMCall{} = directive, input_signal, state) do
    agent_pid = self()
    task_sup = Aikido.task_supervisor_name(state.aikido)
    source = "/agent/#{state.id}"

    tracers = Aikido.Signal.tracers(input_signal, state.aikido)
    transfer = Ash.ProcessHelpers.get_context_for_transfer(tracer: tracers)

    case Task.Supervisor.start_child(task_sup, fn ->
           Ash.ProcessHelpers.transfer_context(transfer)

           Ash.Tracer.span {:custom, :aikido_model_call}, "aikido_model_call", tracers do
             generate_response_and_send_to_agent(
               directive,
               agent_pid,
               source,
               Aikido.Signal.ctx(input_signal),
               task_sup
             )
           end
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        send_model_result_to_agent(
          {:error, reason},
          directive,
          agent_pid,
          source,
          Aikido.Signal.ctx(input_signal)
        )
    end

    :ok
  end

  defp generate_response_and_send_to_agent(%LLMCall{} = d, agent_pid, source, scope, supervisor) do
    d
    |> generate_response(agent_pid, source, scope, supervisor)
    |> send_model_result_to_agent(d, agent_pid, source, scope)
  rescue
    exception -> send_model_result_to_agent({:error, exception}, d, agent_pid, source, scope)
  end

  defp generate_response(d, agent_pid, source, scope, supervisor) do
    messages = Context.to_list(d.context)
    llm_opts = model_options(d)

    Aikido.AiReact.CancellableTask.run_cancellable_attempts(
      agent_pid,
      d.request_id,
      supervisor,
      fn notify, attempt ->
        emit = fn text, thinking ->
          dispatch_stream_delta(d, text, thinking, attempt, agent_pid, source, scope)
        end

        request_model_response(d, messages, llm_opts, notify, emit)
      end,
      execution_options(d, scope)
    )
  end

  defp model_options(d) do
    options = Keyword.put(d.llm_opts, :tools, d.tools)
    if d.mode == :handoff, do: Keyword.delete(options, :tool_choice), else: options
  end

  defp execution_options(d, scope) do
    [
      tracer: scope[:tracer],
      timeout: d.options.model_timeout_ms,
      deadline_at: d.deadline_at,
      progress_timeout:
        if(streaming?(d), do: d.options.progress_timeout_ms, else: d.options.model_timeout_ms),
      retries: d.options.model_max_retries,
      backoff: d.options.retry_backoff_ms
    ]
  end

  defp streaming?(d), do: d.options.streaming && d.mode != :handoff

  defp request_model_response(d, messages, options, notify, emit) do
    if streaming?(d) do
      Aikido.AiReact.ModelStream.call(
        d.client,
        d.model,
        messages,
        options,
        emit,
        notify,
        d.options.stream_batch_bytes,
        d.options.stream_batch_ms
      )
    else
      d.client.generate_text(d.model, messages, options)
    end
  end

  defp dispatch_stream_delta(d, text, thinking, attempt, pid, source, scope) do
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
      |> Aikido.Signal.put_ctx(scope)

    AgentServer.cast(pid, signal)
  end

  defp send_model_result_to_agent(result, d, pid, source, scope) do
    signal = result |> model_result_signal(d, source) |> Aikido.Signal.put_ctx(scope)
    AgentServer.cast(pid, signal)
  end

  defp model_result_signal({:ok, response}, d, source) do
    type =
      if d.mode == :handoff,
        do: "ai.react.context_handoff.completed",
        else: "ai.react.llm.completed"

    data =
      %{turn: response, request_id: d.request_id, iteration: d.iteration}
      |> include_handoff_id(d)

    Signal.new!(type, data, source: source)
  end

  defp model_result_signal({:error, reason}, d, source) do
    reason = Aikido.AiReact.Errors.ProviderRequestFailed.from_reason(reason)
    data = %{reason: reason, request_id: d.request_id} |> include_handoff_id(d)
    Signal.new!(model_failure_signal_type(d), data, source: source)
  end

  defp model_failure_signal_type(%{mode: :handoff}), do: "ai.react.context_handoff.failed"
  defp model_failure_signal_type(_), do: "ai.react.failed"

  defp include_handoff_id(data, %{mode: :handoff, handoff_id: id}),
    do: Map.put(data, :handoff_id, id)

  defp include_handoff_id(data, _), do: data
end
