defmodule Aikido.Team.Signals.Start do
  @moduledoc "Typed payload for `aikido.ash.team.start`."
  use Aikido.Signal

  signal do
    type "aikido.ash.team.start"

    schema do
      attribute :topology, :map do
        description "Desired topology to configure; omitted values retain the configured topology."
      end
    end
  end
end
