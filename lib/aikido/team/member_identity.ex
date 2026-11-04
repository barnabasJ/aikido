defmodule Aikido.Team.MemberIdentity do
  @moduledoc """
  Authorizes a principal to act on behalf of a current Team member.

  The immutable actor and tenant identify authority, not the calling BEAM
  process. Agents intentionally sharing that principal share this authority.
  A member check performs one bounded read of the actual child; a busy child
  fails closed. No scope or authority is copied into Team state.
  """
  alias Aikido.Agent.{CommandRuntime, ExecutionIdentity, Reference}

  @doc "Read the current coordinator, using adopted runtime context for its own policy turn."
  def coordinator(input) do
    case input.context[:aikido] do
      %{agent_pid: pid, agent_module: resource} = context
      when pid == self() and resource == input.resource and pid == input.arguments.agent ->
        {:ok, context}

      _ ->
        CommandRuntime.catch_runtime_exit(fn ->
          with {:ok, {_id, pid}} <- CommandRuntime.resolve(input) do
            Aikido.AgentServer.state(pid, fn runtime ->
              if runtime.agent_module == input.resource do
                {:ok, coordinator_context(runtime, pid)}
              else
                {:error, Ash.Error.Forbidden.exception([])}
              end
            end)
          end
        end)
    end
  end

  @doc "Check the actual member incarnation against the authenticated actor and tenant."
  def matches?(coordinator, requester, scope, timeout_ms) do
    cond do
      is_nil(Aikido.Agent.Info.team_config(coordinator.agent_module)) ->
        {:ok, false}

      requester in [nil, :self] ->
        {:ok, ExecutionIdentity.matches?(coordinator.execution_scope, scope)}

      true ->
        match_member(coordinator, requester, scope, timeout_ms)
    end
  end

  defp match_member(coordinator, requester, scope, timeout_ms) do
    team = coordinator.agent.state[:team]

    with %{members: members, topology: topology} <- team,
         pid when is_pid(pid) and pid != self() <- members[requester],
         %{resource: resource} <- topology.nodes[requester] do
      reference =
        Reference.new!(
          id: Aikido.Team.Topology.member_id(topology, coordinator.agent_id, requester),
          resource: resource,
          aikido: coordinator.aikido,
          partition: coordinator.partition
        )

      CommandRuntime.catch_runtime_exit(fn ->
        with {:ok, ^pid} <- Reference.lookup(reference) do
          Aikido.AgentServer.state(
            pid,
            fn child ->
              {:ok,
               current_member?(child, coordinator, requester, reference) and
                 ExecutionIdentity.matches?(child.bound_execution_scope, scope)}
            end,
            timeout: timeout_ms
          )
        else
          _stopped_or_replaced -> {:ok, false}
        end
      end)
    else
      _not_a_current_member -> {:ok, false}
    end
  end

  defp current_member?(child, coordinator, requester, reference) do
    parent = Aikido.Ownership.parent(child)

    Reference.matches?(reference, %{
      id: child.id,
      resource: child.agent_module,
      aikido: child.aikido,
      partition: child.partition
    }) and
      match?(
        %{
          partition: partition,
          meta: %{
            team_id: team_id,
            team_resource: team_resource,
            team_pid: team_pid,
            member: member
          }
        }
        when team_id == coordinator.agent_id and
               team_resource == coordinator.agent_module and
               team_pid == coordinator.agent_pid and member == requester and
               partition == coordinator.partition,
        parent
      )
  end

  @doc false
  def coordinator_context(runtime, pid) do
    %{
      agent: runtime.agent,
      agent_pid: pid,
      agent_id: runtime.id,
      agent_module: runtime.agent_module,
      aikido: runtime.aikido,
      partition: runtime.partition,
      execution_scope: runtime.bound_execution_scope
    }
  end
end
