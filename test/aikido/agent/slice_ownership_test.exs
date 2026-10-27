defmodule AikidoTest.Agent.SliceOwnershipTest do
  use AikidoTest.Case, async: true

  alias AikidoTest.TestAgents.AuditedWorkflow
  alias AikidoTest.TestSignals.UpdateAudit

  test "one signal updates each slice through its owning action", context do
    pid = start_workflow(context)

    assert {:ok, state} =
             Aikido.AgentServer.call(pid, UpdateAudit.new!(%{}), &{:ok, &1.agent.state})

    assert state.domain == %{primary: "result"}
    assert %AikidoTest.TestAgents.AuditTrail{last_event: :touched} = state.audit
  end

  test "a rejecting slice rolls back the other action's staged update", context do
    pid = start_workflow(context)
    assert {:ok, before_state} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state})

    assert {:error, error} =
             Aikido.AgentServer.call(
               pid,
               UpdateAudit.new!(%{reject?: true}),
               &{:ok, &1.agent.state}
             )

    assert inspect(error) =~ "audit_rejected"
    assert {:ok, ^before_state} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state})
  end

  test "the built-in children query preserves the agent and its mounted slice", context do
    pid = start_workflow(context)
    assert {:ok, before_state} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state})

    assert {:ok, reply} =
             Aikido.Signal.Call.call(pid, Aikido.Ownership.Signals.QueryChildren.new!(%{}))

    assert reply.data == %{children: %{}}
    assert {:ok, ^before_state} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state})
  end

  defp start_workflow(context) do
    start_server(context, AuditedWorkflow,
      initial_state: %{domain: %{primary: "prior"}, audit: %{last_event: :none}}
    )
  end
end
