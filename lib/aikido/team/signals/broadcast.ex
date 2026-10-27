defmodule Aikido.Team.Signals.Broadcast do
  @moduledoc "Typed payload for `aikido.ash.team.broadcast`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.broadcast"

    schema do
      attribute :type, :string do
        description "Signal type delivered to the target member."
        allow_nil? false
      end

      attribute :payload, :map do
        description "Arguments carried by the delivered signal."
        default %{}
      end

      attribute :members, {:array, :term} do
        description "Recipient member names; nil broadcasts to every active member."
      end
    end
  end
end
