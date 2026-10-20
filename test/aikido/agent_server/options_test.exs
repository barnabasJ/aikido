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

    test "creates options with default_dispatch" do
      {:ok, opts} =
        Aikido.AgentServer.Options.new(
          @base_opts ++
            [
              agent_module: AikidoTest.AgentServer.OptionsTest.ValidAgent,
              default_dispatch: {:logger, level: :info}
            ]
        )

      assert opts.default_dispatch == {:logger, level: :info}
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
      assert_raise Aikido.Error.ValidationError, fn ->
        Aikido.AgentServer.Options.new!(@base_opts ++ [agent_module: nil])
      end
    end
  end

  describe("agent module validation") do
    test "requires agent_module" do
      {:error, error} = Aikido.AgentServer.Options.new(@base_opts)
      assert error.message =~ "agent_module is required"
    end

    test "rejects nil agent_module" do
      {:error, error} = Aikido.AgentServer.Options.new(@base_opts ++ [agent_module: nil])
      assert error.message =~ "agent_module is required"
    end

    test "rejects module without an initialization action" do
      {:error, error} = Aikido.AgentServer.Options.new(@base_opts ++ [agent_module: Enum])
      assert error.message =~ "must define an :initialize Ash action"
    end

    test "rejects non-existent module" do
      {:error, error} =
        Aikido.AgentServer.Options.new(@base_opts ++ [agent_module: NonExistentModule])

      assert error.message =~ "not found"
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

      assert error.message =~ "parent"
    end
  end
end
