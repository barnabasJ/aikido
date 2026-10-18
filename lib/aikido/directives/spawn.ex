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

  use Aikido.Directive

  typed_struct do
    field :child_spec, :term, allow_nil?: false, description: "Supervisor child_spec"
    field :tag, :term, allow_nil?: true, description: "Optional correlation tag"
  end

  require Logger

  @impl true
  def exec(%{child_spec: child_spec, tag: tag}, _input_signal, state) do
    result =
      if is_function(state.spawn_fun, 1) do
        state.spawn_fun.(child_spec)
      else
        agent_sup =
          if state.aikido,
            do: Aikido.agent_supervisor_name(state.aikido),
            else: Aikido.AgentSupervisor

        DynamicSupervisor.start_child(agent_sup, child_spec)
      end

    case result do
      {:ok, pid} ->
        Logger.debug("Spawned child process #{inspect(pid)} with tag #{inspect(tag)}")
        :ok

      {:ok, pid, _info} ->
        Logger.debug("Spawned child process #{inspect(pid)} with tag #{inspect(tag)}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to spawn child: #{inspect(reason)}")
        :ok

      :ignored ->
        :ok
    end
  end
end
