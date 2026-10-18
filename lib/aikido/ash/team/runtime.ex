defmodule Aikido.Ash.Team.Runtime do
  @moduledoc false

  # Each function is one AsyncTask unit. No function changes agent state.
  def start_member(resource, id, initial_state, parent) do
    with {:ok, _record} <-
           Aikido.Ash.start(resource, Map.put(initial_state, :id, id),
             context: %{
               aikido_runtime_options: [
                 parent: parent,
                 partition: parent.partition,
                 on_parent_death: :stop,
                 restart: :temporary
               ]
             }
           ),
         pid when is_pid(pid) <-
           Aikido.whereis(Aikido.Ash.Runtime.option(resource, :instance), id) do
      {:ok, pid}
    else
      nil -> {:error, :member_disappeared}
      error -> error
    end
  end

  def stop_member(instance, pid) do
    case Aikido.stop_agent(instance, pid) do
      :ok -> {:ok, :stopped}
      {:error, :not_found} -> {:ok, :stopped}
    end
  end

  def watch_member(pid, team) do
    member_ref = Process.monitor(pid)
    team_ref = Process.monitor(team)

    receive do
      {:DOWN, ^member_ref, :process, ^pid, reason} ->
        Process.demonitor(team_ref, [:flush])
        {:ok, reason}

      {:DOWN, ^team_ref, :process, ^team, _reason} ->
        Process.demonitor(member_ref, [:flush])
        {:signals, []}
    end
  end
end
