defmodule Aikido.AICleanupTest.Owner do
  use Aikido.Agent

  agent do
    name "cleanup_owner"

    schema do
      attribute :request_id, :string do
        description "Correlation identifier for the active work request."
      end

      attribute :status, :atom do
        description "Current lifecycle or processing status of the fixture."
        default :running
      end
    end
  end
end

defmodule Aikido.AICleanupTest do
  use AikidoTest.Case, async: true

  test "cleanup failures are diagnosed without replacing the result or skipping later cleanup",
       context do
    request_id = "cleanup"
    owner = start_server(context, __MODULE__.Owner, initial_state: %{request_id: request_id})
    supervisor = start_supervised!(Task.Supervisor)
    observer = self()

    work = fn notify, _attempt ->
      notify.({:cleanup, fn -> send(observer, :remaining_cleanup) end})
      notify.({:cleanup, fn -> raise "cleanup failure" end})
      notify.({:cleanup, fn -> throw(:cleanup_failure) end})
      {:ok, :primary_result}
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, :primary_result} =
                 Aikido.AiReact.CancellableTask.run_cancellable_attempts(
                   owner,
                   request_id,
                   supervisor,
                   work,
                   timeout: 5_000
                 )
      end)

    assert log =~ "AI cleanup callback raised:"
    assert log =~ "AI cleanup callback throw: :cleanup_failure"
    assert_receive :remaining_cleanup
    assert Task.Supervisor.children(supervisor) == []
  end
end
