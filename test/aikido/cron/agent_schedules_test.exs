defmodule AikidoTest.Agent.SchedulesTest do
  use ExUnit.Case, async: true

  test "native schedule entities retain payload, timezone and identity" do
    schedule = %Aikido.Cron.Schedule{
      cron: "* * * * *",
      signal_type: "heartbeat.tick",
      job_id: :heartbeat,
      timezone: "Europe/Vienna",
      data: %{amount: 3}
    }

    assert [spec] = Aikido.Cron.Declarations.agent_schedules([schedule], "agent")

    assert spec == %{
             cron_expression: "* * * * *",
             job_id: {:agent_schedule, "agent", :heartbeat},
             signal_type: "heartbeat.tick",
             timezone: "Europe/Vienna",
             data: %{amount: 3}
           }
  end

  test "schedule defaults use the signal identity and UTC" do
    schedule = %Aikido.Cron.Schedule{cron: "@daily", signal_type: "cleanup.run", data: %{}}
    assert [spec] = Aikido.Cron.Declarations.agent_schedules([schedule], "agent")
    assert spec.job_id == {:agent_schedule, "agent", "cleanup.run"}
    assert spec.timezone == "Etc/UTC"
  end

  test "no declarations produce no schedules" do
    assert Aikido.Cron.Declarations.agent_schedules([], "agent") == []
  end
end
