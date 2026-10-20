defmodule AikidoTest.Actions.SchedulingTest do
  use ExUnit.Case, async: true
  alias Aikido.Directives
  alias Jido.Signal

  defp sig(type, data) do
    Signal.new!(%{type: type, source: "/test", data: data})
  end

  describe("ScheduleSignal") do
    test "creates schedule directive with signal" do
      data = %{
        delay_ms: 5000,
        signal_type: "work.check",
        payload: %{attempt: 1},
        source: "/scheduler"
      }

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("schedule_signal", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(
            :schedule_signal,
            Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
      assert %Directives.Schedule{} = directive
      assert directive.delay_ms == 5000
      assert directive.message.type == "work.check"
      assert directive.message.data == %{attempt: 1}
    end

    test "uses default source" do
      data = %{delay_ms: 1000, signal_type: "ping", payload: %{}, source: "/scheduler"}

      {:ok, %Aikido.Types.ActionResult{state: _result, directives: [directive]}} =
        then(sig("schedule_signal", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(
            :schedule_signal,
            Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert directive.message.source == "/scheduler"
    end
  end

  describe("ScheduleTimeout") do
    test "creates schedule directive for timeout" do
      data = %{timeout_ms: 30_000, timeout_id: :work_deadline, signal_type: "agent.timeout"}

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("schedule_timeout", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(
            :schedule_timeout,
            Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
      assert %Directives.Schedule{} = directive
      assert directive.delay_ms == 30_000
      assert directive.message.type == "agent.timeout"
      assert directive.message.data == %{timeout_id: :work_deadline}
    end

    test "uses default timeout_id" do
      data = %{timeout_ms: 5000, timeout_id: :default, signal_type: "agent.timeout"}

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("schedule_timeout", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(
            :schedule_timeout,
            Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
      assert directive.message.data.timeout_id == :default
    end
  end

  describe("ScheduleCron") do
    test "creates cron directive" do
      data = %{
        cron: "* * * * *",
        job_id: :heartbeat,
        signal_type: "agent.heartbeat",
        payload: %{},
        timezone: nil
      }

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("schedule_cron", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:schedule_cron, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
      assert %Directives.Cron{} = directive
      assert directive.cron == "* * * * *"
      assert directive.job_id == :heartbeat
      assert directive.message.type == "agent.heartbeat"
    end

    test "includes timezone when provided" do
      data = %{
        cron: "0 9 * * *",
        job_id: :daily,
        signal_type: "daily.task",
        payload: %{},
        timezone: "America/New_York"
      }

      {:ok, %Aikido.Types.ActionResult{state: _result, directives: [directive]}} =
        then(sig("schedule_cron", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:schedule_cron, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert directive.timezone == "America/New_York"
    end
  end

  describe("CancelCron") do
    test "creates cron cancel directive" do
      data = %{job_id: :heartbeat}

      {:ok, %Aikido.Types.ActionResult{state: result, directives: [directive]}} =
        then(sig("cancel_cron", data), fn signal ->
          Aikido.AgentServer.RuntimeActions
          |> Ash.ActionInput.for_action(:cancel_cron, Map.put(signal.data || %{}, :state, %{}),
            context: %{aikido: Map.put(%{}, :signal, signal)},
            skip_unknown_inputs: [:*]
          )
          |> Ash.run_action()
        end)

      assert result == %{}
      assert %Directives.CronCancel{} = directive
      assert directive.job_id == :heartbeat
    end
  end
end
