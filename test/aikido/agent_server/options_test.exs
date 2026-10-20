defmodule AikidoTest.AgentServer.OptionsTest.ValidAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "valid_agent"
    path :domain

    schema do
      attribute :value, :integer, default: 0
    end
  end
end

defmodule AikidoTest.AgentServer.OptionsTest do
  use ExUnit.Case, async: true
  @base_opts aikido: :test_aikido

  test "runtime identity requires an ID while initialization generates one" do
    assert {:error, %Ash.Error.Changes.InvalidAttribute{field: :id}} = Aikido.Agent.new(%{})
    assert %Aikido.Agent{id: id} = AikidoTest.AgentServer.OptionsTest.ValidAgent.initialize!(%{})
    assert is_binary(id)
    assert id != ""
  end

  test "native startup fields reject invalid IDs without crashing normalization" do
    assert {:error, %Ash.Error.Changes.InvalidAttribute{field: :id}} =
             Aikido.AgentServer.Options.new(
               agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent,
               id: %{}
             )
  end

  test "startup fields provide the shared runtime default" do
    assert {:ok, %{aikido: Aikido.Default}} =
             Aikido.AgentServer.Options.new(
               agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent
             )
  end

  test "recasting typed options preserves their identity" do
    options =
      Aikido.AgentServer.Options.new!(agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent)

    assert {:ok, ^options} = Aikido.AgentServer.Options.new(options)
  end

  test "string-key startup input preserves the supplied identity" do
    assert {:ok, %{id: "existing-id"}} =
             Aikido.AgentServer.Options.new(%{
               "agent_module" => AikidoTest.AgentServer.OptionsTest.ValidAgent,
               "id" => "existing-id"
             })
  end

  describe("new/1 with keyword list") do
    test "creates options with agent module" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++ [agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent]
        )

      assert opts.agent_module == AikidoTest.AgentServer.OptionsTest.ValidAgent
      assert is_binary(opts.id)
      assert opts.initial_state == %{}
      assert opts.on_parent_death == :stop
    end

    test "creates options with custom id" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++
            [agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent, id: "custom-id"]
        )

      assert opts.id == "custom-id"
    end

    test "creates options with initial_state" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++
            [
              agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent,
              initial_state: %{foo: :bar}
            ]
        )

      assert opts.initial_state == %{foo: :bar}
    end

    test "creates options with on_parent_death" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++
            [
              agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent,
              on_parent_death: :continue
            ]
        )

      assert opts.on_parent_death == :continue
    end
  end

  describe("new/1 with map") do
    test "creates options from map" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(%{
          aikido: :test_aikido,
          agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent,
          id: "map-test"
        })

      assert opts.agent_module == AikidoTest.AgentServer.OptionsTest.ValidAgent
      assert opts.id == "map-test"
    end
  end

  describe("new!/1") do
    test "returns options on success" do
      opts =
        Aikido.AgentServer.Options.new!(
          @base_opts ++ [agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent]
        )

      assert opts.agent_module == AikidoTest.AgentServer.OptionsTest.ValidAgent
    end

    test "raises on error" do
      assert_raise Ash.Error.Invalid, fn ->
        Aikido.AgentServer.Options.new!(@base_opts ++ [agent_module: nil])
      end
    end
  end

  describe("agent module validation") do
    test "requires agent_module" do
      {:error, error} = Aikido.AgentServer.Options.new(@base_opts)
      assert %Ash.Error.Changes.InvalidAttribute{field: :agent_module} = error
    end

    test "rejects nil agent_module" do
      {:error, error} = Aikido.AgentServer.Options.new(@base_opts ++ [agent_module: nil])
      assert %Ash.Error.Changes.InvalidAttribute{field: :agent_module} = error
    end

    test "rejects modules without the agent behaviour" do
      {:error, error} = Aikido.AgentServer.Options.new(@base_opts ++ [agent_module: Enum])
      assert %Ash.Error.Changes.InvalidAttribute{field: :agent_module} = error
    end

    test "rejects non-existent module" do
      {:error, error} =
        Aikido.AgentServer.Options.new(@base_opts ++ [agent_module: NonExistentModule])

      assert %Ash.Error.Changes.InvalidAttribute{field: :agent_module} = error
    end
  end

  describe("ID handling") do
    test "generates ID when not provided" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++ [agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent]
        )

      assert is_binary(opts.id)
      assert String.length(opts.id) > 0
    end

    test "uses provided ID" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++
            [agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent, id: "explicit-id"]
        )

      assert opts.id == "explicit-id"
    end

    test "converts atom ID to string" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++
            [agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent, id: :atom_id]
        )

      assert opts.id == "atom_id"
    end

    test "handles empty string ID by generating one" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++ [agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent, id: ""]
        )

      assert is_binary(opts.id)
      assert opts.id != ""
    end
  end

  describe("parent validation") do
    test "rejects unknown parent-death policies through the typed field" do
      assert {:error, %Ash.Error.Changes.InvalidAttribute{field: :on_parent_death}} =
               Aikido.AgentServer.Options.new(
                 @base_opts ++
                   [
                     agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent,
                     on_parent_death: :unknown
                   ]
               )
    end

    test "accepts nil parent" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++ [agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent, parent: nil]
        )

      assert opts.parent == nil
    end

    test "accepts ParentRef struct" do
      parent = Aikido.AgentServer.ParentRef.new!(%{pid: self(), id: "parent-1", tag: :worker})

      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++
            [agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent, parent: parent]
        )

      assert opts.parent == parent
    end

    test "accepts parent as map and converts to ParentRef" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++
            [
              agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent,
              parent: %{pid: self(), id: "parent-2", tag: :child}
            ]
        )

      assert %Aikido.AgentServer.ParentRef{} = opts.parent
      assert opts.parent.id == "parent-2"
      assert opts.parent.tag == :child
    end

    test "rejects invalid parent" do
      {:error, error} =
        Aikido.AgentServer.Options.new(
          @base_opts ++
            [agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent, parent: "invalid"]
        )

      assert error.field == :parent
    end
  end
end
