defmodule Aikido.Durable.SyncPolicy do
  @moduledoc "Per-agent DurableServer synchronization policy, inherited by children unless overridden."
  use Ash.TypedStruct

  typed_struct do
    field :mode, Aikido.Durable.Types.SyncMode do
      description "Periodic batches dirty state; automatic uses DurableServer callback sync; explicit requests strict sync after persistent transitions."
      default :periodic
      allow_nil? false
    end

    field :interval_ms, :integer do
      description "Native DurableServer periodic checkpoint interval in milliseconds. Lifecycle writes remain immediate."
      default 30_000
      constraints min: 1
      allow_nil? false
    end
  end
end
