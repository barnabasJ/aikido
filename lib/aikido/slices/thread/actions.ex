defmodule Aikido.Slices.Thread.Actions do
  @moduledoc "Native Ash state-transition actions for the thread slice."
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :append, Aikido.ActionResult do
      argument :state, :term

      argument :entry, Aikido.Types.Union,
        description: "Entry map (or list of entry maps) to append.",
        allow_nil?: false,
        constraints: [
          types: [[type: :map, constraints: []], [type: {:array, :map}, constraints: []]]
        ]

      description "Append one or more entries to the thread."
      run {Aikido.Slices.Thread.Actions.Implementation, action: :append}
    end

    action :clear, Aikido.ActionResult do
      argument :state, :term
      description "Reset the thread to an empty state."
      run {Aikido.Slices.Thread.Actions.Implementation, action: :clear}
    end

    action :ensure, Aikido.ActionResult do
      argument :state, :term

      argument :metadata, :map,
        description: "Optional metadata for newly created thread.",
        default: %{}

      argument :id, :string, description: "Optional explicit thread id."
      description "Initialize thread state if missing."
      run {Aikido.Slices.Thread.Actions.Implementation, action: :ensure}
    end
  end
end
