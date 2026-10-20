defmodule Aikido.Ash.Team.Runtime do
  @moduledoc false

  # Each function is one AsyncTask unit. No function changes agent state.
  def start_member(resource, id, initial_state, parent, scope) do
    options = Ash.Scope.to_opts(scope)
    context = Keyword.get(options, :context, %{})

    context =
      Map.put(context, :aikido_runtime_options,
        parent: parent,
        partition: parent.partition,
        on_parent_death: :stop,
        restart?: false
      )

    options = Keyword.put(options, :context, context)

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

  def stop_member(instance, pid) do
    case Aikido.Durable.stop(Aikido.durable_supervisor_name(instance), pid) do
      :ok -> {:ok, :stopped}
      {:error, :not_found} -> {:ok, :stopped}
    end
  catch
    :exit, {:noproc, _} -> {:ok, :stopped}
    :exit, {:normal, _} -> {:ok, :stopped}
    :exit, {:shutdown, _} -> {:ok, :stopped}
    :exit, {{:shutdown, _}, _} -> {:ok, :stopped}
  end
end
