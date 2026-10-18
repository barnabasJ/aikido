defmodule AikidoTest.AgentTest.ConfiguredRoutesAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "configured_routes_agent"
  end

  signal_routes do
    route "configured.route", AikidoTest.TestActions.NoSchema
  end
end

defmodule AikidoTest.AgentTest.ExtendingRoutesAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "extending_routes_agent"
  end

  signal_routes do
    route "base.route", AikidoTest.TestActions.NoSchema
    route "extended.route", AikidoTest.TestActions.BasicAction
  end
end

defmodule AikidoTest.AgentTest do
  use ExUnit.Case, async: true

  describe("module definition") do
    test "defines metadata accessors via Info" do
      assert Map.get(Aikido.Dsl.Agent.Info.agent_options(AikidoTest.TestAgents.Basic), :name) ==
               "basic_agent"

      assert Map.get(
               Aikido.Dsl.Agent.Info.agent_options(AikidoTest.TestAgents.Basic),
               :description
             ) == "A basic test agent"

      assert Map.get(Aikido.Dsl.Agent.Info.agent_options(AikidoTest.TestAgents.Basic), :category) ==
               "test"

      assert Map.get(Aikido.Dsl.Agent.Info.agent_options(AikidoTest.TestAgents.Basic), :tags) == [
               "test",
               "basic"
             ]

      assert Map.get(Aikido.Dsl.Agent.Info.agent_options(AikidoTest.TestAgents.Basic), :vsn) ==
               "1.0.0"
    end

    test "minimal agent has default values" do
      assert Map.get(Aikido.Dsl.Agent.Info.agent_options(AikidoTest.TestAgents.Minimal), :name) ==
               "minimal_agent"

      assert Map.get(
               Aikido.Dsl.Agent.Info.agent_options(AikidoTest.TestAgents.Minimal),
               :description
             ) == nil

      schema = Aikido.Dsl.Agent.Info.schema(AikidoTest.TestAgents.Minimal)
      assert Keyword.keyword?(schema)
    end
  end

  describe("signal routes configuration") do
    test "agent's signal_routes section is exposed via Agent.Info.signal_routes/1" do
      routes = Aikido.Dsl.Agent.Info.signal_routes(AikidoTest.AgentTest.ConfiguredRoutesAgent)
      assert routes == [{"configured.route", AikidoTest.TestActions.NoSchema}]
    end

    test "Agent.Info.signal_routes/1 returns configured routes for agents with multiple routes" do
      routes = Aikido.Dsl.Agent.Info.signal_routes(AikidoTest.AgentTest.ExtendingRoutesAgent)
      assert {"base.route", AikidoTest.TestActions.NoSchema} in routes
      assert {"extended.route", AikidoTest.TestActions.BasicAction} in routes
      assert length(routes) == 2
    end
  end

  describe("new/1") do
    test "creates agent with auto-generated id" do
      agent = AikidoTest.TestAgents.Minimal.new()
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "creates agent with custom id" do
      agent = AikidoTest.TestAgents.Minimal.new(id: "custom-123")
      assert agent.id == "custom-123"
    end

    test "generates unique ids for each instance" do
      agent1 = AikidoTest.TestAgents.Minimal.new()
      agent2 = AikidoTest.TestAgents.Minimal.new()
      assert agent1.id != agent2.id
    end

    test "generates id when nil is passed" do
      agent = AikidoTest.TestAgents.Minimal.new(id: nil)
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "generates id when empty string is passed" do
      agent = AikidoTest.TestAgents.Minimal.new(id: "")
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "creates agent with initial state" do
      agent = AikidoTest.TestAgents.Basic.new(state: %{counter: 10})
      assert agent.state.domain.counter == 10
      assert agent.state.domain.status == :idle
    end

    test "applies schema defaults to state" do
      agent = AikidoTest.TestAgents.Basic.new()
      assert agent.state.domain.counter == 0
      assert agent.state.domain.status == :idle
    end

    test "merges initial state with defaults" do
      agent = AikidoTest.TestAgents.Basic.new(state: %{counter: 5})
      assert agent.state.domain.counter == 5
      assert agent.state.domain.status == :idle
    end

    test "populates agent metadata" do
      agent = AikidoTest.TestAgents.Basic.new()
      assert agent.name == "basic_agent"
      assert agent.description == "A basic test agent"
      assert agent.category == "test"
      assert agent.tags == ["test", "basic"]
      assert agent.vsn == "1.0.0"
    end
  end

  describe("set/2") do
    test "updates state with map" do
      agent = AikidoTest.TestAgents.Basic.new()
      {:ok, updated} = AikidoTest.TestAgents.Basic.set(agent, %{counter: 42})
      assert updated.state.domain.counter == 42
    end

    test "updates state with keyword list" do
      agent = AikidoTest.TestAgents.Basic.new()
      {:ok, updated} = AikidoTest.TestAgents.Basic.set(agent, counter: 42, status: :running)
      assert updated.state.domain.counter == 42
      assert updated.state.domain.status == :running
    end

    test "deep merges nested maps" do
      agent = AikidoTest.TestAgents.Basic.new(state: %{config: %{a: 1, b: 2}})
      {:ok, updated} = AikidoTest.TestAgents.Basic.set(agent, %{config: %{b: 3, c: 4}})
      assert updated.state.domain.config == %{a: 1, b: 3, c: 4}
    end
  end

  describe("validate/2") do
    test "validates state against schema" do
      agent = AikidoTest.TestAgents.Basic.new()
      {:ok, validated} = AikidoTest.TestAgents.Basic.validate(agent)
      assert validated.state.domain.counter == 0
      assert validated.state.domain.status == :idle
    end

    test "preserves extra fields in non-strict mode" do
      agent = AikidoTest.TestAgents.Basic.new(state: %{counter: 0, extra_field: "hello"})
      {:ok, validated} = AikidoTest.TestAgents.Basic.validate(agent)
      assert validated.state.domain.extra_field == "hello"
    end

    test "strict mode only keeps schema fields" do
      agent =
        AikidoTest.TestAgents.Basic.new(state: %{counter: 0, status: :idle, extra_field: "hello"})

      {:ok, validated} = AikidoTest.TestAgents.Basic.validate(agent, strict: true)
      refute Map.has_key?(Map.get(validated.state, :domain, %{}), :extra_field)
      refute Map.has_key?(validated.state, :extra_field)
    end
  end

  describe("cmd/2") do
    test "executes action module" do
      agent = AikidoTest.TestAgents.Basic.new()

      {:ok, updated, _directives} =
        AikidoTest.TestAgents.Basic.cmd(agent, AikidoTest.TestActions.NoSchema)

      assert updated.state.domain.result == "No params"
    end

    test "executes action tuple" do
      agent = AikidoTest.TestAgents.Basic.new()

      {:ok, updated, _directives} =
        AikidoTest.TestAgents.Basic.cmd(agent, {AikidoTest.TestActions.BasicAction, %{value: 42}})

      assert updated.state.domain.value == 42
    end

    test "all-or-nothing batch: every action succeeds; slice reflects the last instruction" do
      agent = AikidoTest.TestAgents.Basic.new()

      {:ok, updated, directives} =
        AikidoTest.TestAgents.Basic.cmd(agent, [
          {AikidoTest.TestActions.Add, %{value: 5, amount: 3}},
          {AikidoTest.TestActions.Add, %{value: 1, amount: 1}}
        ])

      assert updated.state.domain.value == 2
      assert directives == []
    end

    test "all-or-nothing batch: middle instruction errors halts the batch and returns the input agent unchanged" do
      agent = AikidoTest.TestAgents.Basic.new(state: %{counter: 0})

      assert {:error, %Ash.Error.Unknown{}} =
               AikidoTest.TestAgents.Basic.cmd(agent, [
                 {AikidoTest.TestActions.Add, %{value: 5, amount: 3}},
                 {AikidoTest.TestActions.FailingAction, %{reason: "halted"}},
                 {AikidoTest.TestActions.Add, %{value: 1, amount: 1}}
               ])
    end

    test "handles %Instruction{} struct directly" do
      agent = AikidoTest.TestAgents.Basic.new()

      {:ok, instruction} =
        Aikido.Instruction.new(%{
          action: AikidoTest.TestActions.BasicAction,
          params: %{value: 99}
        })

      {:ok, updated, _directives} = AikidoTest.TestAgents.Basic.cmd(agent, instruction)
      assert updated.state.domain.value == 99
    end

    test "single-instruction error returns {:error, %Aikido.Error{}}" do
      agent = AikidoTest.TestAgents.Basic.new()

      assert {:error, %Ash.Error.Invalid{}} =
               AikidoTest.TestAgents.Basic.cmd(agent, {AikidoTest.TestActions.BasicAction, %{}})
    end

    test "invalid input format returns {:error, %ValidationError{}}" do
      agent = AikidoTest.TestAgents.Basic.new()

      assert {:error, %Aikido.Error.ValidationError{message: "Invalid action"}} =
               AikidoTest.TestAgents.Basic.cmd(agent, {:unknown, "whatever"})
    end
  end

  describe("cmd/3 with opts") do
    test "passes timeout option to instruction" do
      agent = AikidoTest.TestAgents.Basic.new()

      assert {:error, %Aikido.Error.TimeoutError{timeout: 10}} =
               AikidoTest.TestAgents.Basic.cmd(
                 agent,
                 {AikidoTest.TestActions.SlowAction, %{delay_ms: 200}},
                 timeout: 10
               )
    end

    test "passes max_retries option to disable retries" do
      agent = AikidoTest.TestAgents.Basic.new()
      start_no_retry = System.monotonic_time(:millisecond)

      assert {:error, %Aikido.Error.TimeoutError{timeout: 10}} =
               AikidoTest.TestAgents.Basic.cmd(
                 agent,
                 {AikidoTest.TestActions.SlowAction, %{delay_ms: 200}},
                 timeout: 10,
                 max_retries: 0
               )

      elapsed_no_retry = System.monotonic_time(:millisecond) - start_no_retry
      start_default = System.monotonic_time(:millisecond)

      assert {:error, %Aikido.Error.TimeoutError{timeout: 10}} =
               AikidoTest.TestAgents.Basic.cmd(
                 agent,
                 {AikidoTest.TestActions.SlowAction, %{delay_ms: 200}},
                 timeout: 10
               )

      elapsed_default = System.monotonic_time(:millisecond) - start_default
      assert elapsed_no_retry < elapsed_default
    end

    test "cmd/2 delegates to cmd/3 with empty opts" do
      agent = AikidoTest.TestAgents.Basic.new()

      {:ok, updated1, directives1} =
        AikidoTest.TestAgents.Basic.cmd(agent, AikidoTest.TestActions.NoSchema)

      {:ok, updated2, directives2} =
        AikidoTest.TestAgents.Basic.cmd(agent, AikidoTest.TestActions.NoSchema, [])

      assert updated1.state == updated2.state
      assert directives1 == directives2
    end

    test "opts are merged into all instructions; first failure halts" do
      agent = AikidoTest.TestAgents.Basic.new()

      assert {:error, %Aikido.Error.TimeoutError{timeout: 10}} =
               AikidoTest.TestAgents.Basic.cmd(
                 agent,
                 [
                   {AikidoTest.TestActions.SlowAction, %{delay_ms: 200}},
                   {AikidoTest.TestActions.SlowAction, %{delay_ms: 200}}
                 ],
                 timeout: 10,
                 max_retries: 0
               )
    end
  end

  describe("base module functions") do
    test "Agent.new/1 creates agent from attrs (map)" do
      {:ok, agent} = Aikido.Agent.new(%{name: "test_agent", id: "test-123"})
      assert agent.id == "test-123"
      assert agent.name == "test_agent"
    end

    test "Agent.new/1 creates agent from attrs (keyword list)" do
      {:ok, agent} = Aikido.Agent.new(name: "test_agent", id: "kw-123")
      assert agent.id == "kw-123"
      assert agent.name == "test_agent"
    end

    test "Agent.new/1 auto-generates id when not provided" do
      {:ok, agent} = Aikido.Agent.new(%{name: "test_agent"})
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "Agent.new/1 generates id when nil is passed" do
      {:ok, agent} = Aikido.Agent.new(%{id: nil, name: "test_agent"})
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "Agent.new/1 generates id when empty string is passed" do
      {:ok, agent} = Aikido.Agent.new(%{id: "", name: "test_agent"})
      assert is_binary(agent.id)
      assert String.length(agent.id) > 0
    end

    test "Agent.set/2 updates state" do
      {:ok, agent} = Aikido.Agent.new(%{id: "test"})
      {:ok, updated} = Aikido.Agent.set(agent, %{key: "value"})
      assert updated.state.key == "value"
    end

    test "Agent.new/1 returns error for invalid id type" do
      {:error, error} = Aikido.Agent.new(%{id: 12345})
      assert error.message == "Agent validation failed"
    end

    test "Agent.validate/2 validates state against schema" do
      {:ok, agent} =
        Aikido.Agent.new(%{
          id: "test",
          schema: Spark.Dsl.Extension.get_opt(AikidoTest.TestAgents.AshSchema, [:agent], :schema)
        })

      {:ok, validated} = Aikido.Agent.validate(agent)
      assert validated.state.count == 0
    end

    test "Agent.validate/2 returns error for invalid state" do
      {:ok, agent} =
        Aikido.Agent.new(%{id: "test", schema: [count: [type: :integer, required: true]]})

      agent = %{agent | state: %{count: "not_an_integer"}}
      {:error, error} = Aikido.Agent.validate(agent)
      assert error.message == "State validation failed"
    end

    test "the base agent constructor validates native state types" do
      assert {:ok, %Aikido.Agent{state: %{}}} = Aikido.Agent.new(%{id: "native-contract"})
      assert {:error, _} = Aikido.Agent.new(%{id: "invalid-state", state: "not a map"})
    end
  end

  describe("actions returning effects") do
    test "action can emit signal via directive" do
      agent = AikidoTest.TestAgents.Basic.new()

      {:ok, updated, directives} =
        AikidoTest.TestAgents.Basic.cmd(agent, AikidoTest.TestActions.EmitAction)

      assert updated.state.domain.emitted == true
      assert [%Aikido.Directives.Emit{signal: signal}] = directives
      assert signal.type == "test.emitted"
    end

    test "action can return multiple directives" do
      agent = AikidoTest.TestAgents.Basic.new()

      {:ok, updated, directives} =
        AikidoTest.TestAgents.Basic.cmd(agent, AikidoTest.TestActions.MultiEffectAction)

      assert updated.state.domain.triggered == true
      assert length(directives) == 2
      assert [%Aikido.Directives.Emit{}, %Aikido.Directives.Schedule{}] = directives
    end

    test "SliceUpdate writes multiple slices in one action turn" do
      agent =
        AikidoTest.TestAgents.Basic.new(
          state: %{domain: %{prior: true}, audit: %{last_event: :none}}
        )

      {:ok, updated, directives} =
        AikidoTest.TestAgents.Basic.cmd(agent, AikidoTest.TestActions.MultiSliceAction)

      assert updated.state.domain == %{primary: "result"}
      assert updated.state.audit == %{last_event: :touched}
      assert directives == []
    end
  end

  describe("Ash field contract support") do
    test "agent works with Ash field contract" do
      agent = AikidoTest.TestAgents.AshSchema.new()
      assert agent.name == "ash_schema_agent"
    end

    test "validate works with Ash field contract" do
      agent = AikidoTest.TestAgents.AshSchema.new(state: %{status: :running, count: 5})
      {:ok, validated} = AikidoTest.TestAgents.AshSchema.validate(agent)
      assert validated.state.domain.status == :running
      assert validated.state.domain.count == 5
    end
  end
end
