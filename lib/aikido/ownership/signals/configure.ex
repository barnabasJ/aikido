defmodule Aikido.Ownership.Signals.Configure do
  @moduledoc "Applies validated startup ownership options before lifecycle signals run."
  use Aikido.Signal

  signal do
    type "aikido.ownership.configure"

    schema do
      attribute :parent, :term do
        description "Optional logical parent supplied by the activation boundary."
      end

      attribute :on_parent_death, Aikido.Ownership.Types.ParentDeathPolicy do
        description "Policy applied when the parent's process exits."
        default :stop
        allow_nil? false
      end
    end
  end
end
