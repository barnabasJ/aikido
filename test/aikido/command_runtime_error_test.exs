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

  test "generated list omits a retiring entry and preserves a healthy agent" do
    retiring = Domain.counter_start!(%{id: unique_id("stopped-list")})
    healthy = Domain.counter_start!(%{id: unique_id("healthy-list")})
    nonce = AikidoTest.AgentCommandGate.install(retiring.pid, :shutdown)
    stopping = Task.async(fn -> Domain.counter_stop(retiring.id) end)

    try do
      assert_receive {^nonce, :held, pid} when pid == retiring.pid, 5_000

      listing =
        Task.async(fn ->
          receive do
            :list -> Domain.counter_list()
          end
        end)

      :erlang.trace(listing.pid, true, [:send])
      send(listing.pid, :list)
      reader = listing.pid
      owner = retiring.pid

      assert_receive {:trace, ^reader, :send, {:"$gen_call", _, {:read_state_with_selector, _}},
                      ^owner},
                     5_000

      AikidoTest.AgentCommandGate.release(retiring.pid, nonce)
      assert {:ok, _} = Task.await(stopping, 5_000)
      assert {:ok, records} = Task.await(listing, 5_000)
      assert Enum.map(records, & &1.id) == [healthy.id]
    after
      AikidoTest.AgentCommandGate.release(retiring.pid, nonce)
    end
  end

  test "a timeout during generated list remains a typed runtime error" do
    reference = Domain.counter_start!(%{id: unique_id("list-timeout")})
    nonce = AikidoTest.AgentCommandGate.install(reference.pid, :read)
    listing = Task.async(fn -> Domain.counter_list() end)

    try do
      assert_receive {^nonce, :held, pid} when pid == reference.pid, 5_000
      assert {:error, %Ash.Error.Invalid{errors: errors}} = Task.await(listing, 7_000)
      assert [%RuntimeUnavailable{reason: {:timeout, {GenServer, :call, _}}}] = errors
      assert Process.alive?(reference.pid)
    after
      AikidoTest.AgentCommandGate.release(reference.pid, nonce)
    end
  end

  test "an unexpected crash during generated list remains a typed runtime error" do
    reference = Domain.counter_start!(%{id: unique_id("list-crash")})
    nonce = AikidoTest.AgentCommandGate.install(reference.pid, :read)
    listing = Task.async(fn -> Domain.counter_list() end)
    assert_receive {^nonce, :held, pid} when pid == reference.pid, 5_000
    Process.exit(reference.pid, :kill)
    assert {:error, %Ash.Error.Invalid{errors: errors}} = Task.await(listing, 5_000)
    assert [%RuntimeUnavailable{reason: {:killed, {GenServer, :call, _}}}] = errors
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
