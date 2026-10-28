defmodule AikidoTest.Memory.SliceTest.AgentWithMemory do
  use Aikido.Agent

  agent do
    name "memory_slice_test_agent"
    slice :memory, Aikido.Memory.Slice
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
      assert Map.get(Aikido.Slice.Info.slice_options(Aikido.Memory.Slice), :name) == "memory"
    end

    test "exposes seven native Memory action references via actions/1" do
      action_set = MapSet.new(Aikido.Slice.Info.actions(Aikido.Memory.Slice))

      assert MapSet.equal?(
               action_set,
               MapSet.new([
                 {Aikido.Memory.Slice, :put_space},
                 {Aikido.Memory.Slice, :update_space},
                 {Aikido.Memory.Slice, :ensure_space},
                 {Aikido.Memory.Slice, :delete_space},
                 {Aikido.Memory.Slice, :put_in_space},
                 {Aikido.Memory.Slice, :delete_from_space},
                 {Aikido.Memory.Slice, :append_to_space}
               ])
             )
    end

    test "exposes one signal route per action" do
      route_types =
        Aikido.Memory.Slice
        |> Aikido.Slice.Info.signal_routes()
        |> Enum.map(fn
          {type, _action} -> type
          {type, _action, _opts} -> type
        end)

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
        Ash.ActionInput.for_action(Aikido.Memory.Slice, :ensure_space, %{
          state: Ash.create!(Aikido.Memory.Slice, %{}),
          space: :example,
          default: default
        })

      assert %Ash.Union{type: ^type, value: ^default} = input.arguments.default
      assert {:ok, result} = Ash.run_action(input)
      assert result.changes.spaces.example.data == default
    end

    input =
      Ash.ActionInput.for_action(Aikido.Memory.Slice, :ensure_space, %{
        state: Ash.create!(Aikido.Memory.Slice, %{}),
        space: :example
      })

    assert %Ash.Union{type: :kv, value: %{}} = input.arguments.default
    assert {:ok, result} = Ash.run_action(input)
    assert result.changes.spaces.example.data == %{}
  end

  test "replacing a space increments its existing revision and keeps replacement metadata" do
    original = Ash.create!(Aikido.Memory.Slice, %{id: "revision-test"})

    final =
      Enum.reduce(1..2, original, fn count, state ->
        assert {:ok, result} =
                 Aikido.Memory.Slice
                 |> Ash.ActionInput.for_action(:update_space, %{
                   state: state,
                   space: :world,
                   value: %{data: %{count: count}, metadata: %{replacement: count}}
                 })
                 |> Ash.run_action()

        assert result.directives == []
        assert result.changes.spaces.world.rev == count
        assert result.changes.spaces.world.data == %{count: count}
        assert result.changes.spaces.world.metadata == %{replacement: count}
        assert result.changes.rev == count
        Ash.update!(state, result.changes, action: :update)
      end)

    replacement = Aikido.Memory.Types.Space.new!(data: %{fresh: true})

    world =
      Aikido.Memory.Types.Space.new!(
        data: final.spaces.world.data,
        metadata: final.spaces.world.metadata,
        rev: 5
      )

    state = Ash.update!(final, %{spaces: Map.put(final.spaces, :world, world)}, action: :update)

    updated =
      Aikido.Memory.Slice
      |> Ash.ActionInput.for_action(:update_space, %{
        state: state,
        space: :world,
        value: replacement
      })
      |> Ash.run_action!()
      |> Map.fetch!(:changes)

    assert updated.spaces.world.rev == 6
    assert updated.spaces.world.data == %{fresh: true}

    replaced =
      Aikido.Memory.Slice
      |> Ash.ActionInput.for_action(:put_space, %{state: state, space: :world, value: replacement})
      |> Ash.run_action!()

    assert replaced.changes.spaces.world.rev == 0

    assert original.spaces.world.rev == 0
    assert original.spaces.world.data == %{}
  end

  test "space arguments use Ash casting and reject invalid space values before execution" do
    for action <- [:put_space, :update_space] do
      input =
        Ash.ActionInput.for_action(Aikido.Memory.Slice, action, %{
          state: Ash.create!(Aikido.Memory.Slice, %{}),
          space: :world,
          value: %{data: %{count: 1}}
        })

      assert input.valid?

      assert %Aikido.Memory.Types.Space{data: %{count: 1}, rev: 0, metadata: %{}} =
               input.arguments.value

      assert {:ok, result} = Ash.run_action(input)
      assert result.changes.spaces.world.data == %{count: 1}

      invalid =
        Ash.ActionInput.for_action(Aikido.Memory.Slice, action, %{
          state: Ash.create!(Aikido.Memory.Slice, %{}),
          space: :world,
          value: %{rev: -1, metadata: "invalid"}
        })

      refute invalid.valid?
      assert {:error, %Ash.Error.Invalid{}} = Ash.run_action(invalid)
    end
  end

  describe("agent integration") do
    test "agent includes its explicitly mounted memory slice" do
      assert Aikido.Memory.Slice in Aikido.Agent.Info.slices(
               AikidoTest.Memory.SliceTest.AgentWithMemory
             )
    end

    test "agent has no memory slice unless mounted" do
      refute Aikido.Memory.Slice in Aikido.Agent.Info.slices(
               AikidoTest.Memory.SliceTest.AgentWithoutMemory
             )
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
            {{Aikido.Memory.Slice, :put_in_space}, %{space: :world, key: :temperature, value: 22}}
          ]
        )

      assert agent.state.memory.spaces[:world].data == %{temperature: 22}
    end
  end
end
