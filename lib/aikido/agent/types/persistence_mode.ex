defmodule Aikido.Agent.Types.PersistenceMode do
  @moduledoc "Snapshot retention policy applied when an agent stops."
  use Ash.Type.Enum,
    values: [
      permanent: "Retain the saved identity and state after stopping.",
      temporary: "Delete the saved identity and state when stopping."
    ]
end
