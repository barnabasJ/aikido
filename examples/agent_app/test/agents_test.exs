defmodule AgentExamples.AgentsTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true
  alias AgentExamples.Agents

  setup do
    prefix = "test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      for resource <- [
            AgentExamples.Counter,
            AgentExamples.Checklist,
            AgentExamples.Notebook,
            AgentExamples.Worker,
            AgentExamples.Team
          ],
          record <- resource |> Ash.ActionInput.for_action(:list, %{}) |> Ash.run_action!(),
          String.starts_with?(record.id, prefix <> "-") do
        resource
        |> Ash.ActionInput.for_action(:stop, %{agent: record})
        |> Ash.run_action()
      end
    end)

    %{prefix: prefix}
  end

  test "domain arguments cast and reject invalid input before state changes", %{prefix: prefix} do
    counter = snapshot_result(Agents.counter_start!(%{id: prefix <> "-counter"}))
    assert snapshot_result(Agents.counter_add!(counter, %{amount: "7"})).count == 7
    assert {:error, _} = snapshot_result(Agents.counter_add(counter, %{amount: "invalid"}))

    assert [%{count: 7}] = Enum.filter(Agents.counter_list!(), &(&1.id == counter.id))
    assert {:ok, %{status: :stopped}} = Agents.counter_stop(counter)
    assert Enum.filter(Agents.counter_list!(), &(&1.id == counter.id)) == []
  end

  test "checklist business errors preserve the last state", %{prefix: prefix} do
    list = snapshot_result(Agents.checklist_start!(%{id: prefix <> "-checklist"}))
    list = snapshot_result(Agents.checklist_add!(list, %{item: "Ship"}))
    assert {:error, _} = snapshot_result(Agents.checklist_complete(list, %{item: "Missing"}))
    list = snapshot_result(Agents.checklist_complete!(list, %{item: "Ship"}))
    assert list.items == []
    assert list.completed == 1
  end

  test "an embedded slice changes independently of the agent's own state", %{prefix: prefix} do
    notebook =
      snapshot_result(Agents.notebook_start!(%{id: prefix <> "-notebook", title: "Notes"}))

    notebook = snapshot_result(Agents.notebook_append!(notebook, %{text: "First entry"}))
    assert notebook.title == "Notes"
    assert notebook.journal.entries == ["First entry"]
    assert {:error, _} = snapshot_result(Agents.notebook_append(notebook, %{text: nil}))
  end

  test "an async result enters the receiving action through a signal", %{prefix: prefix} do
    worker = snapshot_result(Agents.worker_start!(%{id: prefix <> "-worker"}))

    pid =
      case Aikido.Durable.lookup(Aikido.durable_supervisor_name(Aikido.Default), worker.id) do
        {:ok, pid} -> pid
        :error -> nil
      end

    {:ok, reference} =
      Aikido.AgentServer.subscribe(pid, "worker.completed", &{:ok, &1.agent.state.state},
        once: true
      )

    assert {:ok, _} = snapshot_result(Agents.worker_run(worker, %{text: "hello"}))

    assert_receive {:aikido_subscription, ^reference,
                    %{result: {:ok, %{status: :completed, result: "HELLO"}}}},
                   5_000
  end

  test "teams deliver signals and stop their child processes", %{prefix: prefix} do
    team = snapshot_result(Agents.team_start!(%{id: prefix <> "-team"}))
    counter = team.team.members.counter
    members = Map.values(team.team.members)

    {:ok, reference} =
      Aikido.AgentServer.subscribe(counter, "counter.add", &{:ok, &1.agent.state.state.count},
        once: true
      )

    assert {:ok, _} =
             snapshot_result(
               Agents.team_send(team, %{
                 data: %{member: :counter, type: "counter.add", payload: %{amount: 2}}
               })
             )

    assert_receive {:aikido_subscription, ^reference, %{result: {:ok, 12}}}, 5_000
    monitors = Enum.map(members, &{&1, Process.monitor(&1)})
    assert {:ok, %{status: :stopped}} = Agents.team_stop(team)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end
  end

  # Commands return receipts; state assertions opt into a separate inspection.
  defp snapshot_result({:ok, %{resource: resource, id: id}}),
    do: resource |> Ash.ActionInput.for_action(:inspect, %{agent: id}) |> Ash.run_action()

  defp snapshot_result({:error, _} = error), do: error

  defp snapshot_result(%{resource: resource, id: id}),
    do: resource |> Ash.ActionInput.for_action(:inspect, %{agent: id}) |> Ash.run_action!()
end
