defmodule Aikido.Directives.Spawn do
  @moduledoc """
  Spawn a generic BEAM child process under the agent's supervisor.

  This is a **low-level, fire-and-forget** directive for spawning non-agent
  processes (Tasks, GenServers, etc.). The spawned process is **not tracked**
  in the agent's children map and has no parent-child relationship semantics.

  Use `SpawnAgent` instead if you need to spawn another Aikido agent with:
  - Parent-child hierarchy tracking
  - Process monitoring and exit signals
  - The ability to address the parent from the child via `ctx.parent.pid`
  - Lifecycle management via `StopChild`

  ## Fields

  - `child_spec` - Supervisor child_spec for the process to spawn
  - `tag` - Optional correlation tag for logging (not used for tracking)
  """

  use Ash.TypedStruct

  typed_struct do
    field :child_spec, :term, allow_nil?: false, description: "Supervisor child_spec"
    field :tag, :term, allow_nil?: true, description: "Optional correlation tag"
  end

  @schema __MODULE__
  defoverridable new!: 1

  @type t :: %__MODULE__{}

  @doc "Returns the Ash type for Spawn."
  @spec schema() :: Aikido.Schema.t()
  def schema, do: @schema
end
