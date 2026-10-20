defmodule Aikido.Hooks.Decision do
  @moduledoc "The validated result of a synchronous Lua hook."
  use Ash.TypedStruct

  typed_struct do
    field :decision, :atom do
      description "Whether the synchronous hook allows the lifecycle step to continue or denies it."
      constraints one_of: [:continue, :deny]
      allow_nil? false
      default :continue
    end

    field :context, :string do
      description "Optional text contributed by the hook to the model's context."
    end

    field :message, :string do
      description "Optional explanation returned when the hook denies the lifecycle step."
    end
  end
end
