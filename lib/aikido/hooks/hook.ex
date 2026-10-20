defmodule Aikido.Hooks.Hook do
  @moduledoc """
  A Lua lifecycle hook. Supply hook maps at agent start or per AI request.

  Synchronous hooks return `{decision = "continue"}` (or nil), optionally
  with `context`, or `{decision = "deny", message = "reason"}`. Asynchronous
  hooks do not gate execution and can call `aikido.send_context(text)` or
  `aikido.send_signal(type, data)` on their originating agent. Neither mode
  can write agent state directly.

  Both modes can call `aikido.request(type, payload)` and receive a response
  inside Lua. Supply `request: fn request, context -> {:ok, response} end`.
  The callback receives `%{type: type, payload: payload}` and context containing
  `hook`, `request_id`, and the lifecycle `event`. It runs in the Lua task and
  may return `{:ok, response}` or `{:error, reason}`. The application owns any
  waiting, deadlines, cancellation and UI communication. Without a callback,
  `aikido.request` returns an error to Lua.
  """
  use Ash.Resource, data_layer: :embedded

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

    attribute :request, :function,
      constraints: [arity: 2],
      public?: true,
      description:
        "Application callback for Lua requests; returns {:ok, response} or {:error, reason}."

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
