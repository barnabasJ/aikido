defmodule AikidoTest.TeamStopScopeTest do
  use AikidoTest.Case, async: false
  alias AikidoTest.TeamStopScope.{Domain, Member}
  alias AikidoTest.LifecycleWait

  @moduletag capture_log: true

  setup do
    options = Keyword.put(durable_options(), :scope_adapter, AikidoTest.DurableScopeAuthority)
    start_supervised!({Aikido, name: Aikido.Default, durable: options})
    :ok
  end

  test "a topology stop uses the member activation scope after current command admission" do
    team = start_team()
    member = Domain.scope_team_inspect!(team).team.members.worker
    {:ok, id} = Aikido.AgentServer.state(member, &{:ok, &1.id})

    assert {:ok, _} =
             Domain.scope_team_stop_member(team, %{member: :worker},
               actor: permitted("member-stopper"),
               tenant: "current-tenant"
             )

    LifecycleWait.await_down(member)

    assert_receive {:signal,
                    %Aikido.Signal{
                      data: %{id: ^id, actor: "starter", tenant: "startup-tenant"}
                    }}

    assert Domain.scope_team_inspect!(team).team.members == %{}
  end

  test "denied member cleanup retains the native policy error and leaves the member alive" do
    team = start_team(%{}, actor: denied())
    member = Domain.scope_team_inspect!(team).team.members.worker

    assert {:error, _} =
             Domain.scope_team_stop_member(team, %{member: :worker},
               actor: permitted("member-stopper")
             )

    assert Process.alive?(member)
    snapshot = Domain.scope_team_inspect!(team)
    assert snapshot.team.operation.status == :failed
    assert %Ash.Error.Forbidden{} = error = snapshot.team.operation.error
    refute Exception.message(error) =~ "CaseClauseError"
    assert snapshot.team.members.worker == member
    assert {:ok, 0} = Aikido.AgentServer.state(member, &{:ok, &1.agent.state.state.cleanups})
    refute_received {:signal, %Aikido.Signal{type: "test.team_stop_scope.cleaned"}}

    assert {:ok, _} = Domain.scope_member_stop(member, actor: permitted("direct-caller"))
    LifecycleWait.await_down(member)
  end

  test "a raw late Started cannot request cleanup of an unrelated running agent" do
    team = start_team(%{topology: %{}})
    member = Domain.scope_member_start!(%{observer: self()}, actor: permitted("starter"))

    signal =
      Aikido.Team.Signals.Started.new!(
        %{member: :late_worker, operation_id: "fabricated", result: member.pid},
        scope: %{actor: permitted("late-cleaner")}
      )

    assert {:error, _} = Aikido.AgentServer.call(team.pid, signal, &{:ok, &1.agent})
    assert Process.alive?(member.pid)
    refute_received {:signal, %Aikido.Signal{type: "test.team_stop_scope.cleaned"}}
    Domain.scope_member_stop!(member, actor: permitted("direct-caller"))
    LifecycleWait.await_down(member.pid)
  end

  test "failed topology startup rolls the root back with the current startup caller's scope" do
    id = unique_id("startup-rollback")

    assert {:error, error} =
             Domain.scope_team_start(failed_topology(id), actor: permitted("rollback-caller"))

    assert startup_cleanup_failure(error) == nil
    assert_receive {:signal, %Aikido.Signal{data: %{id: ^id, actor: "rollback-caller"}}}
    assert :error = Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), id)
  end

  test "failed rollback cleanup retains the stable root identity and both native failure reasons" do
    id = unique_id("denied-startup-rollback")

    assert {:error, error} = Domain.scope_team_start(failed_topology(id), actor: denied())
    details = startup_cleanup_failure(error)
    assert is_map(details), inspect(error, limit: :infinity)
    assert %{agent_id: ^id, startup: {:error, _}, cleanup: %Ash.Error.Forbidden{}} = details

    assert {:ok, pid} = Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), id)
    assert Process.alive?(pid)
    refute_received {:signal, %Aikido.Signal{type: "test.team_stop_scope.cleaned"}}
    assert {:ok, _} = Domain.scope_team_stop(id, actor: permitted("cleanup"))
    LifecycleWait.await_down(pid)
  end

  defp start_team(attributes \\ %{}, options \\ []) do
    team =
      Domain.scope_team_start!(Map.put(attributes, :observer, self()),
        actor: Keyword.get(options, :actor, permitted("starter")),
        tenant: "startup-tenant"
      )

    :ok = Aikido.AgentServer.await_ready(team.pid)
    team
  end

  defp failed_topology(id) do
    %{
      id: id,
      observer: self(),
      topology: %{worker: %{resource: Member, initial_state: %{boot_allowed: false}}}
    }
  end

  defp startup_cleanup_failure(%Aikido.Agent.Errors.StartupCleanupFailed{} = error), do: error

  defp startup_cleanup_failure(%{errors: errors}),
    do: Enum.find_value(errors, &startup_cleanup_failure/1)

  defp startup_cleanup_failure(_error), do: nil

  defp permitted(id), do: %{id: id, can_cleanup: true}
  defp denied, do: %{id: "denied", can_cleanup: false}
end
