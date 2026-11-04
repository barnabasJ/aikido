defmodule Aikido.Team.Actions.Send do
  @moduledoc "Returns one verified delivery to a current member or the coordinator itself."
  use Ash.Resource.Actions.Implementation
  alias Aikido.Team.ActionAdapter
  alias Aikido.Signal

  @impl true
  def run(input, _opts, _context) do
    {signal, state, context, _config} = ActionAdapter.unpack_team_action(input)

    ActionAdapter.to_action_result(
      build_message_delivery(signal.data, state, context),
      state,
      context
    )
  end

  defp build_message_delivery(data, state, context) do
    with {:ok, pid, recipient} <- recipient(data.member, state, context),
         {:ok, requester} <- requester(data[:requester], state, context) do
      signal =
        %Signal{id: nil, type: data.type, data: Map.get(data, :payload, %{}), source: "/ash/team"}

      delivery =
        Aikido.Team.Directives.Deliver.new!(
          signal: signal,
          target: pid,
          recipient: recipient,
          requester: requester,
          kind: :message,
          signal_type: data.type
        )

      {:ok, state, [delivery]}
    end
  end

  defp recipient(:self, _state, context),
    do: {:ok, context.agent_pid, coordinator_reference(context)}

  defp recipient(name, state, context) do
    with {:ok, pid} <- Aikido.Team.MemberProcesses.fetch_running_member_pid(state, name),
         {:ok, spec} <- Map.fetch(state.topology.nodes, name),
         reference = member_reference(name, spec.resource, state, context),
         :ok <- current_recipient(state, name, pid, reference) do
      {:ok, pid, reference}
    else
      :error -> unavailable(name)
      {:error, _} = error -> error
    end
  end

  defp current_recipient(state, name, pid, reference) do
    case get_in(state.operation, [:stop_targets, name]) do
      %{pid: ^pid, reference: captured} ->
        if state.operation.status == :running or captured != reference,
          do: unavailable(name),
          else: :ok

      _ ->
        :ok
    end
  end

  defp requester(name, _state, context) when name in [nil, :self] do
    Aikido.Team.Types.MessageRequester.new(
      member: :self,
      reference: coordinator_reference(context)
    )
  end

  defp requester(name, state, context) do
    with {:ok, _pid, reference} <- recipient(name, state, context),
         {:ok, incarnation} <- Map.fetch(state.incarnations, name) do
      Aikido.Team.Types.MessageRequester.new(
        member: name,
        reference: reference,
        incarnation: incarnation
      )
    else
      :error -> unavailable(name)
      {:error, _} = error -> error
    end
  end

  defp coordinator_reference(context) do
    Aikido.Agent.Reference.new!(
      id: context.agent_id,
      resource: context.agent_module,
      aikido: context.aikido,
      partition: context.partition
    )
  end

  defp member_reference(name, resource, state, context) do
    Aikido.Agent.Reference.new!(
      id: Aikido.Team.Topology.member_id(state.topology, context.agent_id, name),
      resource: resource,
      aikido: context.aikido,
      partition: context.partition
    )
  end

  defp unavailable(name) do
    {:error,
     Ash.Error.Action.InvalidArgument.exception(
       field: :member,
       message:
         "Member #{inspect(name)} is stopping, being replaced or no longer declared. Wait for its native lifecycle operation before sending again."
     )}
  end
end
