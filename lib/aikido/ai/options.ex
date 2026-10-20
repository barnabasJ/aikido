defmodule Aikido.AI.Options do
  @moduledoc "Optional ReAct execution and context controls, supplied at start or per request."
  use Ash.TypedStruct

  typed_struct do
    field :completion, :atom do
      description "Whether the run completes from the model response or from the tracked todo state."
      default :model
      allow_nil? false
      constraints one_of: [:model, :todos]
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

    field :handoff_prompt, :string do
      description "Optional instruction used to summarize context during a conversation handoff."
    end
  end
end
