defmodule AikidoTest.AgentServer.AckSubscribeTest.WriteAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    v =
      input.arguments.value

    slice = input.arguments.state
    Aikido.Types.ActionResult.new(state: %{slice | value: v, status: :written}, directives: [])
  end
end

defmodule AikidoTest.AgentServer.AckSubscribeTest.FailingAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _opts, _context) do
    {:error, :intentional_action_failure}
  end
end

defmodule AikidoTest.AgentServer.AckSubscribeTest.TestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "ack_subscribe_agent"
    path :app

    schema do
      attribute :value, :integer do
        description "Domain value used to verify state transitions and native contracts."
        default 0
      end

      attribute :status, :atom do
        description "Current lifecycle or processing status of the fixture."
        default :idle
      end
    end

    route "write", {AikidoTest.AgentServer.AckSubscribeTest.TestAgent, :write}
    route "fail", {AikidoTest.AgentServer.AckSubscribeTest.TestAgent, :fail}
  end

  actions do
    action :write, Aikido.Types.ActionResult do
      argument :state, :term
      argument :value, :integer, allow_nil?: false
      run AikidoTest.AgentServer.AckSubscribeTest.WriteAction.Implementation
    end

    action :fail, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.AgentServer.AckSubscribeTest.FailingAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServer.AckSubscribeTest do
  use AikidoTest.Case, async: false

  describe("call_until/5") do
    test("subscribes before a command that completes in the same turn", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)

      assert {:ok, 7} =
               Aikido.AgentServer.call_until(
                 pid,
                 signal("write", %{value: 7}),
                 "write",
                 fn runtime -> {:ok, runtime.agent.state.app.value} end
               )

      assert {:ok, 0} = Aikido.AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)})
    end

    test("skip waits for a later signal through its subscription", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)
      caller = self()

      task =
        Task.async(fn ->
          Aikido.AgentServer.call_until(
            pid,
            signal("write", %{value: 1}),
            "write",
            fn runtime ->
              case runtime.agent.state.app.value do
                1 ->
                  send(caller, :waiting_for_second_write)
                  :skip

                value ->
                  {:ok, value}
              end
            end,
            timeout: 1000
          )
        end)

      assert_receive :waiting_for_second_write

      assert {:ok, :processed} =
               Aikido.AgentServer.call(pid, signal("write", %{value: 2}), fn _ ->
                 {:ok, :processed}
               end)

      assert {:ok, 2} = Task.await(task)
    end

    test("pipeline errors return immediately and remove the subscription", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)

      assert {:error, %Ash.Error.Unknown{}} =
               Aikido.AgentServer.call_until(pid, signal("fail"), "**", fn _ -> :skip end)

      assert {:ok, 0} =
               Aikido.AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)})
    end

    test("timeout releases subscriptions and isolates late replies", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)

      assert {:error, :timeout} =
               Aikido.AgentServer.call_until(
                 pid,
                 signal("write", %{value: 1}),
                 "write",
                 fn _ -> :skip end,
                 timeout: 20
               )

      assert {:ok, 0} =
               Aikido.AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)})

      assert {:ok, 2} =
               Aikido.AgentServer.call(pid, signal("write", %{value: 2}), fn runtime ->
                 {:ok, runtime.agent.state.app.value}
               end)

      refute_receive {:aikido_subscription, _, _}
    end

    test("server shutdown returns an error instead of exiting the caller", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)

      assert {:error, {:server_stopped, _reason}} =
               Aikido.AgentServer.call_until(
                 pid,
                 signal("aikido.agent.stop", %{reason: :normal}),
                 "**",
                 fn _ -> :skip end
               )
    end
  end

  describe("call/4") do
    test("runs the selector after the signal completes and returns its value", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)

      result =
        Aikido.AgentServer.call(
          pid,
          signal("write", %{value: 7}),
          fn %Aikido.AgentServer.State{agent: agent} ->
            case agent.state.app.status do
              :written -> {:ok, agent.state.app.value}
              _ -> {:error, :not_yet}
            end
          end,
          timeout: 5000
        )

      assert {:ok, 7} = result
    end

    test("returns {:error, reason} when the selector returns an error tuple", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)

      result =
        Aikido.AgentServer.call(
          pid,
          signal("write", %{value: 1}),
          fn _state -> {:error, :selector_says_no} end,
          timeout: 1000
        )

      assert {:error, :selector_says_no} = result
    end

    test(
      "delivers the native Ash error when the action fails; selector is skipped",
      %{aikido: aikido}
    ) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)

      result =
        Aikido.AgentServer.call(
          pid,
          signal("fail"),
          fn _state -> {:ok, :selector_should_be_skipped} end,
          timeout: 1000
        )

      assert {:error, %Ash.Error.Unknown{}} = result
    end

    test("subscribers' selectors run even when the chain returned {:error, _}", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)
      caller = self()

      {:ok, ref} =
        Aikido.AgentServer.subscribe(
          pid,
          "fail",
          fn _state ->
            send(caller, :subscriber_ran)
            :skip
          end,
          []
        )

      :ok = Aikido.AgentServer.cast(pid, signal("fail"))
      assert_receive :subscriber_ran, 1000
      :ok = Aikido.AgentServer.unsubscribe(pid, ref)
    end

    test(
      "raising selector surfaces as {:error, {:selector_raised, _, _}}; agent stays alive",
      %{aikido: aikido}
    ) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)

      result =
        Aikido.AgentServer.call(
          pid,
          signal("write", %{value: 9}),
          fn _state -> raise "selector boom" end,
          timeout: 1000
        )

      assert {:error, {:selector_raised, %RuntimeError{message: "selector boom"}, _stacktrace}} =
               result

      assert Process.alive?(pid)
    end
  end

  describe("subscribe/4") do
    test("delivers a result on the first matching signal when once: true", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)

      {:ok, ref} =
        Aikido.AgentServer.subscribe(
          pid,
          "write",
          fn %Aikido.AgentServer.State{agent: agent} -> {:ok, agent.state.app.value} end,
          once: true
        )

      :ok = Aikido.AgentServer.cast(pid, signal("write", %{value: 42}))
      assert_receive {:aikido_subscription, ^ref, %{result: {:ok, 42}}}, 5000
    end

    test("with :skip return, keeps the subscription alive across multiple signals", %{
      aikido: aikido
    }) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)
      caller = self()

      {:ok, ref} =
        Aikido.AgentServer.subscribe(
          pid,
          "write",
          fn %Aikido.AgentServer.State{agent: agent} ->
            send(caller, {:saw_value, agent.state.app.value})
            :skip
          end,
          []
        )

      :ok = Aikido.AgentServer.cast(pid, signal("write", %{value: 1}))
      :ok = Aikido.AgentServer.cast(pid, signal("write", %{value: 2}))
      assert_receive {:saw_value, 1}, 5000
      assert_receive {:saw_value, 2}, 5000
      :ok = Aikido.AgentServer.unsubscribe(pid, ref)
    end

    test("unsubscribe/2 stops the subscription", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)
      {:ok, ref} = Aikido.AgentServer.subscribe(pid, "write", fn _s -> {:ok, :received} end, [])
      :ok = Aikido.AgentServer.unsubscribe(pid, ref)
      :ok = Aikido.AgentServer.cast(pid, signal("write", %{value: 99}))
      refute_receive {:aikido_subscription, ^ref, _}, 200
    end

    test("ignores signals that don't match the pattern", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = Aikido.AgentServer.await_ready(pid)

      {:ok, ref} =
        Aikido.AgentServer.subscribe(pid, "specific.path", fn _ -> {:ok, :hit} end, once: true)

      :ok = Aikido.AgentServer.cast(pid, signal("write", %{value: 1}))
      refute_receive {:aikido_subscription, ^ref, _}, 200
      :ok = Aikido.AgentServer.unsubscribe(pid, ref)
    end
  end
end
