defmodule Aikido.Slices.AiReact do
  @moduledoc """
  A native Ash slice that owns the ReAct conversation and its next execution step.

  Add `Aikido.Ash.AI` to an agent resource for model configuration and public
  AI actions. Alternatively mount this slice directly with `slice :ai,
  Aikido.Slices.AiReact, options: [...]` inside its `agent` block.

  Runs move from `:idle` to `:setup` while native Ash AI tools are prepared,
  then `:running` for model/tool turns. Terminal states are `:completed` and
  `:failed`; optional todo completion can hold a result in `:waiting`.
  Cancellation and queued messages are accepted during setup and execution.

  The conversation retains native ReqLLM messages, including provider metadata
  and signed reasoning. Model calls and tools run in directives; generic Ash
  actions apply their results. Callers supply Ash AI tool names and native
  `tool_options`; prepared callbacks are rebuilt for each run and never saved.
  """
  @cycle_warning "You already called the same tool(s) with identical parameters in the previous iteration and got the same results. Do NOT repeat the same calls. Either use the results you already have to form a final answer, or try a different approach."
  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Ash.Slice]

  @keyword_constraints [items: [fields: [key: [type: :atom], value: [type: :term]]]]

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

      attribute :tool_options, {:array, :tuple},
        public?: true,
        default: [otp_app: :aikido],
        constraints: @keyword_constraints

      attribute :tool_context, :map, public?: true, allow_nil?: false, default: %{}
      attribute :system_prompt, :term, public?: true, allow_nil?: true, default: nil

      attribute :llm_opts, {:array, :tuple},
        public?: true,
        allow_nil?: false,
        default: [max_tokens: 4096, temperature: 0.2],
        constraints: @keyword_constraints

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

      attribute :tool_options, {:array, :tuple},
        public?: true,
        default: [otp_app: :aikido],
        constraints: @keyword_constraints

      attribute :tool_context, :map, public?: true, allow_nil?: false, default: %{}
      attribute :system_prompt, :term, public?: true, allow_nil?: true
      attribute :max_iterations, :integer, public?: true, allow_nil?: false, default: 10

      attribute :llm_opts, {:array, :tuple},
        public?: true,
        allow_nil?: false,
        default: [max_tokens: 4096, temperature: 0.2],
        constraints: @keyword_constraints
    end

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

  @behaviour Aikido.Durable.Codec

  actions do
    action :handoff_completed, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :request_id, :string, allow_nil?: false
      argument :handoff_id, :integer, allow_nil?: false
      argument :turn, :term, allow_nil?: false
      argument :iteration, :integer
      run {Aikido.Slices.AiReact.Implementation, action: :handoff_completed}
    end

    action :handoff_failed, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :request_id, :string, allow_nil?: false
      argument :handoff_id, :integer, allow_nil?: false
      argument :reason, :term, allow_nil?: false
      run {Aikido.Slices.AiReact.Implementation, action: :handoff_failed}
    end

    action :tools_ready, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :request_id, :string, allow_nil?: false
      argument :prepared_tools, :term, allow_nil?: false
      run {Aikido.Slices.AiReact.Implementation, action: :tools_ready}
    end

    action :ask, Aikido.Types.ActionResult do
      argument :state, :term
      argument :options, Aikido.AI.Options
      argument :tool_options, {:array, :tuple}, constraints: @keyword_constraints
      argument :tool_context, :map
      argument :metadata, :map, default: %{}
      argument :query, :string, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      argument :model, :term
      argument :client, :atom
      argument :tools, {:array, :atom}
      argument :system_prompt, :string
      argument :max_iterations, :integer, constraints: [min: 1]
      argument :llm_opts, {:array, :tuple}, constraints: @keyword_constraints
      argument :hooks, {:array, Aikido.Hooks.Hook}
      description "Open a ReAct run on a Aikido.Slices.AiReact-equipped agent."
      run {Aikido.Slices.AiReact.Implementation, action: :ask}
    end

    action :message, Aikido.Types.ActionResult do
      argument :state, :term
      argument :text, :string, allow_nil?: false
      run {Aikido.Slices.AiReact.Implementation, action: :message}
    end

    action :handoff, Aikido.Types.ActionResult do
      argument :state, :term
      argument :messages, {:array, :term}, allow_nil?: false
      run {Aikido.Slices.AiReact.Implementation, action: :handoff}
    end

    action :deliver, Aikido.Types.ActionResult do
      argument :state, :term
      argument :metadata, :map, default: %{}
      argument :text, :string, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      run {Aikido.Slices.AiReact.Implementation, action: :deliver}
    end

    action :todo_changed, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      run {Aikido.Slices.AiReact.Implementation, action: :todo_changed}
    end

    action :stream, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :request_id, :string, allow_nil?: false
      argument :iteration, :integer, allow_nil?: false
      argument :attempt, :integer, default: 0
      argument :text, :string, default: "", constraints: [allow_empty?: true, trim?: false]
      argument :thinking, :string, default: "", constraints: [allow_empty?: true, trim?: false]
      run {Aikido.Slices.AiReact.Implementation, action: :stream}
    end

    action :cancel, Aikido.Types.ActionResult do
      argument :state, :term
      argument :request_id, :string, default: nil
      run {Aikido.Slices.AiReact.Implementation, action: :cancel}
    end

    action :failed, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :reason, :term, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Settle the slice as :failed with the reason."
      run {Aikido.Slices.AiReact.Implementation, action: :failed}
    end

    action :llm_turn, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :iteration, :integer
      argument :turn, :term, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Process a completed LLM turn and decide the next ReAct step."
      run {Aikido.Slices.AiReact.Implementation, action: :llm_turn}
    end

    action :tool_result, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      argument :tool_call_id, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :content, :string, allow_nil?: false
      argument :request_id, :string, allow_nil?: false
      description "Process one tool result and fan-in to the next LLM turn."
      run {Aikido.Slices.AiReact.Implementation, action: :tool_result}
    end

    action :hook_completed, Aikido.Types.ActionResult do
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

    action :hook_context, Aikido.Types.ActionResult do
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
