defmodule Aikido.Team.Signals.Send do
  @moduledoc "Typed payload for `aikido.ash.team.send`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.send"

    schema do
      attribute :member, :term do
        description "Topology name of the member to operate on."
        allow_nil? false
      end

      attribute :type, :string do
        description "Signal type delivered to the target member."
        allow_nil? false
      end

      attribute :payload, :map do
        description "Arguments carried by the delivered signal."
        default %{}
      end
    end
  end
end
