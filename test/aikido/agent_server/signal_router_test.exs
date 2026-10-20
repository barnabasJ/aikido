defmodule AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes do
  @moduledoc false
  use Aikido.Slice

  slice do
    name "slice_with_routes"

    route "slice.custom", {AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes, :test_action}

    route "slice.priority",
          {AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes, :test_action}, priority: -20
  end

  actions do
    action :test_action, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.TestActions.Actions.ClearState
    end
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.AgentWithRoutes do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "agent_with_routes"
    route "agent.action", {AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes, :test_action}

    route "agent.priority",
          {AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes, :test_action}, priority: 10
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.AgentWithConfiguredRoutes do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "agent_with_configured_routes"

    route "agent.configured",
          {AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes, :test_action}
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest.AgentWithoutRoutes do
  @moduledoc "Agent with no declared signal routes"
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
    slice :router_slice, AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes
  end
end

defmodule AikidoTest.AgentServer.SignalRouterTest do
  use ExUnit.Case, async: true

  defp build_state(agent_module) do
    Aikido.AgentServer.State.new!(
      id: "router-test-#{System.unique_integer([:positive])}",
      agent_module: agent_module,
      agent: agent_module.initialize!(),
      status: :idle,
      aikido: Aikido
    )
  end

  describe("build/1 — agent routes") do
    test "collects routes declared in the agent block" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithConfiguredRoutes)
        )

      assert {:ok, [{AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes, :test_action}]} =
               Aikido.Signal.Router.route(router, signal("agent.configured"))
    end

    test "collects native route declarations and priorities" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithRoutes)
        )

      assert {:ok, [{AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes, :test_action}]} =
               Aikido.Signal.Router.route(router, signal("agent.action"))

      assert {:ok, [{AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes, :test_action}]} =
               Aikido.Signal.Router.route(router, signal("agent.priority"))
    end

    test "agent without routes still produces a working router" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithoutRoutes)
        )

      assert {:error, _} = Aikido.Signal.Router.route(router, signal("nonexistent"))
    end
  end

  describe("build/1 — slice routes") do
    test "collects routes from slices using their declared (absolute) paths" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithSlices)
        )

      assert {:ok, [{AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes, :test_action}]} =
               Aikido.Signal.Router.route(router, signal("slice.custom"))

      assert {:ok, [{AikidoTest.AgentServer.SignalRouterTest.SliceWithRoutes, :test_action}]} =
               Aikido.Signal.Router.route(router, signal("slice.priority"))
    end

    test "non-matching signals fall through to error" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithSlices)
        )

      assert {:error, _} = Aikido.Signal.Router.route(router, signal("no.match"))
    end
  end

  describe("build/1 — built-in routes") do
    test "every agent has the aikido.agent.query.children built-in route" do
      router =
        Aikido.AgentServer.SignalRouter.build(
          build_state(AikidoTest.AgentServer.SignalRouterTest.AgentWithoutRoutes)
        )

      assert {:ok, [{Aikido.AgentServer.RuntimeActions, :query_children}]} =
               Aikido.Signal.Router.route(router, signal("aikido.agent.query.children"))
    end
  end

  defp signal(type) do
    {:ok, sig} = Aikido.Signal.new(%{type: type, source: "/test", data: %{}})
    sig
  end
end
