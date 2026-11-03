defmodule Aikido.Team.Types.MembershipEvent do
  @moduledoc "Fixed native journal protocol states."
  use Ash.Type.Enum, values: [:added, :started, :stopped, :removed, :replaced]
end
