defmodule AikidoTest.Agent.SchedulesIntegrationTest.Signals.Tick do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "agent.tick"
  end
end

defmodule AikidoTest.Agent.SchedulesIntegrationTest.Signals.Heartbeat do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "heartbeat.tick"
  end
end

defmodule AikidoTest.Agent.SchedulesIntegrationTest.Signals.Cleanup do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "cleanup.run"
  end
end

defmodule AikidoTest.Agent.SchedulesIntegrationTest.Actions.CountTick do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    slice = input.arguments.state
    count = Map.get(slice, :tick_count, 0)
    Aikido.Types.ActionResult.new(changes: %{tick_count: count + 1}, directives: [])
  end
end

defmodule AikidoTest.Agent.SchedulesIntegrationTest.ScheduledAgent do
  use Aikido.Agent

  agent do
    name "scheduled_agent"
    path :domain

    schema do
      attribute :tick_count, :integer do
        description "Number of scheduled ticks handled by the agent."
        default 0
      end
    end

    route AikidoTest.Agent.SchedulesIntegrationTest.Signals.Tick,
          AikidoTest.Agent.SchedulesIntegrationTest.Actions.CountTick,
          public?: false
  end

  schedules do
    schedule "* * * * * * *", "agent.tick", job_id: :tick
  end
end

defmodule AikidoTest.Agent.SchedulesIntegrationTest.MultiScheduleAgent do
  use Aikido.Agent

  agent do
    name "multi_schedule_agent"
    path :domain

    schema do
      attribute :tick_count, :integer do
        description "Number of scheduled ticks handled by the agent."
        default 0
      end
    end

    route AikidoTest.Agent.SchedulesIntegrationTest.Signals.Heartbeat,
          AikidoTest.Agent.SchedulesIntegrationTest.Actions.CountTick,
          public?: false

    route AikidoTest.Agent.SchedulesIntegrationTest.Signals.Cleanup,
          AikidoTest.Agent.SchedulesIntegrationTest.Actions.CountTick,
          public?: false
  end

  schedules do
    schedule "* * * * *", "heartbeat.tick", job_id: :heartbeat
    schedule "@daily", "cleanup.run", job_id: :cleanup, timezone: "America/New_York"
  end
end

defmodule AikidoTest.Agent.SchedulesIntegrationTest.NoScheduleAgent do
  use Aikido.Agent

  agent do
    name "no_schedule_agent"
    path :domain

    schema do
      attribute :tick_count, :integer do
        description "Number of scheduled ticks handled by the agent."
        default 0
      end
    end
  end
end

defmodule AikidoTest.Agent.SchedulesIntegrationTest do
  use AikidoTest.Case, async: false
  @moduletag :integration
  @moduletag capture_log: true

  describe("agent with schedules") do
    test "Info.schedules/1 exposes the shared schedule contract" do
      module = Aikido.Agent.Info
      {:ok, specs} = Code.Typespec.fetch_specs(module)
      {{:schedules, 1}, [spec]} = List.keyfind(specs, {:schedules, 1}, 0)

      rendered = :schedules |> Code.Typespec.spec_to_quoted(spec) |> Macro.to_string()
      assert String.contains?(rendered, "Aikido.Cron.Declarations.schedule_spec()")
    end

    test "Info.schedules/1 includes agent schedules" do
      schedules =
        Aikido.Agent.Info.schedules(AikidoTest.Agent.SchedulesIntegrationTest.ScheduledAgent)

      agent_schedules =
        Enum.filter(schedules, fn spec -> match?({:agent_schedule, _, _}, spec.job_id) end)

      assert agent_schedules != []
    end

    test "agent schedules have correct job_id namespacing" do
      schedules =
        Aikido.Agent.Info.schedules(AikidoTest.Agent.SchedulesIntegrationTest.ScheduledAgent)

      agent_schedule =
        Enum.find(schedules, fn spec -> match?({:agent_schedule, _, _}, spec.job_id) end)

      assert agent_schedule.job_id == {:agent_schedule, "scheduled_agent", :tick}
    end

    test "agent schedules have correct signal_type" do
      schedules =
        Aikido.Agent.Info.schedules(AikidoTest.Agent.SchedulesIntegrationTest.ScheduledAgent)

      agent_schedule =
        Enum.find(schedules, fn spec -> match?({:agent_schedule, _, _}, spec.job_id) end)

      assert agent_schedule.signal_type == "agent.tick"
    end

    test "agent with no schedules has no agent schedules in schedules" do
      schedules =
        Aikido.Agent.Info.schedules(AikidoTest.Agent.SchedulesIntegrationTest.NoScheduleAgent)

      agent_schedules =
        Enum.filter(schedules, fn spec -> match?({:agent_schedule, _, _}, spec.job_id) end)

      assert agent_schedules == []
    end

    test "multiple schedules are all included" do
      schedules =
        Aikido.Agent.Info.schedules(AikidoTest.Agent.SchedulesIntegrationTest.MultiScheduleAgent)

      agent_schedules =
        Enum.filter(schedules, fn spec -> match?({:agent_schedule, _, _}, spec.job_id) end)

      assert length(agent_schedules) == 2
      signal_types = Enum.map(agent_schedules, & &1.signal_type) |> Enum.sort()
      assert signal_types == ["cleanup.run", "heartbeat.tick"]
    end
  end

  describe("agent schedule tick delivery") do
    test("schedule tick delivers signal and updates state", %{aikido: aikido}) do
      pid =
        start_server(%{aikido: aikido}, AikidoTest.Agent.SchedulesIntegrationTest.ScheduledAgent)

      await_state_value(
        pid,
        fn s ->
          tc = s.agent.state.domain.tick_count

          if tc > 0 do
            tc
          end
        end,
        timeout: 5000
      )
    end
  end
end
