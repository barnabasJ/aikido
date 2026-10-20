defmodule Aikido.Agent.SliceUpdate do
  @moduledoc """
  Multi-slice action return value used when one action transactionally
  mutates multiple slices on the agent.

  Use sparingly — most actions own a single slice and should just return
  the new slice value. Multi-slice writes are an explicit escape hatch
  for genuinely cross-cutting actions.

  ## Usage

      def run(input, _opts, _context) do
        Aikido.Types.ActionResult.new(
          state: %Aikido.Agent.SliceUpdate{
            slices: %{
              team: input.arguments.team,
              audit: %{last_event: "topology.updated"}
            }
          }
        )
      end

  Actions are pure: state changes flow only through their return values.
  All side effects belong in directives, which must not mutate state.
  """

  @enforce_keys [:slices]
  defstruct [:slices]

  @type t :: %__MODULE__{slices: %{atom() => map()}}
end
