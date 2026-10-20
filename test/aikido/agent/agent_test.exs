defmodule AikidoTest.AgentTest.ConfiguredRoutesAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "configured_routes_agent"
    route "configured.route", {AikidoTest.TestActions, :optional_input}
  end
end

defmodule AikidoTest.AgentTest.ExtendingRoutesAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "extending_routes_agent"
    route "base.route", {AikidoTest.TestActions, :optional_input}
    route "extended.route", {AikidoTest.TestActions, :basic_action}
  end
end

defmodule AikidoTest.AgentTest do
  use ExUnit.Case, async: true

  describe("module definition") do
    test "defines metadata accessors via Info" do
      assert Map.get(Aikido.Ash.Agent.Info.agent_options(AikidoTest.TestAgents.Basic), :name) ==
               "basic_agent"

      assert Map.get(
               Aikido.Ash.Agent.Info.agent_options(AikidoTest.TestAgents.Basic),
               :description
             ) == "A basic test agent"
    end

    test "minimal agent has default values" do
      assert Map.get(Aikido.Ash.Agent.Info.agent_options(AikidoTest.TestAgents.Minimal), :name) ==
               "minimal_agent"

      assert Map.get(
               Aikido.Ash.Agent.Info.agent_options(AikidoTest.TestAgents.Minimal),
               :description
             ) == nil

      assert Ash.Resource.Info.action(AikidoTest.TestAgents.Minimal, :initialize, :action)
    end
  end

  describe("signal routes configuration") do
    test "agent route declarations are exposed via Agent.Info.signal_routes/1" do
      routes = Aikido.Ash.Agent.Info.signal_routes(AikidoTest.AgentTest.ConfiguredRoutesAgent)
      assert routes == [{"configured.route", {AikidoTest.TestActions, :optional_input}, 0}]
    end

    test "Agent.Info.signal_routes/1 returns configured routes for agents with multiple routes" do
      routes = Aikido.Ash.Agent.Info.signal_routes(AikidoTest.AgentTest.ExtendingRoutesAgent)
      assert {"base.route", {AikidoTest.TestActions, :optional_input}, 0} in routes
      assert {"extended.route", {AikidoTest.TestActions, :basic_action}, 0} in routes
      assert length(routes) == 2
    end
  end

  describe("initialize/1") do
    test "creates agent with auto-generated id" do
      agent = AikidoTest.TestAgents.Minimal.initialize!()
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "creates agent with custom id" do
      agent = AikidoTest.TestAgents.Minimal.initialize!(%{id: "custom-123"})
      assert agent.id == "custom-123"
    end

    test "generates unique ids for each instance" do
      agent1 = AikidoTest.TestAgents.Minimal.initialize!()
      agent2 = AikidoTest.TestAgents.Minimal.initialize!()
      assert agent1.id != agent2.id
    end

    test "Ash applies the identifier default to nil input" do
      assert {:ok, %{id: id}} = AikidoTest.TestAgents.Minimal.initialize(%{id: nil})
      assert is_binary(id)
    end

    test "creates agent with initial state" do
      agent = AikidoTest.TestAgents.Basic.initialize!(%{state: %{counter: 10}})
      assert agent.state.domain.counter == 10
      assert agent.state.domain.status == :idle
    end

    test "applies schema defaults to state" do
      agent = AikidoTest.TestAgents.Basic.initialize!()
      assert agent.state.domain.counter == 0
      assert agent.state.domain.status == :idle
    end

    test "merges initial state with defaults" do
      agent = AikidoTest.TestAgents.Basic.initialize!(%{state: %{counter: 5}})
      assert agent.state.domain.counter == 5
      assert agent.state.domain.status == :idle
    end

    test "populates agent metadata" do
      agent = AikidoTest.TestAgents.Basic.initialize!()
      assert agent.name == "basic_agent"
      assert agent.description == "A basic test agent"
    end
  end

  describe("native action state transitions") do
    test "executes an explicit native action reference" do
      agent = AikidoTest.TestAgents.Basic.initialize!()

      {:ok, %{agent: updated}, _directives} =
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
              agent_module: AikidoTest.TestAgents.Basic,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{AikidoTest.TestActions, :optional_input}, %{}}]
        )

      assert updated.state.domain.result == "No params"
    end

    test "executes action tuple" do
      agent = AikidoTest.TestAgents.Basic.initialize!()

      {:ok, %{agent: updated}, _directives} =
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
              agent_module: AikidoTest.TestAgents.Basic,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{AikidoTest.TestActions, :basic_action}, %{value: 42}}]
        )

      assert updated.state.domain.value == 42
    end

    test "all-or-nothing batch: every action succeeds; slice reflects the last action" do
      agent = AikidoTest.TestAgents.Basic.initialize!()

      {:ok, %{agent: updated}, directives} =
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
              agent_module: AikidoTest.TestAgents.Basic,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [
            {{AikidoTest.TestActions, :add}, %{value: 5, amount: 3}},
            {{AikidoTest.TestActions, :add}, %{value: 1, amount: 1}}
          ]
        )

      assert updated.state.domain.value == 2
      assert directives == []
    end

    test "all-or-nothing batch: middle action errors halts the batch and returns the input agent unchanged" do
      agent = AikidoTest.TestAgents.Basic.initialize!(%{state: %{counter: 0}})

      assert {:error, _, %Ash.Error.Unknown{}} =
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
                     agent_module: AikidoTest.TestAgents.Basic,
                     agent: agent,
                     agent_id: agent.id
                   })
                 ),
                 [
                   {{AikidoTest.TestActions, :add}, %{value: 5, amount: 3}},
                   {{AikidoTest.TestActions, :failing}, %{reason: "halted"}},
                   {{AikidoTest.TestActions, :add}, %{value: 1, amount: 1}}
                 ]
               )
    end

    test "action error returns {:error, %Aikido.Error{}}" do
      agent = AikidoTest.TestAgents.Basic.initialize!()

      assert {:error, _, %Ash.Error.Invalid{}} =
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
                     agent_module: AikidoTest.TestAgents.Basic,
                     agent: agent,
                     agent_id: agent.id
                   })
                 ),
                 [{{AikidoTest.TestActions, :basic_action}, %{}}]
               )
    end
  end

  describe("actions returning effects") do
    test "action can emit signal via directive" do
      agent = AikidoTest.TestAgents.Basic.initialize!()

      {:ok, %{agent: updated}, directives} =
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
              agent_module: AikidoTest.TestAgents.Basic,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{AikidoTest.TestActions, :emit_action}, %{}}]
        )

      assert updated.state.domain.emitted == true
      assert [%Aikido.Directives.Emit{signal: signal}] = directives
      assert signal.type == "test.emitted"
    end

    test "action can return multiple directives" do
      agent = AikidoTest.TestAgents.Basic.initialize!()

      {:ok, %{agent: updated}, directives} =
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
              agent_module: AikidoTest.TestAgents.Basic,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{AikidoTest.TestActions, :multi_effect_action}, %{}}]
        )

      assert updated.state.domain.triggered == true
      assert length(directives) == 2
      assert [%Aikido.Directives.Emit{}, %Aikido.Directives.Schedule{}] = directives
    end

    test "SliceUpdate writes multiple slices in one action turn" do
      agent =
        AikidoTest.TestAgents.Basic.initialize!(%{
          state: %{domain: %{prior: true}, audit: %{last_event: :none}}
        })

      {:ok, %{agent: updated}, directives} =
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
              agent_module: AikidoTest.TestAgents.Basic,
              agent: agent,
              agent_id: agent.id
            })
          ),
          [{{AikidoTest.TestActions, :multi_slice_action}, %{}}]
        )

      assert updated.state.domain == %{primary: "result"}
      assert updated.state.audit == %{last_event: :touched}
      assert directives == []
    end
  end

  describe("Ash field contract support") do
    test "agent works with Ash field contract" do
      agent = AikidoTest.TestAgents.AshSchema.initialize!()
      assert agent.name == "ash_schema_agent"
    end

    test "initialization casts state through the Ash field contract" do
      agent = AikidoTest.TestAgents.AshSchema.initialize!(%{state: %{status: :running, count: 5}})
      assert agent.state.domain.status == :running
      assert agent.state.domain.count == 5
    end
  end
end
