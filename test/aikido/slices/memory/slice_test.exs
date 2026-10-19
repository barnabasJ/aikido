defmodule AikidoTest.Memory.SliceTest.AgentWithMemory do
  use Aikido.Agent

  agent do
    name "memory_slice_test_agent"
  end
end

defmodule AikidoTest.Memory.SliceTest.AgentWithoutMemory do
  use Aikido.Agent, default_slices: %{memory: false}

  agent do
    name "memory_slice_test_no_memory"
  end
end

defmodule AikidoTest.Memory.SliceTest do
  use ExUnit.Case, async: true

  describe("slice metadata") do
    test "name is memory" do
      assert Map.get(Aikido.Dsl.Slice.Info.slice_options(Aikido.Slices.Memory), :name) == "memory"
    end

    test "exposes the eight Aikido.Slices.Memory.* modules via actions/1" do
      action_set = MapSet.new(Aikido.Dsl.Slice.Info.actions(Aikido.Slices.Memory))

      assert MapSet.equal?(
               action_set,
               MapSet.new([
                 {Aikido.Slices.Memory, :ensure},
                 {Aikido.Slices.Memory, :put_space},
                 {Aikido.Slices.Memory, :update_space},
                 {Aikido.Slices.Memory, :ensure_space},
                 {Aikido.Slices.Memory, :delete_space},
                 {Aikido.Slices.Memory, :put_in_space},
                 {Aikido.Slices.Memory, :delete_from_space},
                 {Aikido.Slices.Memory, :append_to_space}
               ])
             )
    end

    test "schema is bound to Aikido.Slices.Memory.schema/0" do
      assert Ash.Resource.Info.attribute_names(Aikido.Dsl.Slice.Info.schema(Aikido.Slices.Memory)) ==
               Ash.Resource.Info.attribute_names(Aikido.Slices.Memory)
    end

    test "exposes one signal route per action" do
      route_types =
        Aikido.Slices.Memory
        |> Aikido.Dsl.Slice.Info.signal_routes()
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

  test "ensure_space preserves native union map and list defaults" do
    for {default, type} <- [{%{count: 1}, :kv}, {[1, 2], :list}] do
      input =
        Ash.ActionInput.for_action(Aikido.Slices.Memory, :ensure_space, %{
          state: Aikido.Slices.Memory.new(),
          space: :example,
          default: default
        })

      assert %Ash.Union{type: ^type, value: ^default} = input.arguments.default
      assert {:ok, result} = Ash.run_action(input)
      assert result.state.spaces.example.data == default
    end

    input =
      Ash.ActionInput.for_action(Aikido.Slices.Memory, :ensure_space, %{
        state: Aikido.Slices.Memory.new(),
        space: :example
      })

    assert %Ash.Union{type: :kv, value: %{}} = input.arguments.default
    assert {:ok, result} = Ash.run_action(input)
    assert result.state.spaces.example.data == %{}
  end

  describe("agent integration") do
    nil
    nil

    test "agent includes memory slice by default" do
      assert Aikido.Slices.Memory in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Memory.SliceTest.AgentWithMemory
             )
    end

    test "agent can disable memory slice" do
      refute Aikido.Slices.Memory in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Memory.SliceTest.AgentWithoutMemory
             )
    end

    test "memory can be attached after creation via Ensure action" do
      agent = AikidoTest.Memory.SliceTest.AgentWithMemory.initialize!()

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Memory.SliceTest.AgentWithMemory,
          agent,
          {{Aikido.Slices.Memory, :ensure}, %{}}
        )

      assert %Aikido.Slices.Memory{} = agent.state[:memory]
    end

    test "PutInSpace action mutates agent.state.memory.spaces[:world]" do
      agent = AikidoTest.Memory.SliceTest.AgentWithMemory.initialize!()

      {:ok, agent, []} =
        AikidoTest.NativeAction.apply(
          AikidoTest.Memory.SliceTest.AgentWithMemory,
          agent,
          {{Aikido.Slices.Memory, :put_in_space}, %{space: :world, key: :temperature, value: 22}}
        )

      assert agent.state.memory.spaces[:world].data == %{temperature: 22}
    end
  end
end
