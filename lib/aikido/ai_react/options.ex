defmodule Aikido.AiReact.Options do
  @moduledoc "Optional ReAct execution and context controls, supplied at start or per request."
  use Ash.TypedStruct

  typed_struct do
    field :tool_preparation, :tuple do
      description "Optional native Ash action {resource, action} accepting options and metadata and returning native Ash AI options."

      constraints fields: [
                    resource: [type: :atom, allow_nil?: false],
                    action: [type: :atom, allow_nil?: false]
                  ]
    end

    field :todo_continuation, Aikido.AiReact.Types.TodoContinuation do
      description "Whether open blocking todos wait for external work or trigger another model turn."
      default :wait
      allow_nil? false
    end

    field :max_todo_continuations, :integer do
      description "Maximum additional model turns requested for unfulfilled or rejected todo work."
      default 3
      allow_nil? false
      constraints min: 0
    end

    field :todo_verifier, :tuple do
      description "Optional scoped Ash action {resource, action} accepting answer, todos and metadata and returning a boolean verdict."

      constraints fields: [
                    resource: [type: :atom, allow_nil?: false],
                    action: [type: :atom, allow_nil?: false]
                  ]
    end

    field :max_consecutive_tool_errors, :integer do
      description "Optional consecutive failing tool-batch limit; nil leaves recovery to the model."
      constraints min: 1
    end

    field :tool_loop_key, :tuple do
      description "Optional pure {module, function, arguments} returning {:ok, comparison_key} for a sorted completed batch of {name, arguments, content} entries."

      constraints fields: [
                    module: [type: :atom, allow_nil?: false],
                    function: [type: :atom, allow_nil?: false],
                    arguments: [type: {:array, :term}, allow_nil?: false]
                  ]
    end

    field :max_repeated_tool_cycles, :integer do
      description "Optional repeat limit for tool cycles of one to four batches; nil keeps warning-only behavior."
      constraints min: 2, max: 100
    end

    field :completion, Aikido.AiReact.Types.CompletionMode do
      description "Whether the run completes from the model response, blocking todos or the team's background assignments."
      default :model
      allow_nil? false
    end

    field :todo_path, :atom do
      description "Mounted todo slice inspected when completion is controlled by todos."
      default :todos
      allow_nil? false
    end

    field :streaming, :boolean do
      description "Whether model generation streams text and thinking updates through signals."
      default false
      allow_nil? false
    end

    field :model_timeout_ms, :integer do
      description "Maximum duration of a model generation attempt in milliseconds."
      default 120_000
      allow_nil? false
      constraints min: 1
    end

    field :progress_timeout_ms, :integer do
      description "Maximum interval without progress during streaming model generation, in milliseconds."
      default 60_000
      allow_nil? false
      constraints min: 1
    end

    field :tool_timeout_ms, :integer do
      description "Maximum duration of a tool execution attempt in milliseconds."
      default 120_000
      allow_nil? false
      constraints min: 1
    end

    field :model_max_retries, :integer do
      description "Number of additional attempts allowed after a retryable model failure."
      default 0
      allow_nil? false
      constraints min: 0
    end

    field :tool_max_retries, :integer do
      description "Number of additional attempts allowed after a retryable tool failure."
      default 0
      allow_nil? false
      constraints min: 0
    end

    field :retry_backoff_ms, :integer do
      description "Base delay in milliseconds before retrying failed model or tool work."
      default 200
      allow_nil? false
      constraints min: 0
    end

    field :stream_batch_ms, :integer do
      description "Time interval in milliseconds used to flush buffered streaming output."
      default 100
      allow_nil? false
      constraints min: 1
    end

    field :stream_batch_bytes, :integer do
      description "Buffered output size in bytes that triggers a streaming update."
      default 256
      allow_nil? false
      constraints min: 1
    end

    field :context_max_tokens, :integer do
      description "Optional token budget used to decide when conversation context needs a handoff."
      constraints min: 1
    end

    field :handoff, :boolean do
      description "Whether context handoff is enabled when the configured token budget is approached."
      default true
      allow_nil? false
    end

    field :handoff_buffer_tokens, :integer do
      description "Token headroom reserved below the context budget before starting a handoff."
      default 24_000
      allow_nil? false
      constraints min: 0
    end

    field :handoff_max_regenerations, :integer do
      description "Additional summary generations allowed after empty, invalid or oversized handoff documents. Truncated summaries are not retried."
      default 0
      allow_nil? false
      constraints min: 0
    end

    field :handoff_prompt, :string do
      description "Optional instruction used to summarize context during a conversation handoff."
    end
  end
end
