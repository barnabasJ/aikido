defmodule AikidoTest.Identity.SliceTest.AgentWithIdentity do
  use Aikido.Agent

  agent do
    name "identity_slice_test_agent"
    slice :identity, Aikido.Slices.Identity
  end
end

defmodule AikidoTest.Identity.SliceTest.AgentWithoutIdentity do
  use Aikido.Agent

  agent do
    name "identity_slice_test_no_identity"
  end
end

defmodule AikidoTest.Identity.SliceTest do
  use ExUnit.Case, async: true

  describe("slice metadata") do
    test "name is identity" do
      assert Map.get(Aikido.Dsl.Slice.Info.slice_options(Aikido.Slices.Identity), :name) ==
               "identity"
    end

    test "exposes Identity.Actions.{Ensure,Evolve,UpdateProfile} via actions/1" do
      action_set = MapSet.new(Aikido.Dsl.Slice.Info.actions(Aikido.Slices.Identity))

      assert MapSet.equal?(
               action_set,
               MapSet.new([
                 {Aikido.Slices.Identity, :ensure},
                 {Aikido.Slices.Identity, :evolve},
                 {Aikido.Slices.Identity, :update_profile}
               ])
             )
    end

    test "exposes one signal route per action" do
      route_types =
        Aikido.Slices.Identity
        |> Aikido.Dsl.Slice.Info.signal_routes()
        |> Enum.map(fn
          {type, _action} -> type
          {type, _action, _opts} -> type
        end)

      assert "aikido.identity.ensure" in route_types
      assert "aikido.identity.evolve" in route_types
      assert "aikido.identity.update_profile" in route_types
    end
  end

  describe("agent integration") do
    test "agent includes its explicitly mounted identity slice" do
      assert Aikido.Slices.Identity in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Identity.SliceTest.AgentWithIdentity
             )
    end

    test "agent.state[:identity] starts from native resource defaults" do
      agent = AikidoTest.Identity.SliceTest.AgentWithIdentity.initialize!()
      assert %Aikido.Slices.Identity{} = Map.get(agent.state, :identity)
    end

    test "agent has no identity slice unless mounted" do
      refute Aikido.Slices.Identity in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Identity.SliceTest.AgentWithoutIdentity
             )
    end

    test "Ensure preserves the mounted identity resource" do
      agent = AikidoTest.Identity.SliceTest.AgentWithIdentity.initialize!()

      {:ok, %{agent: agent}, []} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Identity.SliceTest.AgentWithIdentity,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Slices.Identity, :ensure}, %{}}]
        )

      assert %Aikido.Slices.Identity{} = agent.state[:identity]
    end

    test "UpdateProfile action mutates agent.state.identity" do
      agent = AikidoTest.Identity.SliceTest.AgentWithIdentity.initialize!()

      {:ok, %{agent: agent}, []} =
        Aikido.AgentServer.apply_actions(
          struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test"),
          Map.merge(
            Aikido.SignalCtx.ctx(
              struct!(Jido.Signal, id: nil, type: "test.action", data: %{}, source: "/test")
            ),
            Map.merge(%{}, %{
              agent_module: AikidoTest.Identity.SliceTest.AgentWithIdentity,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{Aikido.Slices.Identity, :update_profile}, %{profile: %{nickname: "Sam"}}}]
        )

      assert agent.state.identity.profile[:nickname] == "Sam"
    end
  end
end
