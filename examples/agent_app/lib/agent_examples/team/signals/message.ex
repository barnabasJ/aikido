defmodule AgentExamples.Team.Signals.Message do
  @moduledoc "A conversation message received by the example coordinator."
  use Aikido.Signal

  signal do
    type "example.team.message"

    schema do
      attribute :text, :string do
        description "Public message shown beside the example's Team controls."
        allow_nil? false
      end
    end
  end
end
