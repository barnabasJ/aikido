defmodule Aikido.Team.Types.CoordinationMember do
  @moduledoc "Public member availability without startup configuration or process identifiers."
  use Ash.TypedStruct

  typed_struct do
    field :name, :term do
      description "Authored Team member name."
      allow_nil? false
    end

    field :running?, :boolean do
      description "Whether the Team currently records an active member process."
      allow_nil? false
    end

    field :busy?, :boolean do
      description "Whether the Team currently tracks dispatched work for the member."
      allow_nil? false
    end
  end
end
