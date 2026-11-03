defmodule Aikido.Thread.Types.Cursor do
  @moduledoc "A position within one retained journal generation."
  use Ash.TypedStruct

  typed_struct do
    field :generation, :string do
      description "Journal generation; clearing the journal changes this identity."
      allow_nil? false
    end

    field :sequence, :integer do
      description "Last committed sequence, or -1 before the first entry."
      allow_nil? false
      constraints min: -1
    end
  end
end
