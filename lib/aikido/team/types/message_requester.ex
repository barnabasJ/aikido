defmodule Aikido.Team.Types.MessageRequester do
  @moduledoc "Requester provenance attested by the coordinator at native Send admission time."
  use Ash.TypedStruct

  typed_struct do
    field :member, :term do
      description "Requesting member name, or :self for the coordinator's native nil/self request."
      allow_nil? false
    end

    field :reference, Aikido.Agent.Reference do
      description "Durable address derived from the coordinator's actual current membership."
      allow_nil? false
    end

    field :incarnation, :term do
      description "Recorded member activation at send time; nil for the coordinator itself."
    end
  end
end
