defmodule Aikido.Ash.AI do
  @moduledoc """
  A common AI interface for agent and team resources.

  Add to an `Ash.Resource` extended by `Aikido.Ash.Agent`, optionally alongside
  `Aikido.Ash.Team`. Both expose `ask(query, request_id)` and `cancel(request_id)`
  generic actions. Model configuration and the runtime tool list are attributes
  supplied at create time. Tools can be built dynamically as `ReqLLM.Tool` objects
  with callbacks; no compile-time tool declaration is required.

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
      client: [type: :module, default: ReqLLM.Generation],
      system_prompt: [type: :string],
      max_iterations: [type: :pos_integer, default: 10]
    ]
  }
  use Spark.Dsl.Extension, sections: [@ai], transformers: [Aikido.Ash.Transformers.AI]
end
