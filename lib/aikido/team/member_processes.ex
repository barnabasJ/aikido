defmodule Aikido.Team.MemberProcesses do
  @moduledoc """
  Starts, stops and looks up the processes backing team members.

  Starts run as individual AsyncTask work units and report results
  through lifecycle signals. PID lookup reads supplied membership without I/O.
  No function changes team or agent state.
  """
  def start_member(resource, id, initial_state, parent, scope) do
    options =
      scope
      |> Ash.Scope.to_opts(context: Map.get(scope, :context) || %{})
      |> attach_parent_options(parent, scope.aikido)

    with {:ok, %{pid: pid}} <-
           resource
           |> Ash.ActionInput.for_action(:start, Map.put(initial_state, :id, id), options)
           |> Ash.run_action(options),
         :ok <- Aikido.AgentServer.await_ready(pid),
         {:ok, ^pid} <- Aikido.AgentServer.await_child(parent.pid, parent.tag) do
      {:ok, pid}
    else
      {:ok, _different_pid} -> {:error, :member_not_attached}
      error -> error
    end
  end

  defp attach_parent_options(options, parent, instance) do
    context =
      options
      |> Keyword.get(:context, %{})
      |> Map.put(:aikido_runtime_options,
        instance: instance,
        parent: parent,
        partition: parent.partition,
        on_parent_death: :stop,
        restart?: false
      )

    Keyword.put(options, :context, context)
  end

  @doc "Look up a live member PID in the supplied team state without performing I/O."
  def fetch_running_member_pid(state, name) do
    case Map.fetch(state.members, name) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        {:error,
         Ash.Error.Action.InvalidArgument.exception(
           field: :member,
           message:
             "Member #{inspect(name)} is not running. Inspect the roster, then use " <>
               "ensure_member to activate an existing member before sending or assigning work."
         )}
    end
  end
end
