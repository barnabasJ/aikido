defmodule Aikido.CommandRuntimeErrorTest do
  use ExUnit.Case, async: true

  import AikidoTest.Case, only: [unique_id: 1]

  alias Aikido.Agent.CommandRuntime
  alias Aikido.Agent.Errors.RuntimeUnavailable
  alias Aikido.CommandRuntimeErrorTest.Domain

  setup do
    runtime =
      start_supervised!(
        {Aikido,
         name: Aikido.CommandRuntimeErrorTest.Instance, durable: AikidoTest.Case.durable_options()}
      )

    on_exit(fn ->
      monitor = Process.monitor(runtime)
      assert_receive {:DOWN, ^monitor, :process, ^runtime, _}
    end)

    :ok
  end

  test "generated inspect preserves the exit from an actual terminated agent" do
    reference = Domain.counter_start!(%{id: unique_id("terminated-inspect")})
    monitor = Process.monitor(reference.pid)
    assert {:ok, _} = Domain.counter_stop(reference.id)
    assert_receive {:DOWN, ^monitor, :process, pid, _} when pid == reference.pid

    assert {:error, %Ash.Error.Invalid{errors: errors}} = Domain.counter_inspect(reference.pid)
    assert [%RuntimeUnavailable{reason: {:noproc, {GenServer, :call, _}}}] = errors
  end

  test "missing identities have a typed unavailable reason" do
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Domain.counter_inspect(unique_id("absent-agent"))

    assert [%RuntimeUnavailable{reason: :not_running}] = errors
  end

  test "runtime timeouts retain their exact cause without implying process death" do
    reason = {:timeout, {GenServer, :call, [self(), :request, 10]}}

    assert {:error, %RuntimeUnavailable{reason: ^reason}} =
             CommandRuntime.catch_runtime_exit(fn -> exit(reason) end)
  end

  test "ordinary errors and resource mismatches retain their contracts" do
    error =
      Ash.Error.to_error_class(Ash.Error.Changes.InvalidChanges.exception(message: "invalid"))

    assert {:error, ^error} = CommandRuntime.catch_runtime_exit(fn -> {:error, error} end)

    reference = Domain.counter_start!(%{id: unique_id("resource-mismatch")})

    assert {:error, :different_resource} =
             CommandRuntime.resolve(Aikido.CommandRuntimeErrorTest.Protected, reference.pid)
  end

  test "generated command authorization still rejects an unauthorized actor" do
    id = unique_id("denied-runtime")
    assert {:error, %Ash.Error.Forbidden{}} = Domain.protected_start(%{id: id})

    assert AikidoTest.Case.agent_pid(Aikido.CommandRuntimeErrorTest.Instance, id) == nil
  end

  test "error rendering and supported tool projections omit private exit data" do
    sentinel = "private-request-sentinel"
    reason = {:noproc, {GenServer, :call, [self(), %{credential: sentinel}]}}
    error = RuntimeUnavailable.exception(reason: reason)
    aggregate = Ash.Error.to_error_class(error)

    assert error.reason == reason
    assert %Ash.Error.Invalid{errors: [%RuntimeUnavailable{}]} = aggregate

    for rendered <- [
          inspect(error),
          Exception.message(error),
          inspect(aggregate),
          Exception.message(aggregate),
          AshAi.ToToolError.to_tool_error(error),
          AshAi.ToToolError.to_tool_error(aggregate),
          inspect(AshLua.Error.to_error(error)),
          inspect(AshLua.Encoder.encode_error(aggregate))
        ] do
      refute rendered =~ sentinel
    end

    assert %{code: "agent_runtime_unavailable", vars: %{}} = AshLua.Error.to_error(error)

    assert %{"errors" => [%{"code" => "agent_runtime_unavailable", "vars" => %{}}]} =
             AshLua.Encoder.encode_error(aggregate)
  end
end
