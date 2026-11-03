defmodule Aikido.Thread.Types.Batch do
  @moduledoc "Correlation for the single outstanding batch of one consumer."
  use Ash.TypedStruct

  typed_struct do
    field :id, :string do
      description "Stable identity for this offered range until acknowledgement."
      allow_nil? false
    end

    field :generation, :string do
      description "Generation containing the offered entries."
      allow_nil? false
    end

    field :first_sequence, :integer do
      description "First offered sequence, inclusive."
      allow_nil? false
      constraints min: 0
    end

    field :last_sequence, :integer do
      description "Last offered sequence, inclusive."
      allow_nil? false
      constraints min: 0
    end
  end
end
