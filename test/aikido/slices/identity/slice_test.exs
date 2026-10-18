defmodule AikidoTest.Identity.SliceTest.AgentWithIdentity do
  use Aikido.Agent

  agent do
    name "identity_slice_test_agent"
  end
end

defmodule AikidoTest.Identity.SliceTest.AgentWithoutIdentity do
  use Aikido.Agent, default_slices: %{identity: false}

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

    test "path is :identity" do
    end

    test "has identity capability" do
      assert :identity in Aikido.Dsl.Slice.Info.capabilities(Aikido.Slices.Identity)
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

    test "schema is bound to Aikido.Slices.Identity.schema/0" do
      assert Ash.Resource.Info.attribute_names(
               Aikido.Dsl.Slice.Info.schema(Aikido.Slices.Identity)
             ) ==
               Ash.Resource.Info.attribute_names(Aikido.Slices.Identity)
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
    nil
    nil

    test "agent includes identity slice by default" do
      assert Aikido.Slices.Identity in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Identity.SliceTest.AgentWithIdentity
             )
    end

    test "agent.state[:identity] starts nil (lazy init)" do
      agent = AikidoTest.Identity.SliceTest.AgentWithIdentity.new()
      assert Map.get(agent.state, :identity) == nil
    end

    test "agent can disable identity slice" do
      refute Aikido.Slices.Identity in Aikido.Dsl.Agent.Info.slices(
               AikidoTest.Identity.SliceTest.AgentWithoutIdentity
             )
    end

    test "identity can be attached after creation via Ensure action" do
      agent = AikidoTest.Identity.SliceTest.AgentWithIdentity.new()

      {:ok, agent, []} =
        AikidoTest.Identity.SliceTest.AgentWithIdentity.cmd(
          agent,
          {{Aikido.Slices.Identity, :ensure}, %{}}
        )

      assert %Aikido.Slices.Identity{} = agent.state[:identity]
    end

    test "UpdateProfile action mutates agent.state.identity" do
      agent = AikidoTest.Identity.SliceTest.AgentWithIdentity.new()

      {:ok, agent, []} =
        AikidoTest.Identity.SliceTest.AgentWithIdentity.cmd(
          agent,
          {{Aikido.Slices.Identity, :update_profile}, %{profile: %{nickname: "Sam"}}}
        )

      assert agent.state.identity.profile[:nickname] == "Sam"
    end
  end
end
