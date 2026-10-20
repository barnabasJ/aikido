defmodule Aikido.Slices.AiReact.Signals.Ask do
  @moduledoc "Typed payload for `ai.react.ask`."
  use Aikido.Signal

  @keyword_constraints [items: [fields: [key: [type: :atom], value: [type: :term]]]]

  signal do
    type "ai.react.ask"

    schema do
      attribute :options, Aikido.Slices.AiReact.Options do
        description "Execution policy overrides applied when opening this ReAct run."
      end

      attribute :tool_options, {:array, :tuple} do
        description "Native Ash AI options used to prepare tools for the requested run."
        constraints @keyword_constraints
      end

      attribute :tool_context, :map do
        description "Native Ash scope and application context supplied to this run's tools."
      end

      attribute :metadata, :map do
        description "Application metadata retained with the requested run and its completion."
        default %{}
      end

      attribute :query, :string do
        description "User request used to open the ReAct conversation."
        allow_nil? false
      end

      attribute :request_id, :string do
        description "Caller-supplied identifier correlating the new run with its later results."
        allow_nil? false
      end

      attribute :model, :term do
        description "Optional model override for the requested run."
      end

      attribute :client, :module do
        description "Optional generation callback module overriding the slice configuration."
      end

      attribute :tools, {:array, :atom} do
        description "Optional native Ash AI tool names exposed to the requested run."
      end

      attribute :system_prompt, :string do
        description "Optional system instructions overriding the slice configuration."
      end

      attribute :max_iterations, :integer do
        description "Optional upper bound on model turns for the requested run."
        constraints min: 1
      end

      attribute :llm_opts, {:array, :tuple} do
        description "Provider generation options merged into the requested run."
        constraints @keyword_constraints
      end

      attribute :hooks, {:array, Aikido.Slices.AiReact.Hooks.Hook} do
        description "Optional ordered hook definitions overriding the slice configuration."
      end
    end
  end
end
