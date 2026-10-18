defmodule AikidoTest.Memory.SliceTest do
  use ExUnit.Case, async: true

  alias Aikido.Dsl.Agent.Info, as: AgentInfo
  alias Aikido.Dsl.Slice.Info, as: SliceInfo
  alias Aikido.Slices.Memory, as: MemorySlice
  alias Aikido.Slices.Memory.Actions
  alias Aikido.Slices.Memory.State

  describe "slice metadata" do
    test "name is memory" do
      assert Map.get(SliceInfo.slice_options(MemorySlice), :name) == "memory"
    end

    test "path is :memory" do
    end

    test "has memory capability" do
      assert :memory in SliceInfo.capabilities(MemorySlice)
    end

    test "exposes the eight Aikido.Slices.Memory.Actions.* modules via actions/1" do
      action_set = MapSet.new(SliceInfo.actions(MemorySlice))

      assert MapSet.equal?(
               action_set,
               MapSet.new([
                 Actions.Ensure,
                 Actions.PutSpace,
                 Actions.UpdateSpace,
                 Actions.EnsureSpace,
                 Actions.DeleteSpace,
                 Actions.PutInSpace,
                 Actions.DeleteFromSpace,
                 Actions.AppendToSpace
               ])
             )
    end

    test "schema is bound to Aikido.Slices.Memory.State.schema/0" do
      assert Aikido.Schema.keys(SliceInfo.schema(MemorySlice)) == Aikido.Schema.keys(State)
    end

    test "exposes one signal route per action" do
      route_types =
        MemorySlice
        |> SliceInfo.signal_routes()
        |> Enum.map(fn
          {type, _action} -> type
          {type, _action, _opts} -> type
        end)

      assert "aikido.memory.ensure" in route_types
      assert "aikido.memory.put_space" in route_types
      assert "aikido.memory.update_space" in route_types
      assert "aikido.memory.ensure_space" in route_types
      assert "aikido.memory.delete_space" in route_types
      assert "aikido.memory.put_in_space" in route_types
      assert "aikido.memory.delete_from_space" in route_types
      assert "aikido.memory.append_to_space" in route_types
    end
  end

  describe "agent integration" do
    defmodule AgentWithMemory do
      use Aikido.Agent

      agent do
        name "memory_slice_test_agent"
      end
    end

    defmodule AgentWithoutMemory do
      use Aikido.Agent,
        default_slices: %{memory: false}

      agent do
        name "memory_slice_test_no_memory"
      end
    end

    test "agent includes memory slice by default" do
      assert Aikido.Slices.Memory in AgentInfo.slices(AgentWithMemory)
    end

    test "agent can disable memory slice" do
      refute Aikido.Slices.Memory in AgentInfo.slices(AgentWithoutMemory)
    end

    test "memory can be attached after creation via Ensure action" do
      agent = AgentWithMemory.new()
      {:ok, agent, []} = AgentWithMemory.cmd(agent, {Aikido.Slices.Memory.Actions.Ensure, %{}})
      assert %State{} = agent.state[:memory]
    end

    test "PutInSpace action mutates agent.state.memory.spaces[:world]" do
      agent = AgentWithMemory.new()

      {:ok, agent, []} =
        AgentWithMemory.cmd(
          agent,
          {Actions.PutInSpace, %{space: :world, key: :temperature, value: 22}}
        )

      assert agent.state.memory.spaces[:world].data == %{temperature: 22}
    end
  end
end
