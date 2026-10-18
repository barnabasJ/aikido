defmodule AikidoTest.TestAgents do
  @moduledoc """
  Shared test agents for Aikido test suite.
  """

  Code.ensure_compiled!(AikidoTest.PluginTestAction)
  Code.ensure_compiled!(AikidoTest.TestActions.IncrementAction)

  defmodule Minimal do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("minimal_agent")
    end
  end

  defmodule Counter do
    @moduledoc """
    Standard test agent with counter and messages state.

    Routes:
      - "increment" -> IncrementAction
      - "decrement" -> DecrementAction
      - "record" -> RecordAction
      - "slow" -> SlowAction
      - "fail" -> FailingAction
    """
    use Aikido.Agent

    agent do
      name("counter_agent")
      description("Test agent with counter and message tracking")
      path(:domain)

      schema do
        attribute(:counter, :integer, default: 0)
        attribute(:messages, {:array, :term}, default: [])
      end
    end

    signal_routes do
      route("increment", AikidoTest.TestActions.IncrementAction)
      route("decrement", AikidoTest.TestActions.DecrementAction)
      route("record", AikidoTest.TestActions.RecordAction)
      route("slow", AikidoTest.TestActions.SlowAction)
      route("fail", AikidoTest.TestActions.FailingAction)
    end
  end

  defmodule Basic do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("basic_agent")
      description("A basic test agent")
      category("test")
      tags(["test", "basic"])
      vsn("1.0.0")
      path(:domain)

      schema do
        attribute(:counter, :integer, default: 0)
        attribute(:status, :atom, default: :idle)
      end
    end
  end

  defmodule Hook do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("hook_agent")
      path(:domain)

      schema do
        attribute(:counter, :integer, default: 0)
      end
    end

    def on_after_cmd(agent, _action, directives) do
      new_agent = %{agent | state: put_in(agent.state, [:domain, :hook_called], true)}
      {:ok, new_agent, directives}
    end
  end

  defmodule AshSchema do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("ash_schema_agent")
      path(:domain)

      schema do
        attribute(:status, :atom, allow_nil?: false, default: :idle)
        attribute(:count, :integer, allow_nil?: false, default: 0)
      end
    end
  end

  defmodule TestSliceWithRoutes do
    @moduledoc false
    use Aikido.Slice

    slice do
      name("test_routes_slice")

      schema do
        attribute(:value, :term, allow_nil?: true)
      end
    end

    signal_routes do
      route("post", AikidoTest.PluginTestAction)
      route("list", AikidoTest.PluginTestAction)
    end
  end

  defmodule TestSliceWithPriority do
    @moduledoc false
    use Aikido.Slice

    slice do
      name("priority_slice")

      schema do
        attribute(:value, :term, allow_nil?: true)
      end
    end

    signal_routes do
      route("action", AikidoTest.PluginTestAction, priority: 5)
    end
  end

  defmodule AgentWithSliceRoutes do
    @moduledoc false
    use Aikido.Agent, default_slices: false

    agent do
      name("agent_with_slice_routes")
    end

    slices do
      slice(:test_routes, AikidoTest.TestAgents.TestSliceWithRoutes)
    end
  end
end
