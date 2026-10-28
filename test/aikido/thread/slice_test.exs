defmodule AikidoTest.Thread.SliceTest.AgentWithThread do
  use Aikido.Agent

  agent do
    name "thread_slice_test_agent"
    slice :thread, Aikido.Thread.Slice
  end
end

defmodule AikidoTest.Thread.SliceTest.AgentWithoutThread do
  use Aikido.Agent

  agent do
    name "thread_slice_test_no_thread"
  end
end

defmodule AikidoTest.Thread.SliceTest do
  use ExUnit.Case, async: true

  describe("slice metadata") do
    test "name is thread" do
      assert Map.get(Aikido.Slice.Info.slice_options(Aikido.Thread.Slice), :name) == "thread"
    end

    test "exposes native thread action references via actions/1" do
      action_set = MapSet.new(Aikido.Slice.Info.actions(Aikido.Thread.Slice))

      assert MapSet.equal?(
               action_set,
               MapSet.new([
                 {Aikido.Thread.Slice, :append},
                 {Aikido.Thread.Slice, :clear}
               ])
             )
    end

    test "exposes one signal route per action" do
      route_types =
        Aikido.Thread.Slice
        |> Aikido.Slice.Info.signal_routes()
        |> Enum.map(fn
          {type, _action} -> type
          {type, _action, _opts} -> type
        end)

      assert "aikido.thread.append" in route_types
      assert "aikido.thread.clear" in route_types
    end
  end

  test "append accepts native union map and list values" do
    entry = %{kind: :message, payload: %{text: "hello"}}

    for entries <- [entry, [entry, entry]] do
      input =
        Ash.ActionInput.for_action(Aikido.Thread.Slice, :append, %{
          state: Ash.create!(Aikido.Thread.Slice, %{}),
          entry: entries
        })

      assert %Ash.Union{value: ^entries} = input.arguments.entry
      assert {:ok, result} = Ash.run_action(input)
      assert result.changes.rev == length(List.wrap(entries))
    end

    input = Ash.ActionInput.for_action(Aikido.Thread.Slice, :append, %{entry: 42})
    refute input.valid?
  end

  describe("agent integration") do
    test "agent includes its explicitly mounted thread slice" do
      assert Aikido.Thread.Slice in Aikido.Agent.Info.slices(
               AikidoTest.Thread.SliceTest.AgentWithThread
             )
    end

    test "agent.state[:thread] starts from native resource defaults" do
      agent = AikidoTest.Thread.SliceTest.AgentWithThread.initialize!()
      assert %Aikido.Thread.Slice{} = Map.get(agent.state, :thread)
    end

    test "agent has no thread slice unless mounted" do
      refute Aikido.Thread.Slice in Aikido.Agent.Info.slices(
               AikidoTest.Thread.SliceTest.AgentWithoutThread
             )
    end

    test "Append action mutates agent.state.thread" do
      agent = AikidoTest.Thread.SliceTest.AgentWithThread.initialize!()

      {:ok, %{agent: agent}, []} =
        Aikido.AgentServer.apply_actions(
          %Aikido.Signal{id: nil, type: "test.action", data: %{}, source: "/test"},
          Map.merge(
            Aikido.Signal.ctx(%Aikido.Signal{
              id: nil,
              type: "test.action",
              data: %{},
              source: "/test"
            }),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Thread.SliceTest.AgentWithThread,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Thread.Slice, :append}, %{entry: %{kind: :message, payload: %{text: "hi"}}}}]
        )

      assert agent.state.thread.stats.entry_count == 1
    end
  end
end
