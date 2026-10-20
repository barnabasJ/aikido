defmodule Aikido.Hooks.Hook do
  @moduledoc """
  A Lua lifecycle hook. Supply hook maps at agent start or per AI request.

  Synchronous hooks return `{decision = "continue"}` (or nil), optionally
  with `context`, or `{decision = "deny", message = "reason"}`. Asynchronous
  hooks do not gate execution and can call `aikido.send_context(text)` or
  `aikido.send_signal(type, data)` on their originating agent. Neither mode
  can write agent state directly.

  Both modes can call `aikido.request(type, payload)` and receive a response
  inside Lua. Supply an external capture such as `request: &MyApp.Hooks.request/2`.
  The callback receives `%{type: type, payload: payload}` and context containing
  `hook`, `request_id`, and the lifecycle `event`. It runs in the Lua task and
  may return `{:ok, response}` or `{:error, reason}`. The application owns any
  waiting, deadlines, cancellation and UI communication. Callbacks must be portable
  external captures without a captured environment; put serializable per-run
  configuration in `event.metadata`. The callback survives checkpoint and restore.
  Without a callback, `aikido.request` returns an error to Lua.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :name, :string do
      description "Hook identity included in execution results and lifecycle diagnostics."
      allow_nil? false
      public? true
    end

    attribute :event, :atom do
      description "AI lifecycle event that triggers this hook."
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

    attribute :mode, :atom do
      description "Whether the hook gates the lifecycle step or observes it asynchronously."
      constraints one_of: [:sync, :async]
      allow_nil? false
      default :sync
      public? true
    end

    attribute :script, :string do
      description "Lua source evaluated for each matching lifecycle event."
      allow_nil? false
      public? true
    end

    attribute :request, :function do
      constraints arity: 2, mfa: true
      public? true

      description "Portable external callback for Lua requests; returns {:ok, response} or {:error, reason}."
    end

    attribute :max_instructions, :integer do
      description "Maximum Lua instruction count allowed for one hook execution."
      constraints min: 1
      allow_nil? false
      default 100_000
      public? true
    end

    attribute :max_call_depth, :integer do
      description "Maximum Lua call nesting allowed for one hook execution."
      constraints min: 1
      allow_nil? false
      default 64
      public? true
    end

    attribute :max_string_bytes, :integer do
      description "Maximum Lua string size in bytes allowed during hook execution."
      constraints min: 1
      allow_nil? false
      default 1_048_576
      public? true
    end
  end
end
