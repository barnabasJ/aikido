defmodule Aikido.Hooks.Hook do
  @moduledoc """
  A Lua lifecycle hook. Supply hook maps at agent start or per AI request.

  Synchronous hooks return `{decision = "continue"}` (or nil), optionally
  with `context`, or `{decision = "deny", message = "reason"}`. Asynchronous
  hooks do not gate execution and can call `aikido.send_context(text)` or
  `aikido.send_signal(type, data)` on their originating agent. Neither mode
  can write agent state directly.
  """
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  attributes do
    attribute :name, :string, allow_nil?: false, public?: true

    attribute :event, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :run_started,
                    :before_model,
                    :after_model,
                    :before_tool,
                    :after_tool,
                    :run_completed,
                    :run_failed,
                    :run_cancelled
                  ]
    end

    attribute :mode, :atom,
      constraints: [one_of: [:sync, :async]],
      allow_nil?: false,
      default: :sync,
      public?: true

    attribute :script, :string, allow_nil?: false, public?: true

    attribute :max_instructions, :integer,
      constraints: [min: 1],
      allow_nil?: false,
      default: 100_000,
      public?: true

    attribute :max_call_depth, :integer,
      constraints: [min: 1],
      allow_nil?: false,
      default: 64,
      public?: true

    attribute :max_string_bytes, :integer,
      constraints: [min: 1],
      allow_nil?: false,
      default: 1_048_576,
      public?: true
  end
end
