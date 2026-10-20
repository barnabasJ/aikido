defmodule Aikido.Signals.AiReact.Ask do
  @moduledoc "Typed payload for `ai.react.ask`."
  use Aikido.Signal

  @keyword_constraints [items: [fields: [key: [type: :atom], value: [type: :term]]]]

  signal do
    type "ai.react.ask"

    schema do
      attribute :options, Aikido.AI.Options

      attribute :tool_options, {:array, :tuple}, constraints: @keyword_constraints

      attribute :tool_context, :map

      attribute :metadata, :map, default: %{}

      attribute :query, :string, allow_nil?: false

      attribute :request_id, :string, allow_nil?: false

      attribute :model, :term

      attribute :client, :module

      attribute :tools, {:array, :atom}

      attribute :system_prompt, :string

      attribute :max_iterations, :integer, constraints: [min: 1]

      attribute :llm_opts, {:array, :tuple}, constraints: @keyword_constraints

      attribute :hooks, {:array, Aikido.Hooks.Hook}
    end
  end
end
