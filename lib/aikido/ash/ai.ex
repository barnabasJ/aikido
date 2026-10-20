defmodule Aikido.Ash.AI do
  @moduledoc """
  A common AI interface for agent and team resources.

  Add to an `Ash.Resource` extended by `Aikido.Ash.Agent`, optionally alongside
  `Aikido.Ash.Team`. Both expose `ask(query, request_id)` and `cancel(request_id)`
  generic actions. Model configuration and the runtime tool list are attributes
  supplied at create time. Pass Ash AI tool names in `tools`; `tool_options`
  accepts native Ash AI configuration such as `otp_app` or `actions`. The default
  source is the resource/domain OTP application. Aikido builds native tool
  descriptions and execution registries inside I/O tasks, never in state actions.

  Supply `hooks` at start or set defaults in `ai`. Lua sync hooks gate lifecycle
  steps; async observers can inject context through signals. See
  `Aikido.Slices.AiReact.Hooks.Hook` and the runtime-patterns guide.

      ai do
        model "zai:glm-4.7"
      end

  Tool execution uses the same ReAct signal pipeline for a single agent and
  a team. A team can use application-defined Ash actions to delegate work to
  members. The caller does not need to know its topology.
  """
  @ai %Spark.Dsl.Section{
    name: :ai,
    schema: [
      model: [type: :any],
      options: [type: :map, default: %{}],
      tool_options: [type: :keyword_list, default: []],
      client: [type: :module, default: ReqLLM.Generation],
      system_prompt: [type: :string],
      llm_opts: [type: :keyword_list, default: []],
      hooks: [type: {:list, :map}, default: []],
      max_iterations: [type: :pos_integer, default: 10]
    ]
  }
  use Spark.Dsl.Extension,
    sections: [@ai],
    transformers: [Aikido.Ash.AI.Transformers.Build],
    verifiers: [Aikido.Ash.AI.Verifiers.Validate]
end
