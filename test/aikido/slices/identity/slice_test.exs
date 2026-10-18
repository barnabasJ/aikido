defmodule AikidoTest.Identity.SliceTest do
  use ExUnit.Case, async: true
  alias Aikido.Dsl.Agent.Info, as: AgentInfo
  alias Aikido.Dsl.Slice.Info, as: SliceInfo
  alias Aikido.Slices.Identity, as: IdentitySlice
  alias Aikido.Slices.Identity.Actions
  alias Aikido.Slices.Identity.State

  describe("slice metadata") do
    test "name is identity" do
      assert Map.get(SliceInfo.slice_options(IdentitySlice), :name) == "identity"
    end

    test "path is :identity" do
    end

    test "has identity capability" do
      assert :identity in SliceInfo.capabilities(IdentitySlice)
    end

    test "exposes Identity.Actions.{Ensure,Evolve,UpdateProfile} via actions/1" do
      action_set = MapSet.new(SliceInfo.actions(IdentitySlice))

      assert MapSet.equal?(
               action_set,
               MapSet.new([
                 {Aikido.Slices.Identity.Actions, :ensure},
                 {Aikido.Slices.Identity.Actions, :evolve},
                 {Aikido.Slices.Identity.Actions, :update_profile}
               ])
             )
    end

    test "schema is bound to Aikido.Slices.Identity.State.schema/0" do
      assert Aikido.Schema.keys(SliceInfo.schema(IdentitySlice)) == Aikido.Schema.keys(State)
    end

    test "exposes one signal route per action" do
      route_types =
        IdentitySlice
        |> SliceInfo.signal_routes()
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
    defmodule AgentWithIdentity do
      use Aikido.Agent

      agent do
        name("identity_slice_test_agent")
      end
    end

    defmodule AgentWithoutIdentity do
      use Aikido.Agent, default_slices: %{identity: false}

      agent do
        name("identity_slice_test_no_identity")
      end
    end

    test "agent includes identity slice by default" do
      assert Aikido.Slices.Identity in AgentInfo.slices(AgentWithIdentity)
    end

    test "agent.state[:identity] starts nil (lazy init)" do
      agent = AgentWithIdentity.new()
      assert Map.get(agent.state, :identity) == nil
    end

    test "agent can disable identity slice" do
      refute Aikido.Slices.Identity in AgentInfo.slices(AgentWithoutIdentity)
    end

    test "identity can be attached after creation via Ensure action" do
      agent = AgentWithIdentity.new()

      {:ok, agent, []} =
        AgentWithIdentity.cmd(agent, {{Aikido.Slices.Identity.Actions, :ensure}, %{}})

      assert %State{} = agent.state[:identity]
    end

    test "UpdateProfile action mutates agent.state.identity" do
      agent = AgentWithIdentity.new()

      {:ok, agent, []} =
        AgentWithIdentity.cmd(
          agent,
          {{Aikido.Slices.Identity.Actions, :update_profile}, %{profile: %{nickname: "Sam"}}}
        )

      assert agent.state.identity.profile[:nickname] == "Sam"
    end
  end
end
