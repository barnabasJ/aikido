defmodule Aikido.Ash.Team.Types.Activation do
  @moduledoc "When a desired team member is activated."
  use Ash.Type.Enum,
    values: [
      eager: "Start the member with the topology.",
      lazy: "Start the member when explicitly requested."
    ]
end
