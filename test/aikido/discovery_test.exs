defmodule AikidoTest.DiscoveryTest.TestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    Aikido.ActionResult.new(state: %{}, directives: [])
  end
end

defmodule AikidoTest.DiscoveryTest.TestAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  @persist {:aikido_action_metadata,
            %{name: "discovery_test_action", description: "Test action for discovery"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      description "Test action for discovery"
      run {AikidoTest.DiscoveryTest.TestAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.DiscoveryTest.TestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "discovery_test_agent"
    description "Test agent for discovery"
    category "test"
    tags ["discovery", "test"]
  end
end

defmodule AikidoTest.DiscoveryTest do
  use ExUnit.Case, async: false

  setup do
    Aikido.Discovery.refresh()
    :ok
  end

  describe("init_async/0") do
    test "returns a Task" do
      task = Aikido.Discovery.init_async()
      assert %Task{} = task
      Task.await(task)
    end
  end

  describe("refresh/0") do
    test "refreshes the catalog" do
      assert :ok = Aikido.Discovery.refresh()
    end
  end

  describe("last_updated/0") do
    test "returns timestamp after initialization" do
      {:ok, timestamp} = Aikido.Discovery.last_updated()
      assert %DateTime{} = timestamp
    end
  end

  describe("catalog/0") do
    test "returns full catalog" do
      {:ok, catalog} = Aikido.Discovery.catalog()
      assert Map.has_key?(catalog, :last_updated)
      assert Map.has_key?(catalog, :components)
      assert Map.has_key?(catalog.components, :actions)
      assert Map.has_key?(catalog.components, :sensors)
      assert Map.has_key?(catalog.components, :agents)
      assert Map.has_key?(catalog.components, :slices)
      assert Map.has_key?(catalog.components, :demos)
    end
  end

  describe("list_actions/1") do
    test "returns a list of actions" do
      actions = Aikido.Discovery.list_actions()
      assert is_list(actions)
    end

    test "filters by limit" do
      actions = Aikido.Discovery.list_actions(limit: 2)
      assert length(actions) <= 2
    end

    test "filters by offset" do
      all_actions = Aikido.Discovery.list_actions()
      offset_actions = Aikido.Discovery.list_actions(offset: 1)

      if length(all_actions) > 1 do
        assert length(offset_actions) == length(all_actions) - 1
      end
    end

    test "filters by name" do
      actions = Aikido.Discovery.list_actions(name: "discovery_test")
      assert Enum.all?(actions, fn a -> String.contains?(a[:name] || "", "discovery_test") end)
    end

    test "filters by description" do
      actions = Aikido.Discovery.list_actions(description: "discovery")
      assert Enum.all?(actions, fn a -> String.contains?(a[:description] || "", "discovery") end)
    end

    test "filters by category" do
      actions = Aikido.Discovery.list_actions(category: :utility)
      assert Enum.all?(actions, fn a -> a[:category] == :utility end)
    end

    test "filters by tag" do
      actions = Aikido.Discovery.list_actions(tag: :test)
      assert Enum.all?(actions, fn a -> is_list(a[:tags]) and :test in a[:tags] end)
    end
  end

  describe("list_sensors/1") do
    test "returns a list of sensors" do
      sensors = Aikido.Discovery.list_sensors()
      assert is_list(sensors)
    end

    test "filters by limit" do
      sensors = Aikido.Discovery.list_sensors(limit: 1)
      assert length(sensors) <= 1
    end
  end

  describe("list_agents/1") do
    test "returns a list of agents" do
      agents = Aikido.Discovery.list_agents()
      assert is_list(agents)
    end

    test "includes discoverable agent metadata" do
      app = :aikido_discovery_test_app

      spec =
        {:application, app,
         description: ~c"Aikido discovery test app",
         vsn: ~c"0.1.0",
         modules: [AikidoTest.DiscoveryTest.TestAgent]}

      load_result =
        case :application.load(spec) do
          :ok -> :ok
          {:error, {:already_loaded, ^app}} -> :ok
        end

      assert load_result == :ok

      on_exit(fn ->
        unload_result =
          case :application.unload(app) do
            :ok -> :ok
            {:error, {:not_loaded, ^app}} -> :ok
          end

        assert unload_result == :ok
      end)

      :ok = Aikido.Discovery.refresh()
      agents = Aikido.Discovery.list_agents()
      agent = Enum.find(agents, &(&1[:name] == "discovery_test_agent"))
      assert agent != nil
      assert agent[:description] == "Test agent for discovery"
      assert agent[:category] == "test"
      assert is_list(agent[:tags]) and "discovery" in agent[:tags]
      assert agent[:module] == AikidoTest.DiscoveryTest.TestAgent
      assert Map.has_key?(agent, :schema)
      assert Map.has_key?(agent, :slug)
    end

    test "filters by limit" do
      agents = Aikido.Discovery.list_agents(limit: 1)
      assert length(agents) <= 1
    end
  end

  describe("list_slices/1") do
    test "returns a list of slices" do
      slices = Aikido.Discovery.list_slices()
      assert is_list(slices)
    end

    test "filters by limit" do
      slices = Aikido.Discovery.list_slices(limit: 1)
      assert length(slices) <= 1
    end
  end

  describe("list_demos/1") do
    test "returns a list of demos" do
      demos = Aikido.Discovery.list_demos()
      assert is_list(demos)
    end

    test "filters by limit" do
      demos = Aikido.Discovery.list_demos(limit: 1)
      assert length(demos) <= 1
    end
  end

  describe("get_action_by_slug/1") do
    test "returns nil for non-existent slug" do
      assert nil == Aikido.Discovery.get_action_by_slug("nonexistent_slug_123")
    end

    test "returns action for valid slug" do
      actions = Aikido.Discovery.list_actions(limit: 1)

      if actions != [] do
        [action | _] = actions
        found = Aikido.Discovery.get_action_by_slug(action.slug)
        assert found != nil
        assert found.slug == action.slug
      end
    end
  end

  describe("get_sensor_by_slug/1") do
    test "returns nil for non-existent slug" do
      assert nil == Aikido.Discovery.get_sensor_by_slug("nonexistent_slug_123")
    end
  end

  describe("get_agent_by_slug/1") do
    test "returns nil for non-existent slug" do
      assert nil == Aikido.Discovery.get_agent_by_slug("nonexistent_slug_123")
    end

    test "returns agent for valid slug" do
      agents = Aikido.Discovery.list_agents(limit: 1)

      if agents != [] do
        [agent | _] = agents
        found = Aikido.Discovery.get_agent_by_slug(agent.slug)
        assert found != nil
        assert found.slug == agent.slug
      end
    end
  end

  describe("get_slice_by_slug/1") do
    test "returns nil for non-existent slug" do
      assert nil == Aikido.Discovery.get_slice_by_slug("nonexistent_slug_123")
    end
  end

  describe("get_demo_by_slug/1") do
    test "returns nil for non-existent slug" do
      assert nil == Aikido.Discovery.get_demo_by_slug("nonexistent_slug_123")
    end
  end

  describe("pagination") do
    test "offset and limit work together" do
      all = Aikido.Discovery.list_actions()
      page1 = Aikido.Discovery.list_actions(limit: 2, offset: 0)
      page2 = Aikido.Discovery.list_actions(limit: 2, offset: 2)

      if length(all) >= 4 do
        assert length(page1) == 2
        assert length(page2) == 2
        assert Enum.at(all, 0) == Enum.at(page1, 0)
        assert Enum.at(all, 2) == Enum.at(page2, 0)
      end
    end

    test "handles invalid limit gracefully" do
      actions = Aikido.Discovery.list_actions(limit: -1)
      assert is_list(actions)
    end
  end

  describe("catalog not initialized") do
    test "list functions return empty when catalog not initialized" do
      :persistent_term.erase(:aikido_discovery_catalog)
      assert [] == Aikido.Discovery.list_actions()
      assert [] == Aikido.Discovery.list_sensors()
      assert [] == Aikido.Discovery.list_agents()
      assert [] == Aikido.Discovery.list_slices()
      assert [] == Aikido.Discovery.list_demos()
      Aikido.Discovery.refresh()
    end

    test "get_by_slug returns nil when catalog not initialized" do
      :persistent_term.erase(:aikido_discovery_catalog)
      assert nil == Aikido.Discovery.get_action_by_slug("any")
      assert nil == Aikido.Discovery.get_sensor_by_slug("any")
      assert nil == Aikido.Discovery.get_agent_by_slug("any")
      assert nil == Aikido.Discovery.get_slice_by_slug("any")
      assert nil == Aikido.Discovery.get_demo_by_slug("any")
      Aikido.Discovery.refresh()
    end

    test "last_updated returns error when not initialized" do
      :persistent_term.erase(:aikido_discovery_catalog)
      assert {:error, :not_initialized} = Aikido.Discovery.last_updated()
      Aikido.Discovery.refresh()
    end

    test "catalog returns error when not initialized" do
      :persistent_term.erase(:aikido_discovery_catalog)
      assert {:error, :not_initialized} = Aikido.Discovery.catalog()
      Aikido.Discovery.refresh()
    end
  end
end
