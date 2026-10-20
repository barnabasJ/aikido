defmodule Aikido.Hooks.Decision do
  @moduledoc "The validated result of a synchronous Lua hook."
  use Ash.TypedStruct

  typed_struct do
    field :decision, :atom,
      constraints: [one_of: [:continue, :deny]],
      allow_nil?: false,
      default: :continue

    field :context, :string
    field :message, :string
  end
end
