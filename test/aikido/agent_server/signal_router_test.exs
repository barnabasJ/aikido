defmodule AikidoTest.AgentServer.SignalRouterTest do
  use ExUnit.Case, async: true

  alias Aikido.AgentServer.SignalRouter
  alias Aikido.AgentServer.State
  alias Aikido.AgentServer.State.Lifecycle
  alias Jido.Signal.Router, as: AikidoRouter

  defmodule TestAction do
    @moduledoc false
    use Aikido.Action

    action do
      name "test_action"

      schema do
      end
    end

    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}, []}
  end

  defmodule AnotherAction do
    @moduledoc false
    use Aikido.Action

    action do
      name "another_action"

      schema do
      end
    end

    def run(_signal, _slice, _opts, _ctx), do: {:ok, %{}, []}
  end

  defmodule SliceWithRoutes do
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

  defmodule AgentWithRoutes do
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

  defmodule AgentWithConfiguredRoutes do
    @moduledoc false
    use Aikido.Agent

    agent do
      name "agent_with_configured_routes"
    end

    signal_routes do
      route "agent.configured", AikidoTest.AgentServer.SignalRouterTest.TestAction
    end
  end

  defmodule AgentWithoutRoutes do
    @moduledoc "Agent that does NOT export signal_routes/1"
    use Aikido.Agent

    agent do
      name "agent_without_routes"
    end
  end

  defmodule AgentWithSlices do
    @moduledoc false
    use Aikido.Agent

    agent do
      name "agent_with_slices"
    end

    slices do
      slice(:router_slice, SliceWithRoutes)
    end
  end

  defp build_state(agent_module) do
    {:ok, lifecycle} = Lifecycle.new([])

    %State{
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

  describe "build/1 — agent routes" do
    test "collects routes declared via use Aikido.Agent, signal_routes:" do
      router = SignalRouter.build(build_state(AgentWithConfiguredRoutes))
      assert {:ok, [TestAction]} = AikidoRouter.route(router, signal("agent.configured"))
    end

    test "collects routes from agent_module.signal_routes/1" do
      router = SignalRouter.build(build_state(AgentWithRoutes))
      assert {:ok, [TestAction]} = AikidoRouter.route(router, signal("agent.action"))
      assert {:ok, [TestAction]} = AikidoRouter.route(router, signal("agent.priority"))
    end

    test "agent without routes still produces a working router" do
      router = SignalRouter.build(build_state(AgentWithoutRoutes))
      assert {:error, _} = AikidoRouter.route(router, signal("nonexistent"))
    end
  end

  describe "build/1 — slice routes" do
    test "collects routes from slices using their declared (absolute) paths" do
      router = SignalRouter.build(build_state(AgentWithSlices))

      assert {:ok, [TestAction]} =
               AikidoRouter.route(router, signal("slice.custom"))

      assert {:ok, [TestAction]} =
               AikidoRouter.route(router, signal("slice.priority"))
    end

    test "non-matching signals fall through to error" do
      router = SignalRouter.build(build_state(AgentWithSlices))
      assert {:error, _} = AikidoRouter.route(router, signal("no.match"))
    end
  end

  describe "build/1 — built-in routes" do
    test "every agent has the aikido.agent.query.children built-in route" do
      router = SignalRouter.build(build_state(AgentWithoutRoutes))

      assert {:ok, [Aikido.AgentServer.Actions.QueryChildren]} =
               AikidoRouter.route(router, signal("aikido.agent.query.children"))
    end
  end

  defp signal(type) do
    {:ok, sig} = Jido.Signal.new(%{type: type, source: "/test", data: %{}})
    sig
  end
end
