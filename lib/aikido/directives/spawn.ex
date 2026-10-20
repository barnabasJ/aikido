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
    field :child_spec, :term do
      allow_nil? false
      description "OTP child specification started under the runtime's process supervisor."
    end

    field :tag, :term do
      allow_nil? true
      description "Optional correlation tag included in spawn diagnostics."
    end
  end

  require Logger

  @impl true
  def exec(%{child_spec: child_spec, tag: tag}, input_signal, state) do
    supervisor = Aikido.process_supervisor_name(state.aikido)

    task = %Aikido.Directives.AsyncTask{
      work: fn ->
        case DynamicSupervisor.start_child(supervisor, child_spec) do
          {:ok, pid} ->
            Logger.debug("Spawned child process #{inspect(pid)} with tag #{inspect(tag)}")

          {:ok, pid, _info} ->
            Logger.debug("Spawned child process #{inspect(pid)} with tag #{inspect(tag)}")

          {:error, reason} ->
            Logger.error("Failed to spawn child: #{inspect(reason)}")

          :ignore ->
            :ok
        end

        {:signals, []}
      end
    }

    case Aikido.Directives.AsyncTask.start(task, input_signal, state) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.error("Failed to start spawn task: #{inspect(reason)}")
    end

    :ok
  end
end
