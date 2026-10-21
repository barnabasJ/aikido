defmodule Aikido.AiReact.Hooks.Hook do
  @moduledoc """
  A Lua lifecycle hook. Supply hook maps at agent start or per AI request.

  Synchronous hooks return `{decision = "continue"}` (or nil), optionally
  with `context`, or `{decision = "deny", message = "reason"}`. Asynchronous
  hooks do not gate execution and can call `aikido.send_context(text)` or
  `aikido.send_signal(type, data)` on their originating agent. Neither mode
  can write agent state directly.

  Each execution uses a fresh AshLua VM. `lua_options` selects the application's
  action surface with `otp_app`, optional `labels` and `action_entrypoints`, or an
  `eval_resource` configured with `AshLua.EvalActions`. Empty options expose no
  application actions. These selectors are serializable configuration; the live
  actor, tenant and application context come from the triggering signal.

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

    attribute :event, Aikido.AiReact.Hooks.Types.Event do
      description "AI lifecycle event that triggers this hook."
      allow_nil? false
      public? true
    end

    attribute :mode, Aikido.AiReact.Hooks.Types.Mode do
      description "Whether the hook gates the lifecycle step or observes it asynchronously."
      allow_nil? false
      default :sync
      public? true
    end

    attribute :script, :string do
      description "Lua source evaluated for each matching lifecycle event."
      allow_nil? false
      public? true
    end

    attribute :lua_options, :keyword do
      description "Serializable AshLua surface configuration; select an OTP app or an EvalActions resource. Empty options expose no Ash actions."
      public? true
      allow_nil? false
      default []

      constraints fields: [
                    otp_app: [type: :atom],
                    eval_resource: [type: :atom],
                    labels: [type: {:array, :atom}],
                    action_entrypoints: [
                      type: {:array, :tuple},
                      constraints: [
                        items: [
                          fields: [
                            resource: [type: :atom, allow_nil?: false],
                            action: [type: :atom, allow_nil?: false]
                          ]
                        ]
                      ]
                    ],
                    forbidden_fields: [
                      type: Aikido.AiReact.Hooks.Types.ForbiddenFieldPolicy
                    ]
                  ]
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
