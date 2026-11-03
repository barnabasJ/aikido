defmodule Aikido.Thread.Types.EntryReceipt do
  @moduledoc "Immutable identity and content digest retained after an entry's replay payload is pruned."
  use Ash.TypedStruct

  typed_struct do
    field :id, :string do
      description "Immutable caller-supplied or source-generated entry identity."
      allow_nil? false
    end

    field :seq, :integer do
      description "Original assigned sequence, retained for identical retry comparison."
      allow_nil? false
      constraints min: 0
    end

    field :at, :integer do
      description "Original entry timestamp."
      allow_nil? false
    end

    field :refs, :map do
      description "Original source signal references, used when retries omit generated references."
      default %{}
      allow_nil? false
    end

    field :digest, :string do
      description "SHA-256 digest of the entry dumped through native Ash types."
      allow_nil? false
    end
  end
end
