defmodule Aikido.Hooks.Decision do
  @moduledoc "The validated result of a synchronous Lua hook."
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  attributes do
    attribute :decision, :atom,
      constraints: [one_of: [:continue, :deny]],
      allow_nil?: false,
      default: :continue,
      public?: true

    attribute :context, :string, public?: true
    attribute :message, :string, public?: true
  end
end
