defmodule AikidoTest.Thread.SliceTest.AgentWithThread do
  use Aikido.Agent

  agent do
    name "thread_slice_test_agent"
    slice :thread, Aikido.Slices.Thread
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
      assert Map.get(Aikido.Dsl.Slice.Info.slice_options(Aikido.Slices.Thread), :name) == "thread"
    end

    test "exposes native thread action references via actions/1" do
      action_set = MapSet.new(Aikido.Dsl.Slice.Info.actions(Aikido.Slices.Thread))

      assert MapSet.equal?(
               action_set,
               MapSet.new([
                 {Aikido.Slices.Thread, :ensure},
                 {Aikido.Slices.Thread, :append},
                 {Aikido.Slices.Thread, :clear}
               ])
             )
    end

    test "exposes one signal route per action" do
      route_types =
        Aikido.Slices.Thread
        |> Aikido.Dsl.Slice.Info.signal_routes()
        |> Enum.map(fn
          {type, _action} -> type
          {type, _action, _opts} -> type
        end)

      assert "aikido.thread.ensure" in route_types
      assert "aikido.thread.append" in route_types
      assert "aikido.thread.clear" in route_types
    end
  end

  test "append accepts native union map and list values" do
    entry = %{kind: :message, payload: %{text: "hello"}}

    for entries <- [entry, [entry, entry]] do
      input =
        Ash.ActionInput.for_action(Aikido.Slices.Thread, :append, %{
          state: Aikido.Slices.Thread.new(),
          entry: entries
        })

      assert %Ash.Union{value: ^entries} = input.arguments.entry
      assert {:ok, result} = Ash.run_action(input)
      assert result.state.rev == length(List.wrap(entries))
    end

    input = Ash.ActionInput.for_action(Aikido.Slices.Thread, :append, %{entry: 42})
    refute input.valid?
  end

  describe("agent integration") do
    test "agent includes its explicitly mounted thread slice" do
      assert Aikido.Slices.Thread in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Thread.SliceTest.AgentWithThread
             )
    end

    test "agent.state[:thread] starts from native resource defaults" do
      agent = AikidoTest.Thread.SliceTest.AgentWithThread.initialize!()
      assert %Aikido.Slices.Thread{} = Map.get(agent.state, :thread)
    end

    test "agent has no thread slice unless mounted" do
      refute Aikido.Slices.Thread in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Thread.SliceTest.AgentWithoutThread
             )
    end

    test "Ensure preserves the mounted thread resource" do
      agent = AikidoTest.Thread.SliceTest.AgentWithThread.initialize!()

      {:ok, %{agent: agent}, []} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Thread.SliceTest.AgentWithThread,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Slices.Thread, :ensure}, %{}}]
        )

      assert %Aikido.Slices.Thread{} = agent.state[:thread]
    end

    test "Append action mutates agent.state.thread" do
      agent = AikidoTest.Thread.SliceTest.AgentWithThread.initialize!()

      {:ok, %{agent: agent}, []} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Thread.SliceTest.AgentWithThread,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Slices.Thread, :append}, %{entry: %{kind: :message, payload: %{text: "hi"}}}}]
        )

      assert Aikido.Slices.Thread.entry_count(agent.state.thread) == 1
    end
  end
end
