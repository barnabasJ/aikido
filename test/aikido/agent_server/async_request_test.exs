defmodule Aikido.AsyncRequestTest.Gate do
  use Aikido.Middleware

  @impl true
  def on_signal(%{type: "write"} = signal, ctx, opts, next) do
    send(opts.observer, {:request_waiting, self()})

    receive do
      :release_request -> next.(signal, ctx)
    end
  end

  def on_signal(signal, ctx, _opts, next), do: next.(signal, ctx)
end

defmodule Aikido.AsyncRequestTest do
  use AikidoTest.Case, async: false
  alias Aikido.AgentServer
  alias AikidoTest.AgentServer.AckSubscribeTest.TestAgent

  test "submission returns immediately; the same process matches one reply among unrelated messages",
       ctx do
    pid = gated_agent(ctx)
    before_monitors = Process.info(self(), :monitors)
    assert {:ok, request} = AgentServer.send_request(pid, signal("write", %{value: 7}), &value/1)
    assert_receive {:request_waiting, ^pid}
    send(self(), :unrelated)
    assert_receive :unrelated
    assert :no_reply = :gen_server.check_response(:unrelated, request)
    assert :timeout = :gen_server.wait_response(request, 0)
    send(pid, :release_request)
    assert_receive reply
    assert {:reply, {:ok, 7}} = :gen_server.check_response(reply, request)
    assert Process.info(self(), :monitors) == before_monitors
    assert {:ok, %{}} = AgentServer.state(pid, &{:ok, &1.signal_subscribers})
    assert :timeout = :gen_server.wait_response(request, 0)
  end

  test "native reply preserves action errors and selector failures", ctx do
    pid = start_server(ctx, TestAgent)
    assert {:ok, request} = AgentServer.send_request(pid, signal("fail"), &value/1)
    assert {:reply, {:error, %Ash.Error.Unknown{}}} = :gen_server.receive_response(request, 1_000)

    assert {:ok, request} =
             AgentServer.send_request(pid, signal("write", %{value: 2}), fn _ ->
               raise "synthetic selector failure"
             end)

    assert {:reply, {:error, {:selector_raised, RuntimeError, frames}}} =
             :gen_server.receive_response(request, 1_000)

    assert Enum.all?(frames, &match?({_, _, arity} when is_integer(arity), &1))
    assert {:ok, 2} = AgentServer.state(pid, &value/1)
  end

  test "abandoning a timed out reply does not roll back the running signal or leak a late reply",
       ctx do
    pid = gated_agent(ctx)
    before_monitors = Process.info(self(), :monitors)
    assert {:ok, request} = AgentServer.send_request(pid, signal("write", %{value: 9}), &value/1)
    assert_receive {:request_waiting, ^pid}
    assert :timeout = :gen_server.receive_response(request, 0)
    assert Process.info(self(), :monitors) == before_monitors
    send(pid, :release_request)
    assert {:ok, 9} = AgentServer.state(pid, &value/1)
    assert :timeout = :gen_server.wait_response(request, 0)
    refute_received {^request, _}
    assert {:ok, %{}} = AgentServer.state(pid, &{:ok, &1.signal_subscribers})
  end

  test "server death returns a native error and removes the request monitor", ctx do
    pid = gated_agent(ctx, restart?: false)
    before_monitors = Process.info(self(), :monitors)
    assert {:ok, request} = AgentServer.send_request(pid, signal("write", %{value: 1}), &value/1)
    assert_receive {:request_waiting, ^pid}
    Process.exit(pid, :kill)
    assert {:error, {:killed, ^pid}} = :gen_server.receive_response(request, 1_000)
    assert Process.info(self(), :monitors) == before_monitors
  end

  test "requester death leaves no subscriber and does not cancel adoption", ctx do
    pid = gated_agent(ctx)
    observer = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        {:ok, _request} = AgentServer.send_request(pid, signal("write", %{value: 11}), &value/1)
        send(observer, :submitted)

        receive do
          :finish -> :ok
        end
      end)

    assert_receive :submitted
    assert_receive {:request_waiting, ^pid}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    send(pid, :release_request)
    assert {:ok, 11} = AgentServer.state(pid, &value/1)
    assert {:ok, %{}} = AgentServer.state(pid, &{:ok, &1.signal_subscribers})
    assert {:monitors, monitors} = Process.info(pid, :monitors)
    refute {:process, caller} in monitors
  end

  defp gated_agent(ctx, opts \\ []) do
    start_server(
      ctx,
      TestAgent,
      Keyword.put(opts, :middleware, [{Aikido.AsyncRequestTest.Gate, %{observer: self()}}])
    )
  end

  defp value(runtime), do: {:ok, runtime.agent.state.app.value}
end
