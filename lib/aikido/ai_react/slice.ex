defmodule Aikido.AiReact.Slice do
  @moduledoc """
  A native Ash slice that owns the ReAct conversation and its next execution step.

  Add `Aikido.AI.Extension` to an agent resource for model configuration and public
  AI actions. Alternatively mount this slice directly with `slice :ai,
  Aikido.AiReact.Slice, options: [...]` inside its `agent` block.

  Runs move from `:idle` to `:setup` while native Ash AI tools are prepared,
  then `:running` for model/tool turns. Terminal states are `:completed` and
  `:failed`; optional todo completion can hold a result in `:waiting`.
  Cancellation and queued messages are accepted during setup and execution.

  The conversation retains native ReqLLM messages, including provider metadata
  and signed reasoning. Model calls and tools run in directives; generic Ash
  actions apply their results. Callers supply Ash AI tool names and native
  `tool_options`; prepared callbacks are rebuilt for each run and never saved.
  """
  use Ash.Resource,
    data_layer: :embedded,
    extensions: [Aikido.Slice.Extension]

  @keyword_constraints [items: [fields: [key: [type: :atom], value: [type: :term]]]]

  slice do
    name "ai"
    description "Embedded ReAct conversation state and native signal reducers."

    schema do
      attribute :handoff_pending, :integer do
        description "Identifier of the context handoff awaiting a summary result."
      end

      attribute :handoff_count, :integer do
        description "Number of context handoffs adopted during this run."
        public? true
        default 0
        allow_nil? false
      end

      attribute :last_handoff, :map do
        description "Details of the most recently adopted context handoff."
        public? true
      end

      attribute :estimated_tokens, :integer do
        description "Estimated token count used to decide when context needs a handoff."
        public? true
        default 0
        allow_nil? false
        constraints min: 0
      end

      attribute :last_input_tokens, :integer do
        description "Provider-reported input token count from the latest model response."
      end

      attribute :prepared_tools, :term do
        description "Transient tool descriptions and callback registry prepared for the current run."
      end

      attribute :run_scope, :map do
        description "Caller actor and tenant bound to the current run for delivery and tool scope checks."
        default %{}
      end

      attribute :run_metadata, :map do
        description "Application metadata attached to the request and its completion."
        public? true
        default %{}
      end

      attribute :options, Aikido.AiReact.Options do
        description "Execution limits, delivery controls and completion policy for this ReAct run."
        public? true
        default %{}
        allow_nil? false
      end

      attribute :queued_messages, {:array, :string} do
        description "User messages waiting to be appended at the next safe model boundary."
        public? true
        default []
        allow_nil? false
      end

      attribute :streaming_text, :string do
        description "Assistant text accumulated from the current streaming model attempt."
        public? true
        default ""
        constraints allow_empty?: true, trim?: false
      end

      attribute :streaming_thinking, :string do
        description "Thinking text accumulated from the current streaming model attempt."
        public? true
        default ""
        constraints allow_empty?: true, trim?: false
      end

      attribute :stream_attempt, :integer do
        description "Latest accepted streaming attempt, used to discard stale retry deltas."
        default 0
      end

      attribute :usage, :map do
        description "Token usage and provider accounting retained from model responses."
        public? true
        default %{}
      end

      attribute :status, Aikido.AiReact.Types.Status do
        description "Current ReAct lifecycle stage from idle through setup, execution and completion."
        public? true
        allow_nil? false
        default :idle
      end

      attribute :request_id, :term do
        description "Identifier correlating the current run with model, tool and hook results."
        public? true
        allow_nil? true
        default nil
      end

      attribute :context, :term do
        description "Native ReqLLM conversation retained across model and tool turns."
        public? true
        allow_nil? true
        default nil
      end

      attribute :iteration, :integer do
        description "Number of model turns already processed in the current run."
        public? true
        allow_nil? false
        default 0
      end

      attribute :max_iterations, :integer do
        description "Maximum number of model turns permitted in the current run."
        public? true
        allow_nil? false
        default 10
        constraints min: 1
      end

      attribute :result, :term do
        description "Final assistant response retained when the run completes."
        public? true
        allow_nil? true
        default nil
      end

      attribute :error, :term do
        description "Failure reason retained when the run cannot complete."
        public? true
        allow_nil? true
        default nil
      end

      attribute :pending_tool_calls, {:array, :term} do
        description "Tool calls from the current model turn awaiting their results."
        public? true
        allow_nil? false
        default []
      end

      attribute :tool_results_received, {:array, :term} do
        description "Tool results already received for the current batch, including their call identifiers."
        public? true
        allow_nil? false
        default []
      end

      attribute :previous_tool_signature, :term do
        description "Signature of the previous tool batch used to detect repeated calls."
        public? true
        allow_nil? true
        default nil
      end

      attribute :model, :term do
        description "Model used by the current run or as the default for the next request."
        public? true
        allow_nil? true
        default nil
      end

      attribute :client, :module do
        description "Module implementing the model generation callback used by this slice."
        public? true
        allow_nil? false
        default ReqLLM.Generation
      end

      attribute :tools, {:array, :atom} do
        description "Native Ash AI tool names available to the model during this run."
        public? true
        allow_nil? false
        default []
      end

      attribute :tool_options, {:array, :tuple} do
        description "Native Ash AI options used to build tool descriptions and callbacks."
        public? true
        default otp_app: :aikido
        constraints @keyword_constraints
      end

      attribute :tool_context, :map do
        description "Native Ash scope and application context supplied to tool execution."
        public? true
        allow_nil? false
        default %{}
      end

      attribute :system_prompt, :term do
        description "System instructions supplied when opening a model conversation."
        public? true
        allow_nil? true
        default nil
      end

      attribute :llm_opts, {:array, :tuple} do
        description "Provider generation options merged into each model request."
        public? true
        allow_nil? false
        default max_tokens: 4096, temperature: 0.2
        constraints @keyword_constraints
      end

      attribute :hooks, {:array, Aikido.AiReact.Hooks.Hook} do
        description "Ordered hook definitions participating in the run lifecycle."
        public? true
        allow_nil? false
        default []
      end

      attribute :hooks_pending, :map do
        description "Hook continuations awaiting their correlated completion signals."
        public? true
        allow_nil? false
        default %{}
      end

      attribute :hook_sequence, :integer do
        description "Monotonic sequence used to identify pending hook continuations."
        public? true
        allow_nil? false
        default 0
      end

      attribute :hook_context, {:array, :map} do
        description "Context entries contributed by hooks for subsequent model turns."
        public? true
        allow_nil? false
        default []
      end

      attribute :hook_errors, {:array, :map} do
        description "Hook failures retained without replacing the primary run result."
        public? true
        allow_nil? false
        default []
      end

      attribute :hook_terminal, Aikido.AiReact.Types.TerminalStatus do
        description "Terminal status awaiting completion of synchronous lifecycle hooks."
        public? true
      end
    end

    config_schema do
      attribute :options, Aikido.AiReact.Options do
        description "Default execution limits, delivery controls and completion policy for mounted agents."
        public? true
        default %{}
        allow_nil? false
      end

      attribute :hooks, {:array, Aikido.AiReact.Hooks.Hook} do
        description "Default lifecycle hooks inherited by agents mounting this slice."
        public? true
        allow_nil? false
        default []
      end

      attribute :model, :term do
        description "Default model inherited by agents mounting this slice."
        public? true
        allow_nil? true
      end

      attribute :client, :module do
        description "Default generation callback module inherited by mounted agents."
        public? true
        allow_nil? false
        default ReqLLM.Generation
      end

      attribute :tools, {:array, :atom} do
        description "Default native Ash AI tool names inherited by mounted agents."
        public? true
        allow_nil? false
        default []
      end

      attribute :tool_options, {:array, :tuple} do
        description "Default native Ash AI options used to prepare tools for mounted agents."
        public? true
        default otp_app: :aikido
        constraints @keyword_constraints
      end

      attribute :tool_context, :map do
        description "Default native Ash scope and application context for tool execution."
        public? true
        allow_nil? false
        default %{}
      end

      attribute :system_prompt, :term do
        description "Default system instructions for conversations opened by mounted agents."
        public? true
        allow_nil? true
      end

      attribute :max_iterations, :integer do
        description "Default maximum number of model turns permitted in a run."
        public? true
        allow_nil? false
        default 10
        constraints min: 1
      end

      attribute :llm_opts, {:array, :tuple} do
        description "Default provider generation options inherited by mounted agents."
        public? true
        allow_nil? false
        default max_tokens: 4096, temperature: 0.2
        constraints @keyword_constraints
      end
    end

    route Aikido.AiReact.Signals.HandoffCompleted,
          Aikido.AiReact.Actions.HandoffCompleted, public?: false

    route Aikido.AiReact.Signals.HandoffFailed,
          Aikido.AiReact.Actions.HandoffFailed, public?: false

    route Aikido.AiReact.Signals.ToolsReady, Aikido.AiReact.Actions.ToolsReady, public?: false

    route Aikido.AiReact.Signals.Ask, Aikido.AiReact.Actions.Ask
    route Aikido.AiReact.Signals.Message, Aikido.AiReact.Actions.Message
    route Aikido.AiReact.Signals.Deliver, Aikido.AiReact.Actions.Deliver

    route Aikido.AiReact.Signals.ReplaceContext,
          Aikido.AiReact.Actions.ReplaceContext

    route Aikido.Todo.Signals.TodoChanged, Aikido.AiReact.Actions.TodoChanged, public?: false

    route Aikido.AiReact.Signals.Stream, Aikido.AiReact.Actions.Stream, public?: false

    route Aikido.AiReact.Signals.LlmTurn, Aikido.AiReact.Actions.LlmTurn, public?: false

    route Aikido.AiReact.Signals.ToolResult, Aikido.AiReact.Actions.ToolResult, public?: false

    route Aikido.AiReact.Signals.Failed, Aikido.AiReact.Actions.Failed, public?: false

    route Aikido.AiReact.Signals.Cancel, Aikido.AiReact.Actions.Cancel

    route Aikido.AiReact.Signals.HookCompleted,
          Aikido.AiReact.Actions.HookCompleted, public?: false

    route Aikido.AiReact.Signals.HookContext, Aikido.AiReact.Actions.HookContext, public?: false
  end

  @behaviour Aikido.Durable.Codec

  @doc false
  @impl true
  def externalize(state),
    do:
      Map.merge(state, %{
        handoff_pending: nil,
        prepared_tools: nil,
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

    context =
      if(state.context,
        do: Aikido.AiReact.Conversation.append_interrupted_tool_results(state.context)
      )

    state = Aikido.AiReact.Conversation.replace_context(state, context)

    Map.merge(state, %{
      handoff_pending: nil,
      prepared_tools: nil,
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
