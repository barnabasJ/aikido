defmodule AikidoTest.Thread.SliceTest.AgentWithThread do
  use Aikido.Agent

  agent do
    name "thread_slice_test_agent"
  end
end

defmodule AikidoTest.Thread.SliceTest.AgentWithoutThread do
  use Aikido.Agent, default_slices: %{thread: false}

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

    test "path is :thread" do
    end

    test "has thread capability" do
      assert :thread in Aikido.Dsl.Slice.Info.capabilities(Aikido.Slices.Thread)
    end

    test "exposes Thread.Actions.{Ensure,Append,Clear} via actions/1" do
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

    test "schema is bound to Aikido.Slices.Thread.schema/0" do
      assert Aikido.Schema.keys(Aikido.Dsl.Slice.Info.schema(Aikido.Slices.Thread)) ==
               Aikido.Schema.keys(Aikido.Slices.Thread)
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

  describe("Persist.Transform implementation") do
    test "externalize/1 strips a Thread struct to a {id, rev} pointer" do
      thread =
        Aikido.Slices.Thread.new(id: "t-1")
        |> Aikido.Slices.Thread.append(%{kind: :message, payload: %{text: "hello"}})

      assert %{id: "t-1", rev: 1} = Aikido.Slices.Thread.externalize(thread)
    end

    test "externalize/1 returns nil for nil input" do
      assert nil == Aikido.Slices.Thread.externalize(nil)
    end

    test "externalize/1 reflects rev count for multi-entry threads" do
      thread =
        Aikido.Slices.Thread.new(id: "t-2")
        |> Aikido.Slices.Thread.append(%{kind: :message, payload: %{text: "one"}})
        |> Aikido.Slices.Thread.append(%{kind: :message, payload: %{text: "two"}})
        |> Aikido.Slices.Thread.append(%{kind: :message, payload: %{text: "three"}})

      assert %{id: "t-2", rev: 3} = Aikido.Slices.Thread.externalize(thread)
    end

    test "reinstate/1 passes through (rehydration is the Persister's job)" do
      pointer = %{id: "t-1", rev: 5}
      assert Aikido.Slices.Thread.reinstate(pointer) == pointer
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
    nil
    nil

    test "agent includes thread slice by default" do
      assert Aikido.Slices.Thread in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Thread.SliceTest.AgentWithThread
             )
    end

    test "agent.state[:thread] starts nil (lazy init)" do
      agent = AikidoTest.Thread.SliceTest.AgentWithThread.new()
      assert Map.get(agent.state, :thread) == nil
    end

    test "agent can disable thread slice" do
      refute Aikido.Slices.Thread in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Thread.SliceTest.AgentWithoutThread
             )
    end

    test "thread can be attached after creation via Ensure action" do
      agent = AikidoTest.Thread.SliceTest.AgentWithThread.new()

      {:ok, agent, []} =
        AikidoTest.Thread.SliceTest.AgentWithThread.cmd(
          agent,
          {{Aikido.Slices.Thread, :ensure}, %{}}
        )

      assert %Aikido.Slices.Thread{} = agent.state[:thread]
    end

    test "Append action mutates agent.state.thread" do
      agent = AikidoTest.Thread.SliceTest.AgentWithThread.new()

      {:ok, agent, []} =
        AikidoTest.Thread.SliceTest.AgentWithThread.cmd(
          agent,
          {{Aikido.Slices.Thread, :append}, %{entry: %{kind: :message, payload: %{text: "hi"}}}}
        )

      assert Aikido.Slices.Thread.entry_count(agent.state.thread) == 1
    end
  end
end
