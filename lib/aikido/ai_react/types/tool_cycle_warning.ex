defmodule Aikido.AiReact.Types.ToolCycleWarning do
  @moduledoc "Structured facts attached to a model-visible tool-cycle warning message."
  use Ash.TypedStruct

  typed_struct do
    field :request_id, :string do
      description "Run whose successful tool batches crossed the warning threshold."
      allow_nil? false
    end

    field :iteration, :integer do
      description "Model turn whose adopted tool batch crossed the threshold."
      allow_nil? false
      constraints min: 0
    end

    field :period, :integer do
      description "Smallest matching cycle length in completed tool batches."
      allow_nil? false
      constraints min: 1, max: 4
    end

    field :repetitions, :integer do
      description "Complete successful cycles observed at the warning threshold."
      allow_nil? false
      constraints min: 3, max: 3
    end
  end
end
