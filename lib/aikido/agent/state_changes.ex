defmodule Aikido.Agent.StateChanges do
  @moduledoc """
  Applies reducer changes through a native resource update action.

  Ash owns casting, constraints, validations and embedded-resource lifecycle
  handling. Returned notifications remain unpublished until state adoption.
  """

  @doc "Apply changes to one mounted path and return state with unpublished notifications."
  def apply_changes(agent, path, changes, scope) do
    attributes =
      if path == Aikido.Agent.Info.agent_path!(agent.agent_module) do
        fields = Aikido.Agent.Info.state_fields(agent.agent_module)
        Map.take(changes, fields ++ Enum.map(fields, &Atom.to_string/1))
      else
        %{path => changes}
      end

    with {:ok, record} <- snapshot(agent, scope),
         {:ok, record, notifications} <- update_record(record, attributes, scope) do
      {:ok, %{agent | state: Aikido.Agent.state_from_resource(record)}, notifications}
    end
  end

  defp snapshot(agent, scope) do
    # Snapshot materialization reads the current in-memory record. The actual
    # update retains the reducer's actor, tenant and authorization options.
    options = Keyword.put(scope, :authorize?, false)

    agent.agent_module
    |> Ash.ActionInput.for_action(
      :__aikido_snapshot__,
      %{snapshot: Aikido.Agent.resource_attributes(agent)},
      options
    )
    |> Ash.run_action(options)
  end

  defp update_record(record, attributes, scope) do
    record
    |> Ash.Changeset.for_update(:__aikido_apply_state__, %{changes: attributes}, scope)
    |> Ash.update(Keyword.put(scope, :return_notifications?, true))
  end
end
