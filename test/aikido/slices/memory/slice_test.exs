defmodule AikidoTest.Memory.SliceTest.AgentWithMemory do
  use Aikido.Agent

  agent do
    name "memory_slice_test_agent"
    slice :memory, Aikido.Slices.Memory
  end
end

defmodule AikidoTest.Memory.SliceTest.AgentWithoutMemory do
  use Aikido.Agent

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

  test "replacing a space increments its existing revision and keeps replacement metadata" do
    original = Aikido.Slices.Memory.new(id: "revision-test", now: 0)

    final =
      Enum.reduce(1..2, original, fn count, state ->
        assert {:ok, result} =
                 Aikido.Slices.Memory
                 |> Ash.ActionInput.for_action(:update_space, %{
                   state: state,
                   space: :world,
                   value: %{data: %{count: count}, metadata: %{replacement: count}}
                 })
                 |> Ash.run_action()

        assert result.directives == []
        assert result.state.spaces.world.rev == count
        assert result.state.spaces.world.data == %{count: count}
        assert result.state.spaces.world.metadata == %{replacement: count}
        assert result.state.rev == count
        result.state
      end)

    replacement = Aikido.Slices.Memory.Space.new!(data: %{fresh: true})
    state = %{final | spaces: Map.put(final.spaces, :world, %{final.spaces.world | rev: 5})}
    updated = Aikido.Slices.Memory.update_space(state, :world, fn _ -> replacement end, now: 0)
    assert updated.spaces.world.rev == 6
    assert updated.spaces.world.data == %{fresh: true}

    assert Aikido.Slices.Memory.put_space(state, :world, replacement, now: 0).spaces.world.rev ==
             0

    assert original.spaces.world.rev == 0
    assert original.spaces.world.data == %{}
  end

  test "space arguments use Ash casting and reject invalid space values before execution" do
    for action <- [:put_space, :update_space] do
      input =
        Ash.ActionInput.for_action(Aikido.Slices.Memory, action, %{
          state: Aikido.Slices.Memory.new(now: 0),
          space: :world,
          value: %{data: %{count: 1}}
        })

      assert input.valid?

      assert %Aikido.Slices.Memory.Space{data: %{count: 1}, rev: 0, metadata: %{}} =
               input.arguments.value

      assert {:ok, result} = Ash.run_action(input)
      assert result.state.spaces.world.data == %{count: 1}

      invalid =
        Ash.ActionInput.for_action(Aikido.Slices.Memory, action, %{
          state: Aikido.Slices.Memory.new(now: 0),
          space: :world,
          value: %{rev: -1, metadata: "invalid"}
        })

      refute invalid.valid?
      assert {:error, %Ash.Error.Invalid{}} = Ash.run_action(invalid)
    end
  end

  describe("agent integration") do
    test "agent includes its explicitly mounted memory slice" do
      assert Aikido.Slices.Memory in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Memory.SliceTest.AgentWithMemory
             )
    end

    test "agent has no memory slice unless mounted" do
      refute Aikido.Slices.Memory in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Memory.SliceTest.AgentWithoutMemory
             )
    end

    test "Ensure preserves the mounted memory resource" do
      agent = AikidoTest.Memory.SliceTest.AgentWithMemory.initialize!()

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
              agent_module: AikidoTest.Memory.SliceTest.AgentWithMemory,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Slices.Memory, :ensure}, %{}}]
        )

      assert %Aikido.Slices.Memory{} = agent.state[:memory]
    end

    test "PutInSpace action mutates agent.state.memory.spaces[:world]" do
      agent = AikidoTest.Memory.SliceTest.AgentWithMemory.initialize!()

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
              agent_module: AikidoTest.Memory.SliceTest.AgentWithMemory,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [
            {{Aikido.Slices.Memory, :put_in_space},
             %{space: :world, key: :temperature, value: 22}}
          ]
        )

      assert agent.state.memory.spaces[:world].data == %{temperature: 22}
    end
  end
end
