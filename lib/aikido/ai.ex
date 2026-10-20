defmodule Aikido.AI do
  @moduledoc """
  Public API for ReAct agents built on `Aikido.Slices.AiReact`.

  Works against any `pid` whose agent uses `Aikido.Ash.AI` or explicitly
  mounts `Aikido.Slices.AiReact` at `:ai`. The slice owns run configuration
  (model, tools, system_prompt, max_iterations, llm_opts), seeded from the
  AI configuration or slice mount options; per-call opts override.

  ## API shape

  - `ask/3` — fire-and-forget launch. Synchronously sends the
    `"ai.react.ask"` signal via `Aikido.AgentServer.call/4`; returns
    `{:ok, request_id}` once the run is launched, or `{:error, reason}`
    if the action rejected (e.g. `:busy`, `:no_model`). Does *not*
    subscribe to anything — observers are out-of-band.
  - `ask_sync/3` — convenience that subscribes for the terminal
    `:completed` / `:failed` transition before launching the run,
    blocks on the subscription, and returns the final text.

  Anything richer than "the final answer" — streaming tokens, tool-call
  notifications, reasoning steps, intermediate slice transitions — is
  the caller's job. Set up the subscription you want via
  `Aikido.AgentServer.subscribe/4` before calling `ask/3`, then receive
  the events as they arrive.

  ## Example

      defmodule MyApp.SupportAgent do
        use Ash.Resource, domain: MyApp.Agents, extensions: [Aikido.Ash.Agent, Aikido.Ash.AI]

        agent do
          name "support"
        end
      end

      defmodule MyApp.Agents do
        use Ash.Domain, extensions: [Aikido.Ash.Domain]

        agents do
          agent :support, MyApp.SupportAgent
        end
      end

      {:ok, reference} = MyApp.Agents.support_start(%{
        model: "anthropic:claude-haiku-4-5-20251001",
        tools: [:lookup_order, :refund_order],
        tool_options: [otp_app: :my_app],
        system_prompt: "You are a support agent."
      })
      pid = reference.pid
      {:ok, text} = Aikido.AI.ask_sync(pid, "Refund order 42, the customer asked.")

  Per-call overrides:

      {:ok, text} =
        Aikido.AI.ask_sync(pid, "Use a different model for this one",
          model: "openai:gpt-5",
          tools: [:one_off]
        )

  Custom observation:

      {:ok, ref} =
        Aikido.AgentServer.subscribe(pid, "ai.react.**", fn state ->
          {:ok, state.agent.state.ai}
        end)

      {:ok, request_id} = Aikido.AI.ask(pid, "What's the status?")
      # receive {:aikido_subscription, ^ref, ...} for every step

  ## Coordination guarantees

    * `ask_sync/3` waits for a subscription notification. It subscribes before launching to avoid missing completion.
    * Only one run may be active per agent; concurrent `ask/3`
      while `:setup` or `:running` returns the action's `{:error, :busy}` chain
      error verbatim through `Aikido.AgentServer.call/4`.
  """

  @default_await_timeout 30_000

  @type opts :: [
          model: ReqLLM.model_input() | nil,
          tools: [atom()] | nil,
          tool_options: keyword(),
          client: module(),
          system_prompt: String.t() | nil,
          max_iterations: pos_integer() | nil,
          llm_opts: keyword(),
          hooks: [map()],
          timeout: timeout()
        ]

  @doc """
  Launch a ReAct run on `pid`. Pure fire-and-forget — does not
  subscribe. Returns `{:ok, request_id}` once the run is in flight.

  Action-level rejections (`:busy`, `:no_model`) come back through
  `call/4`'s chain-error path wrapped in the framework's standard
  error pipeline.
  """
  @spec ask(GenServer.server(), String.t(), opts()) ::
          {:ok, String.t()} | {:error, term()}
  def ask(pid, query, opts \\ []) when is_binary(query) and is_list(opts) do
    request_id = mint_request_id()
    signal = build_ask_signal(query, request_id, opts) |> Aikido.SignalCtx.capture_tracing()
    launch(pid, signal, request_id)
  end

  @doc """
  Launch a ReAct run and block on the terminal transition.

  Subscribes to the slice's terminal `:completed` / `:failed` for the
  minted `request_id` *before* launching via
  `call/4`, then `receive`s the subscription fire. Returns
  `{:ok, text}` on completion, `{:error, reason}` on LLM failure or
  action rejection, `{:error, :timeout}` if no terminal signal arrives
  within the timeout.

  This is the convenience path for "give me the answer." For anything
  richer — streaming, tool-call notifications, intermediate state —
  subscribe yourself and call `ask/3`.
  """
  @spec ask_sync(GenServer.server(), String.t(), opts()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def ask_sync(pid, query, opts \\ []) when is_binary(query) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_await_timeout)
    request_id = mint_request_id()
    signal = build_ask_signal(query, request_id, opts) |> Aikido.SignalCtx.capture_tracing()

    selector = fn runtime ->
      ai = runtime.agent.state.ai

      cond do
        ai.request_id != request_id -> :skip
        ai.status == :completed -> {:ok, ai.result}
        ai.status == :failed -> {:error, ai.error}
        true -> :skip
      end
    end

    Aikido.AgentServer.call_until(pid, fn -> launch(pid, signal, request_id) end, "**", selector,
      timeout: timeout,
      tracer: Aikido.SignalCtx.tracers(signal)
    )
  end

  @doc "Cancel the active run; its model and tool tasks observe the terminal transition."
  def cancel(pid, request_id \\ nil) do
    Aikido.AgentServer.cast(pid, Jido.Signal.new!("ai.react.cancel", %{request_id: request_id}))
  end

  @doc "Queue a user message for the next model request, or the next run when idle."
  def queue_message(pid, text, opts \\ []) do
    signal = Jido.Signal.new!("ai.react.message", %{text: text})
    signal = Aikido.SignalCtx.put_ctx(signal, caller_scope(opts))

    Aikido.AgentServer.call(pid, signal, fn _ ->
      {:ok, :queued}
    end)
  end

  defp mint_request_id, do: "req_" <> Ash.UUIDv7.generate()

  defp build_ask_signal(query, request_id, opts) do
    data = %{
      metadata: Keyword.get(opts, :metadata, %{}),
      options: Keyword.get(opts, :options),
      tool_context: Keyword.get(opts, :tool_context),
      tool_options: Keyword.get(opts, :tool_options),
      query: query,
      request_id: request_id,
      model: Keyword.get(opts, :model),
      client: Keyword.get(opts, :client),
      tools: Keyword.get(opts, :tools),
      system_prompt: Keyword.get(opts, :system_prompt),
      max_iterations: Keyword.get(opts, :max_iterations),
      llm_opts: Keyword.get(opts, :llm_opts),
      hooks: Keyword.get(opts, :hooks)
    }

    Jido.Signal.new!("ai.react.ask", data)
    |> Aikido.SignalCtx.put_ctx(caller_scope(opts))
  end

  defp caller_scope(opts) do
    if Keyword.has_key?(opts, :scope),
      do:
        opts
        |> Keyword.fetch!(:scope)
        |> Ash.Scope.to_opts()
        |> Map.new()
        |> Map.drop([:authorize?]),
      else: Map.new(Keyword.take(opts, [:actor, :tenant]))
  end

  defp launch(pid, signal, request_id) do
    case Aikido.AgentServer.call(pid, signal, fn _state -> {:ok, request_id} end) do
      {:ok, ^request_id} = ok -> ok
      {:error, _} = err -> err
    end
  end
end
