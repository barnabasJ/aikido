defmodule Aikido.Slices.Memory.Actions do
  @moduledoc "Native Ash state-transition actions for the memory slice."
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :append_to_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "List space name.", allow_nil?: false
      argument :item, :term, description: "Item to append.", allow_nil?: false
      description "Append an item to a list space."
      run {Aikido.Slices.Memory.Actions.Implementation, action: :append_to_space}
    end

    action :delete_from_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Map space name.", allow_nil?: false
      argument :key, :term, description: "Key to remove.", allow_nil?: false
      description "Delete a key from a map space."
      run {Aikido.Slices.Memory.Actions.Implementation, action: :delete_from_space}
    end

    action :delete_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Space name to delete.", allow_nil?: false
      description "Delete a non-reserved space."
      run {Aikido.Slices.Memory.Actions.Implementation, action: :delete_space}
    end

    action :ensure, Aikido.ActionResult do
      argument :state, :term
      argument :metadata, :map, description: "Optional metadata for new memory.", default: %{}
      argument :id, :string, description: "Optional explicit memory id."
      description "Initialize memory state if missing."
      run {Aikido.Slices.Memory.Actions.Implementation, action: :ensure}
    end

    action :ensure_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Space name to ensure.", allow_nil?: false

      argument :default, Aikido.Types.Union,
        description: "Default data for the new space (map → kv, list → list).",
        default: %{},
        constraints: [
          types: [[type: :map, constraints: []], [type: {:array, :term}, constraints: []]]
        ]

      description "Create a space with default data if missing."
      run {Aikido.Slices.Memory.Actions.Implementation, action: :ensure_space}
    end

    action :put_in_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Map space name.", allow_nil?: false
      argument :key, :term, description: "Key to set.", allow_nil?: false
      argument :value, :term, description: "Value to associate with `key`.", allow_nil?: false
      description "Set a key in a map space."
      run {Aikido.Slices.Memory.Actions.Implementation, action: :put_in_space}
    end

    action :put_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Space name to set.", allow_nil?: false

      argument :value, :term,
        description: "%Aikido.Slices.Memory.Space{} to install at the named key.",
        allow_nil?: false

      description "Store a space wholesale at the named key."
      run {Aikido.Slices.Memory.Actions.Implementation, action: :put_space}
    end

    action :update_space, Aikido.ActionResult do
      argument :state, :term
      argument :space, :atom, description: "Space name to update.", allow_nil?: false

      argument :value, :term,
        description: "Replacement %Aikido.Slices.Memory.Space{} value.",
        allow_nil?: false

      description "Replace the value of an existing space."
      run {Aikido.Slices.Memory.Actions.Implementation, action: :update_space}
    end
  end
end
