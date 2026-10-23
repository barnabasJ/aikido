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

  test "each retry receives a fresh deadline and backoff does not consume it", context do
    owner = start_server(context, __MODULE__.Owner, initial_state: %{request_id: "retry"})
    supervisor = start_supervised!(Task.Supervisor)

    work = fn _notify, attempt ->
      if attempt == 0, do: {:error, :timeout}, else: {:ok, :recovered}
    end

    assert {:ok, :recovered} =
             Aikido.AiReact.CancellableTask.run_cancellable_attempts(
               owner,
               "retry",
               supervisor,
               work,
               timeout: 100,
               retries: 1,
               backoff: 150
             )
  end

  test "an expired run deadline starts no work", context do
    owner = start_server(context, __MODULE__.Owner, initial_state: %{request_id: "expired"})
    supervisor = start_supervised!(Task.Supervisor)
    observer = self()

    assert {:error, :timeout} =
             Aikido.AiReact.CancellableTask.run_cancellable_attempts(
               owner,
               "expired",
               supervisor,
               fn _, _ -> send(observer, :unexpected_attempt) end,
               timeout: 5_000,
               deadline_at: System.system_time(:millisecond) - 1
             )

    refute_received :unexpected_attempt
  end

  test "retry backoff cannot renew the enclosing run deadline", context do
    owner = start_server(context, __MODULE__.Owner, initial_state: %{request_id: "bounded"})
    supervisor = start_supervised!(Task.Supervisor)
    observer = self()

    assert {:error, :timeout} =
             Aikido.AiReact.CancellableTask.run_cancellable_attempts(
               owner,
               "bounded",
               supervisor,
               fn _, attempt ->
                 send(observer, {:attempt, attempt})
                 {:error, :timeout}
               end,
               timeout: 5_000,
               deadline_at: System.system_time(:millisecond) + 200,
               retries: 2,
               backoff: 1_000
             )

    assert_received {:attempt, 0}
    refute_received {:attempt, 1}
    assert Task.Supervisor.children(supervisor) == []
  end

  test "owner exit while subscribing returns an error instead of crashing the tool owner" do
    pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    ref = Process.monitor(pid)
    send(pid, :finish)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    supervisor = start_supervised!(Task.Supervisor)

    assert {:error, {:owner_unavailable, _}} =
             Aikido.AiReact.CancellableTask.run_cancellable_attempts(
               pid,
               "gone",
               supervisor,
               fn _, _ -> flunk("work must not start") end,
               timeout: 1_000
             )
  end

  test "only nonempty generation chunks reset streaming progress" do
    alias Aikido.AiReact.ModelStream
    alias ReqLLM.StreamChunk

    refute ModelStream.generation_progress?(StreamChunk.text(""))
    refute ModelStream.generation_progress?(StreamChunk.thinking(""))
    refute ModelStream.generation_progress?(StreamChunk.meta(%{usage: 1}))

    refute ModelStream.generation_progress?(%StreamChunk{
             type: :tool_call,
             name: "",
             arguments: %{}
           })

    assert ModelStream.generation_progress?(StreamChunk.text("answer"))
    assert ModelStream.generation_progress?(StreamChunk.thinking("reasoning"))
    assert ModelStream.generation_progress?(StreamChunk.tool_call("lookup", %{}))
    assert ModelStream.generation_progress?(%StreamChunk{type: :tool_call, arguments: "{\"x\":"})
  end
end
