defmodule Aikido.Team.Types.DelegationMode do
  @moduledoc "Whether a task's requester waits for its result or receives it later."
  use Ash.Type.Enum, values: [:foreground, :background]
end
