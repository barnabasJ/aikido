defmodule AikidoTest.AgentServer.SignalRouterTest.TestAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    Aikido.ActionResult.new(state: %{}, directives: [])
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.TestAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
  @persist {:aikido_action_metadata, %{name: "test_action"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServer.SignalRouterTest.TestAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.AnotherAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    Aikido.ActionResult.new(state: %{}, directives: [])
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.AnotherAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
  @persist {:aikido_action_metadata, %{name: "another_action"}}
  actions do
    action :run, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServer.SignalRouterTest.AnotherAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "slice_with_routes"

    schema do
    end
  end

  signal_routes do
    route "slice.custom", AikidoTest.AgentServer.SignalRouterTest.TestAction
    route "slice.priority", AikidoTest.AgentServer.SignalRouterTest.TestAction, priority: -20
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.AgentWithRoutes do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "agent_with_routes"
  end

  signal_routes do
    route "agent.action", AikidoTest.AgentServer.SignalRouterTest.TestAction
    route "agent.priority", AikidoTest.AgentServer.SignalRouterTest.TestAction, priority: 10
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.AgentWithConfiguredRoutes do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "agent_with_configured_routes"
  end

  signal_routes do
    route "agent.configured", AikidoTest.AgentServer.SignalRouterTest.TestAction
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.AgentWithoutRoutes do
  @moduledoc "Agent that does NOT export signal_routes/1"
  use Aikido.Agent

  agent do
    name "agent_without_routes"
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.AgentWithSlices do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "agent_with_slices"
  end

  slices do
    slice :router_slice, AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest do
  use ExUnit.Case, async: true

  defp build_state(agent_module) do
    {:ok, lifecycle} = Aikido.AgentServer.State.Lifecycle.new([])

    %Aikido.AgentServer.State{
      id: "router-test-#{System.unique_integer([:positive])}",
      agent_module: agent_module,
      agent: agent_module.new(),
      status: :idle,
      parent: nil,
      orphaned_from: nil,
      children: %{},
      on_parent_death: :stop,
      aikido: Aikido,
      partition: nil,
      default_dispatch: nil,
      middleware_chain: nil,
      registry: Aikido.Registry,
      spawn_fun: nil,
      cron_jobs: %{},
      cron_monitors: %{},
      cron_monitor_refs: %{},
      cron_restart_attempts: %{},
      cron_restart_timers: %{},
      cron_restart_timer_refs: %{},
      cron_specs: %{},
      cron_runtime_specs: %{},
      skip_schedules: false,
      error_count: 0,
      metrics: %{},
      signal_subscribers: %{},
      ready_waiters: %{},
      lifecycle: lifecycle,
      debug: false,
      debug_events: [],
      debug_max_events: 500
    }
  end

  describe("build/1 — agent routes") do
    test "collects routes declared via use Aikido.Agent, signal_routes:" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithConfiguredRoutes)
        )

      assert {:ok, [AikidoTest.AgentServer.SignalRouterTest.TestAction]} =
               Jido.Signal.Router.route(router, signal("agent.configured"))
    end

    test "collects routes from agent_module.signal_routes/1" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithRoutes)
        )

      assert {:ok, [AikidoTest.AgentServer.SignalRouterTest.TestAction]} =
               Jido.Signal.Router.route(router, signal("agent.action"))

      assert {:ok, [AikidoTest.AgentServer.SignalRouterTest.TestAction]} =
               Jido.Signal.Router.route(router, signal("agent.priority"))
    end

    test "agent without routes still produces a working router" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithoutRoutes)
        )

      assert {:error, _} = Jido.Signal.Router.route(router, signal("nonexistent"))
    end
  end

  describe("build/1 — slice routes") do
    test "collects routes from slices using their declared (absolute) paths" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithSlices)
        )

      assert {:ok, [AikidoTest.AgentServer.SignalRouterTest.TestAction]} =
               Jido.Signal.Router.route(router, signal("slice.custom"))

      assert {:ok, [AikidoTest.AgentServer.SignalRouterTest.TestAction]} =
               Jido.Signal.Router.route(router, signal("slice.priority"))
    end

    test "non-matching signals fall through to error" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithSlices)
        )

      assert {:error, _} = Jido.Signal.Router.route(router, signal("no.match"))
    end
  end

  describe("build/1 — built-in routes") do
    test "every agent has the aikido.agent.query.children built-in route" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithoutRoutes)
        )

      assert {:ok, [{Aikido.AgentServer.RuntimeActions, :query_children}]} =
               Jido.Signal.Router.route(router, signal("aikido.agent.query.children"))
    end
  end

  defp signal(type) do
    {:ok, sig} = Jido.Signal.new(%{type: type, source: "/test", data: %{}})
    sig
  end
end
