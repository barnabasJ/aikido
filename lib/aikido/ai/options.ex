defmodule Aikido.AI.Options do
  @moduledoc "Optional ReAct execution and context controls, supplied at start or per request."
  use Ash.TypedStruct

  typed_struct do
    field :completion, :atom,
      default: :model,
      allow_nil?: false,
      constraints: [one_of: [:model, :todos]]

    field :todo_path, :atom, default: :todos, allow_nil?: false
    field :streaming, :boolean, default: false, allow_nil?: false

    field :model_timeout_ms, :integer,
      default: 120_000,
      allow_nil?: false,
      constraints: [min: 1]

    field :progress_timeout_ms, :integer,
      default: 60_000,
      allow_nil?: false,
      constraints: [min: 1]

    field :tool_timeout_ms, :integer,
      default: 120_000,
      allow_nil?: false,
      constraints: [min: 1]

    field :model_max_retries, :integer,
      default: 0,
      allow_nil?: false,
      constraints: [min: 0]

    field :tool_max_retries, :integer,
      default: 0,
      allow_nil?: false,
      constraints: [min: 0]

    field :retry_backoff_ms, :integer,
      default: 200,
      allow_nil?: false,
      constraints: [min: 0]

    field :stream_batch_ms, :integer,
      default: 100,
      allow_nil?: false,
      constraints: [min: 1]

    field :stream_batch_bytes, :integer,
      default: 256,
      allow_nil?: false,
      constraints: [min: 1]

    field :context_max_tokens, :integer, constraints: [min: 1]

    field :handoff, :boolean, default: true, allow_nil?: false

    field :handoff_buffer_tokens, :integer,
      default: 24_000,
      allow_nil?: false,
      constraints: [min: 0]

    field :handoff_prompt, :string
  end

  @doc false
  def resolve(options), do: new!(options || %{})
end
