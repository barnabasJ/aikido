defmodule Aikido.AI.Options do
  @moduledoc "Optional ReAct execution and context controls, supplied at start or per request."
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :completion, :atom,
      default: :model,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:model, :todos]]

    attribute :todo_path, :atom, default: :todos, allow_nil?: false, public?: true
    attribute :streaming, :boolean, default: false, allow_nil?: false, public?: true

    attribute :model_timeout_ms, :integer,
      default: 120_000,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :progress_timeout_ms, :integer,
      default: 60_000,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :tool_timeout_ms, :integer,
      default: 120_000,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :model_max_retries, :integer,
      default: 0,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]

    attribute :tool_max_retries, :integer,
      default: 0,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]

    attribute :retry_backoff_ms, :integer,
      default: 200,
      allow_nil?: false,
      public?: true,
      constraints: [min: 0]

    attribute :stream_batch_ms, :integer,
      default: 100,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :stream_batch_bytes, :integer,
      default: 256,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :context_max_tokens, :integer, public?: true, constraints: [min: 1]

    attribute :handoff, :boolean, public?: true, default: true, allow_nil?: false

    attribute :handoff_buffer_tokens, :integer,
      public?: true,
      default: 24_000,
      allow_nil?: false,
      constraints: [min: 0]

    attribute :handoff_prompt, :string, public?: true
  end

  @doc false
  def resolve(options) do
    {:ok, options} = Ash.Type.cast_input(__MODULE__, options || %{})
    options
  end
end
