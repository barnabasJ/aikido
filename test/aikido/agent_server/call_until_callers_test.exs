defmodule AikidoTest.AgentServer.CallUntilCallersTest do
  use AikidoTest.Case, async: true

  alias Aikido.AgentServer
  alias __MODULE__.Domain

  @moduletag aikido_instance: __MODULE__.Instance

  setup do
    assert {:ok, subject} = Domain.subject_start(%{})
    assert :ok = AgentServer.await_ready(subject.pid)
    %{subject: subject}
  end

  @tag story: "US-AIKIDO-CALLERS-01"
  test "a callback retains caller ownership while dispatching real Ash commands", %{
    subject: subject
  } do
    # Given an external caller whose native inspect policy depends on caller ancestry.
    owner = self()
    expected_callers = [owner | Process.get(:"$callers", [])]
    actor = %{id: unique_id("waiter-owner"), owner: owner}

    command = fn ->
      with {:ok, %{value: 0}} <-
             Domain.subject_inspect(subject.pid, %{fields: [:value]}, actor: actor) do
        send(owner, {:callback_callers, self(), Process.get(:"$callers", [])})
        Domain.subject_write(subject.pid, %{value: 7})
      end
    end

    # When the callback authorizes its read and dispatches the generated write.
    assert {:ok, 7} =
             AgentServer.call_until(subject.pid, command, "waiter.write", &value/1)

    # Then the isolated waiter retains the real caller and the command completes.
    assert_receive {:callback_callers, waiter, ^expected_callers}, 1_000
    refute waiter == owner
    assert {:ok, 7} = value_from_agent(subject.pid)
  end

  @tag story: "US-AIKIDO-CALLERS-02"
  test "a callback retains the whole native chain when its caller is already a Task", %{
    subject: subject
  } do
    # Given an ordinary caller-owned Task, without editing its process dictionary.
    owner = self()
    actor = %{id: unique_id("nested-waiter-owner"), owner: owner}

    task =
      Task.async(fn ->
        expected_callers = [self() | Process.get(:"$callers", [])]

        command = fn ->
          with {:ok, %{value: 0}} <-
                 Domain.subject_inspect(subject.pid, %{fields: [:value]}, actor: actor) do
            send(
              owner,
              {:nested_callback_callers, Process.get(:"$callers", []), expected_callers}
            )

            Domain.subject_write(subject.pid, %{value: 11})
          end
        end

        # When that Task uses the same public client waiter.
        AgentServer.call_until(subject.pid, command, "waiter.write", &value/1)
      end)

    # Then both the direct Task caller and its owner remain in the native ancestry.
    assert {:ok, 11} = Task.await(task)
    assert_receive {:nested_callback_callers, actual_callers, expected_callers}, 1_000
    assert actual_callers == expected_callers
    task_pid = task.pid
    assert [^task_pid, ^owner | _] = actual_callers
  end

  @tag capture_log: true
  @tag story: "US-AIKIDO-CALLERS-03"
  test "a callback exception returns its actual failure without killing the caller", %{
    subject: subject
  } do
    # Given a callback that fails as soon as it is allowed to run.
    command = fn -> raise "callback failed" end

    # When the independent waiter executes it.
    assert {:error, {:waiter_stopped, {%RuntimeError{message: "callback failed"}, stacktrace}}} =
             AgentServer.call_until(subject.pid, command, "waiter.write", &value/1)

    # Then monitoring preserves the exception instead of losing it to a startup race.
    assert is_list(stacktrace)
    assert Process.alive?(self())
    assert {:ok, 0} = value_from_agent(subject.pid)
  end

  defp value(runtime), do: {:ok, runtime.agent.state.state.value}
  defp value_from_agent(pid), do: AgentServer.state(pid, &value/1)
end
