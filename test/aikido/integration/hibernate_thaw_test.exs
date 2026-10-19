defmodule AikidoTest.Integration.HibernateThawTest.WorkflowAgent do
  use Aikido.Agent

  agent do
    name "workflow_agent"
    path :domain

    schema do
      attribute :step, :integer, default: 0
      attribute :status, :atom, default: :pending
      attribute :data, :map, default: %{}
    end
  end
end

defmodule AikidoTest.Integration.HibernateThawTest do
  use ExUnit.Case, async: true

  defp unique_table do
    :"hibernate_thaw_test_#{System.unique_integer([:positive])}"
  end

  defp create_aikido_instance(table) do
    %{storage: {Aikido.Storage.ETS, table: table}}
  end

  describe("basic round-trip: create agent → hibernate → thaw → verify") do
    test "agent id is preserved after hibernate/thaw" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{
          id: "basic-roundtrip-1"
        })

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "basic-roundtrip-1"
        )

      assert thawed.id == "basic-roundtrip-1"
    end

    test "agent module metadata is preserved" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{
          id: "basic-roundtrip-2"
        })

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "basic-roundtrip-2"
        )

      assert thawed.__struct__ == Aikido.Agent
      assert thawed.agent_module == AikidoTest.Integration.HibernateThawTest.WorkflowAgent
    end

    test "default state values are preserved" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{
          id: "basic-roundtrip-3"
        })

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "basic-roundtrip-3"
        )

      assert thawed.state.domain.step == 0
      assert thawed.state.domain.status == :pending
      assert thawed.state.domain.data == %{}
    end
  end

  describe(
    "with thread: create agent → attach thread → add entries → hibernate → thaw → verify"
  ) do
    test "thread is restored with correct id" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "thread-test-1"})

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :ensure}, %{id: "thread-for-agent-1"}}
        )

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :append},
           %{entry: %{kind: :message, payload: %{content: "hello"}}}}
        )

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "thread-test-1"
        )

      assert thawed.state[:thread] != nil
      assert thawed.state[:thread].id == "thread-for-agent-1"
    end

    test "thread rev matches entry count" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "thread-test-2"})

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :ensure}, %{id: "thread-rev-test"}}
        )

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :append},
           %{
             entry: [
               %{kind: :message, payload: %{content: "one"}},
               %{kind: :message, payload: %{content: "two"}},
               %{kind: :message, payload: %{content: "three"}}
             ]
           }}
        )

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "thread-test-2"
        )

      rehydrated = thawed.state[:thread]
      assert rehydrated.rev == 3
      assert Aikido.Slices.Thread.entry_count(rehydrated) == 3
    end

    test "entry seq numbers are correct and ordered" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "thread-test-3"})

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :ensure}, %{id: "seq-test-thread"}}
        )

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :append},
           %{
             entry: [
               %{kind: :user_message, payload: %{role: "user", content: "query"}},
               %{kind: :tool_call, payload: %{name: "search", args: %{q: "test"}}},
               %{kind: :tool_result, payload: %{result: "found 5 results"}},
               %{kind: :assistant_message, payload: %{role: "assistant", content: "response"}}
             ]
           }}
        )

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "thread-test-3"
        )

      rehydrated = thawed.state[:thread]
      entry_list = Aikido.Slices.Thread.to_list(rehydrated)
      assert length(entry_list) == 4
      assert Enum.at(entry_list, 0).seq == 0
      assert Enum.at(entry_list, 1).seq == 1
      assert Enum.at(entry_list, 2).seq == 2
      assert Enum.at(entry_list, 3).seq == 3
    end

    test "entry payloads are preserved" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "thread-test-4"})

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :ensure}, %{id: "payload-test-thread"}}
        )

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :append},
           %{entry: %{kind: :message, payload: %{complex: %{nested: "data"}, list: [1, 2, 3]}}}}
        )

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "thread-test-4"
        )

      rehydrated = thawed.state[:thread]
      [entry] = Aikido.Slices.Thread.to_list(rehydrated)
      assert entry.payload.complex == %{nested: "data"}
      assert entry.payload.list == [1, 2, 3]
    end
  end

  describe("state mutations: create → modify state → hibernate → thaw → verify state") do
    test "modified step value is preserved" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "state-mut-1"})

      agent = %{agent | state: %{agent.state | domain: %{agent.state.domain | step: 5}}}
      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "state-mut-1"
        )

      assert thawed.state.domain.step == 5
    end

    test "modified status value is preserved" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "state-mut-2"})

      agent = %{
        agent
        | state: %{agent.state | domain: %{agent.state.domain | status: :completed}}
      }

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "state-mut-2"
        )

      assert thawed.state.domain.status == :completed
    end

    test "modified data map is preserved" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "state-mut-3"})

      agent = %{
        agent
        | state: %{
            agent.state
            | domain: %{agent.state.domain | data: %{user_id: "u123", items: ["a", "b", "c"]}}
          }
      }

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "state-mut-3"
        )

      assert thawed.state.domain.data == %{user_id: "u123", items: ["a", "b", "c"]}
    end

    test "all state fields are preserved together" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "state-mut-4"})

      agent = %{
        agent
        | state: %{
            agent.state
            | domain: %{
                agent.state.domain
                | step: 10,
                  status: :in_progress,
                  data: %{key: "value", count: 42}
              }
          }
      }

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "state-mut-4"
        )

      assert thawed.state.domain.step == 10
      assert thawed.state.domain.status == :in_progress
      assert thawed.state.domain.data == %{key: "value", count: 42}
    end
  end

  describe("multiple agents: hibernate/thaw multiple agents with different IDs") do
    test "multiple agents can be hibernated and thawed independently" do
      aikido = create_aikido_instance(unique_table())

      agent1 =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "multi-agent-1"})

      agent1 = %{
        agent1
        | state: %{agent1.state | domain: %{agent1.state.domain | step: 1, status: :first}}
      }

      agent2 =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "multi-agent-2"})

      agent2 = %{
        agent2
        | state: %{agent2.state | domain: %{agent2.state.domain | step: 2, status: :second}}
      }

      agent3 =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "multi-agent-3"})

      agent3 = %{
        agent3
        | state: %{agent3.state | domain: %{agent3.state.domain | step: 3, status: :third}}
      }

      :ok = Aikido.Persist.hibernate(aikido, agent1)
      :ok = Aikido.Persist.hibernate(aikido, agent2)
      :ok = Aikido.Persist.hibernate(aikido, agent3)

      {:ok, thawed1} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "multi-agent-1"
        )

      {:ok, thawed2} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "multi-agent-2"
        )

      {:ok, thawed3} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "multi-agent-3"
        )

      assert thawed1.id == "multi-agent-1"
      assert thawed1.state.domain.step == 1
      assert thawed1.state.domain.status == :first
      assert thawed2.id == "multi-agent-2"
      assert thawed2.state.domain.step == 2
      assert thawed2.state.domain.status == :second
      assert thawed3.id == "multi-agent-3"
      assert thawed3.state.domain.step == 3
      assert thawed3.state.domain.status == :third
    end

    test "multiple agents with threads can be hibernated and thawed independently" do
      aikido = create_aikido_instance(unique_table())

      agent1 =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{
          id: "multi-thread-1"
        })

      {:ok, agent1, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent1,
          {{Aikido.Slices.Thread, :ensure}, %{id: "thread-multi-1"}}
        )

      {:ok, agent1, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent1,
          {{Aikido.Slices.Thread, :append}, %{entry: %{kind: :note, payload: %{text: "agent1"}}}}
        )

      agent2 =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{
          id: "multi-thread-2"
        })

      {:ok, agent2, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent2,
          {{Aikido.Slices.Thread, :ensure}, %{id: "thread-multi-2"}}
        )

      {:ok, agent2, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent2,
          {{Aikido.Slices.Thread, :append}, %{entry: %{kind: :note, payload: %{text: "agent2"}}}}
        )

      :ok = Aikido.Persist.hibernate(aikido, agent1)
      :ok = Aikido.Persist.hibernate(aikido, agent2)

      {:ok, thawed1} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "multi-thread-1"
        )

      {:ok, thawed2} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "multi-thread-2"
        )

      assert thawed1.state[:thread].id == "thread-multi-1"
      assert thawed2.state[:thread].id == "thread-multi-2"
      [entry1] = Aikido.Slices.Thread.to_list(thawed1.state[:thread])
      [entry2] = Aikido.Slices.Thread.to_list(thawed2.state[:thread])
      assert entry1.payload.text == "agent1"
      assert entry2.payload.text == "agent2"
    end

    test "thawing nonexistent agent returns {:error, :not_found}" do
      aikido = create_aikido_instance(unique_table())
      agent = AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "exists"})
      :ok = Aikido.Persist.hibernate(aikido, agent)

      assert {:error, :not_found} =
               Aikido.Persist.thaw(
                 aikido,
                 AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
                 "does-not-exist"
               )
    end
  end

  describe(
    "overwrite checkpoint: hibernate → modify → hibernate again → thaw → verify latest state"
  ) do
    test "second hibernate overwrites first checkpoint" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "overwrite-1"})

      agent_v1 = %{
        agent
        | state: %{agent.state | domain: %{agent.state.domain | step: 1, status: :version1}}
      }

      :ok = Aikido.Persist.hibernate(aikido, agent_v1)

      agent_v2 = %{
        agent
        | state: %{agent.state | domain: %{agent.state.domain | step: 2, status: :version2}}
      }

      :ok = Aikido.Persist.hibernate(aikido, agent_v2)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "overwrite-1"
        )

      assert thawed.state.domain.step == 2
      assert thawed.state.domain.status == :version2
    end

    test "thaw → modify → hibernate → thaw preserves modifications" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "overwrite-2"})

      agent = %{agent | state: %{agent.state | domain: %{agent.state.domain | step: 1}}}
      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed1} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "overwrite-2"
        )

      assert thawed1.state.domain.step == 1

      updated = %{
        thawed1
        | state: %{thawed1.state | domain: %{thawed1.state.domain | step: 99, status: :final}}
      }

      :ok = Aikido.Persist.hibernate(aikido, updated)

      {:ok, thawed2} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "overwrite-2"
        )

      assert thawed2.state.domain.step == 99
      assert thawed2.state.domain.status == :final
    end

    test "thread updates are preserved on re-hibernate" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "overwrite-3"})

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :ensure}, %{id: "overwrite-thread"}}
        )

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :append},
           %{entry: %{kind: :message, payload: %{content: "first"}}}}
        )

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed1} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "overwrite-3"
        )

      assert Aikido.Slices.Thread.entry_count(thawed1.state[:thread]) == 1

      {:ok, updated, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          thawed1,
          {{Aikido.Slices.Thread, :append},
           %{
             entry: [
               %{kind: :message, payload: %{content: "new first"}},
               %{kind: :message, payload: %{content: "new second"}}
             ]
           }}
        )

      :ok = Aikido.Persist.hibernate(aikido, updated)

      {:ok, thawed2} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "overwrite-3"
        )

      assert thawed2.state[:thread].id == "overwrite-thread"
      assert Aikido.Slices.Thread.entry_count(thawed2.state[:thread]) == 3
      assert thawed2.state[:thread].rev == 3
    end
  end

  describe("integration invariants") do
    test "checkpoint never contains full Thread struct, only pointer" do
      table = unique_table()
      aikido = create_aikido_instance(table)

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "invariant-1"})

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :ensure}, %{id: "invariant-thread"}}
        )

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :append},
           %{entry: %{kind: :message, payload: %{content: "test"}}}}
        )

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, checkpoint} =
        Aikido.Storage.ETS.get_checkpoint(
          {AikidoTest.Integration.HibernateThawTest.WorkflowAgent, "invariant-1"},
          table: table
        )

      refute is_struct(checkpoint.thread, Aikido.Slices.Thread)
      assert checkpoint.thread == %{id: "invariant-thread", rev: 1}
      refute Map.has_key?(checkpoint.state, :thread)
    end

    test "agent.id is preserved exactly" do
      aikido = create_aikido_instance(unique_table())
      original_id = "exact-id-preservation-test-#{System.unique_integer([:positive])}"

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: original_id})

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          original_id
        )

      assert thawed.id == original_id
    end

    test "thread entries preserve kind field" do
      aikido = create_aikido_instance(unique_table())

      agent =
        AikidoTest.Integration.HibernateThawTest.WorkflowAgent.initialize!(%{id: "kind-test"})

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :ensure}, %{id: "kind-test-thread"}}
        )

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          agent,
          {{Aikido.Slices.Thread, :append},
           %{
             entry: [
               %{kind: :user_input, payload: %{}},
               %{kind: :system_response, payload: %{}},
               %{kind: :tool_call, payload: %{}}
             ]
           }}
        )

      :ok = Aikido.Persist.hibernate(aikido, agent)

      {:ok, thawed} =
        Aikido.Persist.thaw(
          aikido,
          AikidoTest.Integration.HibernateThawTest.WorkflowAgent,
          "kind-test"
        )

      entries = Aikido.Slices.Thread.to_list(thawed.state[:thread])
      assert Enum.at(entries, 0).kind == :user_input
      assert Enum.at(entries, 1).kind == :system_response
      assert Enum.at(entries, 2).kind == :tool_call
    end
  end
end
