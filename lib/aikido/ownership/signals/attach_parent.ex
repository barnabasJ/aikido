defmodule Aikido.Ownership.Signals.AttachParent do
  @moduledoc "Requests a parent binding for an unattached child."
  use Aikido.Signal

  signal do
    type "aikido.ownership.attach_parent"

    schema do
      attribute :parent, :term do
        description "Logical parent reference to attach."
        allow_nil? false
      end

      attribute :initial_only?, :boolean do
        description "Ignore late activation repair after an existing binding or orphan transition."
        default false
        allow_nil? false
      end
    end
  end
end
