defmodule Aikido.Slices.AiReact do
  @moduledoc """
  ReAct strategy as a configured `Aikido.Slice`.

  Attached to any `Aikido.Agent` via the agent's `extensions:` list and
  configured through the contributed `react do … end` section:

      defmodule MyApp.SupportAgent do
        use Aikido.Agent, extensions: [Aikido.Slices.AiReact]

        agent do
          name "support"
        end

        react do
          model "anthropic:claude-haiku-4-5-20251001"
          tools [:lookup_order, :refund_order]
          tool_options [otp_app: :my_app]
          system_prompt "You are a support agent."
          max_iterations 5
        end

        slices do
          slice :ai, Aikido.Slices.AiReact
        end
      end

  The slice owns the `:ai` key of the agent's state and contains the full
  lifecycle of one ReAct conversation.

  ## State machine

      :idle ──ask──▶ :setup ──tools ready──▶ :running
                       │                       ├─tool calls──▶ :running (next turn)
                       │                       ├─final answer / limit──▶ :completed
                       │                       ├─unfinished blocking todos──▶ :waiting
                       └─error / cancel──▶ :failed ◀──error / cancel──┘

  Concurrent `ai.react.ask` while `:setup` or `:running` is rejected with
  `{:error, :busy}`.

  ## Slice fields

    * `:status` — `:idle | :setup | :running | :waiting | :completed | :failed`.
    * `:request_id` — opaque correlation id minted by `Aikido.AI.ask/3`.
      Every response signal carries it; mismatched signals are dropped as
      stale.
    * `:context` — the full `ReqLLM.Context`: system, user, assistant and
      tool messages.
    * `:iteration` — number of LLM calls completed so far.
    * `:max_iterations` — cap on LLM calls; further `:tool_calls` turns
      after this is reached truncate the run as `:completed`.
    * `:result` — final answer text on `:completed`, or `nil`.
    * `:error` — error term on `:failed`, or `nil`.
    * `:pending_tool_calls` — tool calls from the last `:tool_calls` turn,
      kept until every paired tool result has come back.
    * `:tool_results_received` — tool results accumulated for the in-flight
      tool batch; cleared when the batch completes and the next LLMCall
      fires.
    * `:previous_tool_signature` — signature of the last batch's tool
      calls; used to detect tool-call cycles and prepend a cycle-warning
      user message before the next LLMCall.
    * `:model`, `:tools`, `:system_prompt`, `:llm_opts` — run config
      seeded from the slice's `slices:` config (validated through
      `config_schema/0`); `Aikido.Slices.AiReact.Ask` falls back to these
      values when the opening signal omits them.

  ## Config keys (`config_schema/0`)

    * `:model` — any value accepted by `ReqLLM.Generation.generate_text/3`.
      Optional; the floor enforced by the `Ask` action is `{:error, :no_model}`
      when neither the slice config nor the per-call `Aikido.AI.ask/3` opts
      supply a model.
    * `:tools` — Ash AI tool names. `tool_options` supplies native Ash AI source/filter configuration.
    * `:system_prompt` — system message text prepended to the conversation.
    * `:max_iterations` — cap on LLM calls per run (default 10).
    * `:max_tokens` — folded into `:llm_opts` (default 4096).
    * `:temperature` — folded into `:llm_opts` (default 0.2).
    * `:llm_opts` — extra keyword list merged into per-call options
      (last-write-wins over `:max_tokens` / `:temperature`).
  """
  @cycle_warning "You already called the same tool(s) with identical parameters in the previous iteration and got the same results. Do NOT repeat the same calls. Either use the results you already have to form a final answer, or try a different approach."
  use Ash.Resource,
    data_layer: :embedded,
    validate_domain_inclusion?: false,
    extensions: [Aikido.Ash.Slice]

  slice do
    name "ai"
    description "ReAct reasoning slice attached via `slices:` on a Aikido.Agent."

    schema do
      attribute :handoff_pending, :integer
      attribute :handoff_count, :integer, public?: true, default: 0, allow_nil?: false
      attribute :last_handoff, :map, public?: true

      attribute :estimated_tokens, :integer,
        public?: true,
        default: 0,
        allow_nil?: false,
        constraints: [min: 0]

      attribute :last_input_tokens, :integer
      attribute :prepared_tools, :term
      attribute :tool_preparation, {:array, :term}, default: [], allow_nil?: false
      attribute :run_scope, :map, default: %{}
      attribute :run_metadata, :map, public?: true, default: %{}
      attribute :options, Aikido.AI.Options, public?: true, default: %{}, allow_nil?: false
      attribute :queued_messages, {:array, :string}, public?: true, default: [], allow_nil?: false

      attribute :streaming_text, :string,
        public?: true,
        default: "",
        constraints: [allow_empty?: true, trim?: false]

      attribute :streaming_thinking, :string,
        public?: true,
        default: "",
        constraints: [allow_empty?: true, trim?: false]

      attribute :stream_attempt, :integer, default: 0
      attribute :usage, :map, public?: true, default: %{}
      attribute :status, :atom, public?: true, allow_nil?: false, default: :idle
      attribute :request_id, :term, public?: true, allow_nil?: true, default: nil
      attribute :context, :term, public?: true, allow_nil?: true, default: nil
      attribute :iteration, :integer, public?: true, allow_nil?: false, default: 0
      attribute :max_iterations, :integer, public?: true, allow_nil?: false, default: 10
      attribute :result, :term, public?: true, allow_nil?: true, default: nil
      attribute :error, :term, public?: true, allow_nil?: true, default: nil

      attribute :pending_tool_calls, {:array, :term},
        public?: true,
        allow_nil?: false,
        default: []

      attribute :tool_results_received, {:array, :term},
        public?: true,
        allow_nil?: false,
        default: []

      attribute :previous_tool_signature, :term, public?: true, allow_nil?: true, default: nil
      attribute :model, :term, public?: true, allow_nil?: true, default: nil
      attribute :client, :atom, public?: true, allow_nil?: false, default: ReqLLM.Generation
      attribute :tools, {:array, :atom}, public?: true, allow_nil?: false, default: []

      attribute :tool_options, Aikido.Types.Native,
        public?: true,
        default: [otp_app: :aikido],
        constraints: [kind: :keyword_list]

      attribute :tool_context, :map, public?: true, allow_nil?: false, default: %{}
      attribute :system_prompt, :term, public?: true, allow_nil?: true, default: nil
      attribute :llm_opts, :term, public?: true, allow_nil?: false, default: []
      attribute :hooks, {:array, Aikido.Hooks.Hook}, public?: true, allow_nil?: false, default: []
      attribute :hooks_pending, :map, public?: true, allow_nil?: false, default: %{}
      attribute :hook_sequence, :integer, public?: true, allow_nil?: false, default: 0
      attribute :hook_context, {:array, :map}, public?: true, allow_nil?: false, default: []
      attribute :hook_errors, {:array, :map}, public?: true, allow_nil?: false, default: []
      attribute :hook_terminal, :atom, public?: true
    end

    config_schema do
      attribute :options, Aikido.AI.Options, public?: true, default: %{}, allow_nil?: false
      attribute :hooks, {:array, Aikido.Hooks.Hook}, public?: true, allow_nil?: false, default: []
      attribute :model, :term, public?: true, allow_nil?: true
      attribute :client, :atom, public?: true, allow_nil?: false, default: ReqLLM.Generation
      attribute :tools, {:array, :atom}, public?: true, allow_nil?: false, default: []

      attribute :tool_options, Aikido.Types.Native,
        public?: true,
        default: [otp_app: :aikido],
        constraints: [kind: :keyword_list]

      attribute :tool_context, :map, public?: true, allow_nil?: false, default: %{}
      attribute :system_prompt, :term, public?: true, allow_nil?: true
      attribute :max_iterations, :integer, public?: true, allow_nil?: false, default: 10
      attribute :max_tokens, :integer, public?: true, allow_nil?: false, default: 4096
      attribute :temperature, :term, public?: true, allow_nil?: false, default: 0.2
      attribute :llm_opts, :term, public?: true, allow_nil?: false, default: []
    end

    config_transform {__MODULE__, :__fold_llm_opts__, []}
    route "ai.react.context_handoff.completed", :handoff_completed
    route "ai.react.context_handoff.failed", :handoff_failed
    route "ai.react.tools.ready", :tools_ready
    route "ai.react.ask", :ask
    route "ai.react.message", :message
    route "ai.react.deliver", :deliver
    route "ai.react.handoff", :handoff
    route "aikido.todo.changed", :todo_changed
    route "ai.react.stream", :stream
    route "ai.react.llm.completed", :llm_turn
    route "ai.react.tool.completed", :tool_result
    route "ai.react.failed", :failed
    route "ai.react.cancel", :cancel
    route "ai.react.hook.completed", :hook_completed
    route "ai.react.hook.context", :hook_context
  end

  @react_section %Spark.Dsl.Section{
    name: :react,
    describe: "ReAct reasoning slice attached via `slices:` on a Aikido.Agent.",
    schema: [
      options: [type: :map, default: %{}],
      model: [type: :any, doc: "Model spec accepted by `ReqLLM.Generation.generate_text/3`."],
      client: [
        type: :module,
        default: ReqLLM.Generation,
        doc: "Module implementing the model-call boundary."
      ],
      tool_options: [type: :keyword_list, default: [otp_app: :aikido]],
      tool_context: [type: :map, default: %{}],
      hooks: [type: {:list, :map}, default: []],
      tools: [
        type: {:list, :atom},
        default: [],
        doc: "Ash AI tool names, resolved using tool_options."
      ],
      system_prompt: [type: :any, doc: "System message text prepended to the conversation."],
      max_iterations: [type: :integer, default: 10, doc: "Cap on LLM calls per run."],
      max_tokens: [
        type: :integer,
        default: 4096,
        doc: "Default max tokens, folded into `:llm_opts`."
      ],
      temperature: [
        type: :any,
        default: 0.2,
        doc: "Default temperature, folded into `:llm_opts`."
      ],
      llm_opts: [
        type: :any,
        default: [],
        doc:
          "Extra keyword list merged into per-call options " <>
            "(last-write-wins over `:max_tokens` / `:temperature`)."
      ]
    ]
  }
  use Spark.Dsl.Extension,
    sections: [@react_section],
    transformers: [Aikido.Slices.AiReact.Transformers.RegisterContribution]

  @doc false
  @spec __fold_llm_opts__(map(), term()) :: {:ok, map()}
  def __fold_llm_opts__(config, _ctx) when is_map(config) do
    {max_tokens, config} = Map.pop(config, :max_tokens)
    {temperature, config} = Map.pop(config, :temperature)
    base_opts = config[:llm_opts] || []

    llm_opts =
      base_opts
      |> put_unless_present(:max_tokens, max_tokens)
      |> put_unless_present(:temperature, temperature)

    {:ok, Map.put(config, :llm_opts, llm_opts)}
  end

  defp put_unless_present(opts, _key, nil) do
    opts
  end

  defp put_unless_present(opts, key, value) do
    if Keyword.has_key?(opts, key) do
      opts
    else
      Keyword.put(opts, key, value)
    end
  end

  @doc """
  The cycle-warning user message appended to the context when the next
  LLMCall would otherwise repeat the previous tool-call batch verbatim.
  """
  @spec cycle_warning() :: String.t()
  def cycle_warning do
    @cycle_warning
  end

  @doc """
  Tool-call signature for cycle detection.

  Stable, sortable, and tolerant of mixed atom/string keys (different
  ReqLLM provider adapters return one or the other).
  """
  @spec tool_call_signature([map()]) :: String.t()
  def tool_call_signature(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(fn tc ->
      name = Map.get(tc, :name) || Map.get(tc, "name") || ""
      args = Map.get(tc, :arguments) || Map.get(tc, "arguments") || ""
      "#{name}:#{inspect(args)}"
    end)
    |> Enum.sort()
    |> Enum.join("|")
  end

  @behaviour Aikido.Persist.Transform

  actions do
    action :handoff_completed, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :request_id, :string, allow_nil?: false
      argument :handoff_id, :integer, allow_nil?: false
      argument :turn, :term, allow_nil?: false
      argument :iteration, :integer
      run {Aikido.Slices.AiReact.Implementation, action: :handoff_completed}
    end

    action :handoff_failed, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :request_id, :string, allow_nil?: false
      argument :handoff_id, :integer, allow_nil?: false
      argument :reason, :term, allow_nil?: false
      run {Aikido.Slices.AiReact.Implementation, action: :handoff_failed}
    end

    action :tools_ready, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :request_id, :string, allow_nil?: false
      argument :prepared_tools, :term, allow_nil?: false
      run {Aikido.Slices.AiReact.Implementation, action: :tools_ready}
    end

    action :ask, Aikido.ActionResult do
      argument :state, :term
      argument :options, Aikido.AI.Options
      argument :tool_options, Aikido.Types.Native, constraints: [kind: :keyword_list]
      argument :tool_context, :map
      argument :metadata, :map, default: %{}
      argument :query, :string, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      argument :model, :term
      argument :client, :atom
      argument :tools, {:array, :atom}
      argument :system_prompt, :string
      argument :max_iterations, :integer, constraints: [min: 1]
      argument :llm_opts, Aikido.Types.Native, constraints: [kind: :keyword_list]
      argument :hooks, {:array, Aikido.Hooks.Hook}
      description "Open a ReAct run on a Aikido.Slices.AiReact-equipped agent."
      run {Aikido.Slices.AiReact.Implementation, action: :ask}
    end

    action :message, Aikido.ActionResult do
      argument :state, :term
      argument :text, :string, allow_nil?: false
      run {Aikido.Slices.AiReact.Implementation, action: :message}
    end

    action :handoff, Aikido.ActionResult do
      argument :state, :term
      argument :messages, {:array, :term}, allow_nil?: false
      run {Aikido.Slices.AiReact.Implementation, action: :handoff}
    end

    action :deliver, Aikido.ActionResult do
      argument :state, :term
      argument :metadata, :map, default: %{}
      argument :text, :string, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      run {Aikido.Slices.AiReact.Implementation, action: :deliver}
    end

    action :todo_changed, Aikido.ActionResult do
      public? false
      argument :state, :term
      run {Aikido.Slices.AiReact.Implementation, action: :todo_changed}
    end

    action :stream, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :request_id, :string, allow_nil?: false
      argument :iteration, :integer, allow_nil?: false
      argument :attempt, :integer, default: 0
      argument :text, :string, default: "", constraints: [allow_empty?: true, trim?: false]
      argument :thinking, :string, default: "", constraints: [allow_empty?: true, trim?: false]
      run {Aikido.Slices.AiReact.Implementation, action: :stream}
    end

    action :cancel, Aikido.ActionResult do
      argument :state, :term
      argument :request_id, :string, default: nil
      run {Aikido.Slices.AiReact.Implementation, action: :cancel}
    end

    action :failed, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :reason, :term, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Settle the slice as :failed with the reason."
      run {Aikido.Slices.AiReact.Implementation, action: :failed}
    end

    action :llm_turn, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :iteration, :integer
      argument :turn, :term, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Process a completed LLM turn and decide the next ReAct step."
      run {Aikido.Slices.AiReact.Implementation, action: :llm_turn}
    end

    action :tool_result, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :tool_call_id, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :content, :string, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Process one tool result and fan-in to the next LLM turn."
      run {Aikido.Slices.AiReact.Implementation, action: :tool_result}
    end

    action :hook_completed, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :request_id, :string, allow_nil?: false
      argument :token, :integer, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :mode, :atom, allow_nil?: false, constraints: [one_of: [:sync, :async]]
      argument :result, :term
      argument :reason, :term
      run {Aikido.Slices.AiReact.Implementation, action: :hook_completed}
    end

    action :hook_context, Aikido.ActionResult do
      public? false
      argument :state, :term
      argument :request_id, :string, allow_nil?: false
      argument :text, :string, allow_nil?: false
      argument :name, :string
      run {Aikido.Slices.AiReact.Implementation, action: :hook_context}
    end
  end

  @doc false
  @impl true
  def externalize(state),
    do:
      Map.merge(state, %{
        handoff_pending: nil,
        prepared_tools: nil,
        tool_preparation: [],
        hooks_pending: %{},
        hook_terminal: nil,
        run_scope: %{},
        streaming_text: "",
        streaming_thinking: ""
      })

  @doc false
  @impl true
  def reinstate(state) do
    state =
      if state.status in [:setup, :running, :waiting],
        do: Map.merge(state, %{status: :failed, error: :interrupted}),
        else: state

    context = if(state.context, do: Aikido.AI.Context.close_tool_calls(state.context))
    state = Aikido.AI.Context.replace_context(state, context)

    Map.merge(state, %{
      handoff_pending: nil,
      prepared_tools: nil,
      tool_preparation: [],
      hooks_pending: %{},
      hook_terminal: nil,
      run_scope: %{},
      pending_tool_calls: [],
      tool_results_received: [],
      streaming_text: "",
      streaming_thinking: ""
    })
  end
end
