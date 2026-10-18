defmodule AikidoTest.AgentServer.AckSubscribeTest do
  use AikidoTest.Case, async: false
  alias Aikido.AgentServer

  describe "call_until/5" do
    test "subscribes before a command that completes in the same turn", %{aikido: aikido} do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = AgentServer.await_ready(pid)

      assert {:ok, 7} =
               AgentServer.call_until(pid, signal("write", %{value: 7}), "write", fn runtime ->
                 {:ok, runtime.agent.state.app.value}
               end)

      assert {:ok, 0} = AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)})
    end

    test "skip waits for a later signal without polling state", %{aikido: aikido} do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = AgentServer.await_ready(pid)
      caller = self()

      task =
        Task.async(fn ->
          AgentServer.call_until(
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
            end, timeout: 1_000)
        end)

      assert_receive :waiting_for_second_write

      assert {:ok, :processed} =
               AgentServer.call(pid, signal("write", %{value: 2}), fn _ -> {:ok, :processed} end)

      assert {:ok, 2} = Task.await(task)
    end

    test "pipeline errors return immediately and remove the subscription", %{aikido: aikido} do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = AgentServer.await_ready(pid)

      assert {:error, %Ash.Error.Unknown{}} =
               AgentServer.call_until(pid, signal("fail"), "**", fn _ -> :skip end)

      assert_eventually(fn ->
        AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)}) == {:ok, 0}
      end)
    end

    test "timeout releases subscriptions and isolates late replies", %{aikido: aikido} do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = AgentServer.await_ready(pid)

      assert {:error, :timeout} =
               AgentServer.call_until(
                 pid,
                 signal("write", %{value: 1}),
                 "write",
                 fn _ -> :skip end, timeout: 20)

      assert_eventually(fn ->
        AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)}) == {:ok, 0}
      end)

      assert {:ok, 2} =
               AgentServer.call(pid, signal("write", %{value: 2}), fn runtime ->
                 {:ok, runtime.agent.state.app.value}
               end)

      refute_receive {:aikido_subscription, _, _}
    end

    test "server shutdown returns an error instead of exiting the caller", %{aikido: aikido} do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.TestAgent)
      :ok = AgentServer.await_ready(pid)

      assert {:error, {:server_stopped, _reason}} =
               AgentServer.call_until(
                 pid,
                 signal("aikido.agent.stop", %{reason: :normal}),
                 "**",
                 fn _ -> :skip end
               )
    end
  end

  defmodule WriteAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "write"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(%Jido.Signal{data: %{value: v}}, slice, _opts, _ctx) do
      {:ok, %{slice | value: v, status: :written}, []}
    end
  end

  defmodule FailingAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "fail"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    defp reduce(_signal, _slice, _opts, _ctx) do
      {:error, :intentional_action_failure}
    end
  end

  defmodule TestAgent do
    @moduledoc false
    use Aikido.Agent

    agent do
      name("ack_subscribe_agent")
      path(:app)

      schema do
        attribute(:value, :integer, default: 0)
        attribute(:status, :atom, default: :idle)
      end
    end

    signal_routes do
      route("write", AikidoTest.AgentServer.AckSubscribeTest.WriteAction)
      route("fail", AikidoTest.AgentServer.AckSubscribeTest.FailingAction)
    end
  end

  defmodule FlakyAction do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false
    @persist {:aikido_action_metadata, %{name: "flaky"}}
    actions do
      action(:run, Aikido.ActionResult) do
        argument(:state, :term)

        run(fn input, _context ->
          runtime = input.context[:aikido] || %{}
          params = Map.delete(input.arguments, :state)
          signal = Map.fetch!(runtime, :signal)
          signal = %{signal | data: Map.merge(signal.data || %{}, params)}

          case reduce(signal, input.arguments.state, runtime[:action_opts] || %{}, runtime) do
            {:ok, state, directives} ->
              Aikido.ActionResult.new(state: state, directives: directives)

            {:error, _} = error ->
              error

            other ->
              {:error, "Unexpected return shape: #{inspect(other)}"}
          end
        end)
      end
    end

    @counter_key {__MODULE__, :counter}
    def reset(name) do
      :persistent_term.put({@counter_key, name}, :counters.new(1, []))
    end

    def attempts(name) do
      :counters.get(:persistent_term.get({@counter_key, name}), 1)
    end

    defp reduce(%Jido.Signal{data: %{name: name, succeed_after: succeed_after}}, slice, _, _) do
      counter = :persistent_term.get({@counter_key, name})
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      if n >= succeed_after do
        {:ok, %{slice | value: succeed_after, status: :written}, []}
      else
        {:error, :transient}
      end
    end
  end

  defmodule RetryingAgent do
    @moduledoc false
    use Aikido.Agent,
      middleware: [{Aikido.Middlewares.Retry, %{max_attempts: 3, pattern: "flaky"}}]

    agent do
      name("retrying_agent")
      path(:app)

      schema do
        attribute(:value, :integer, default: 0)
        attribute(:status, :atom, default: :idle)
      end
    end

    signal_routes do
      route("flaky", AikidoTest.AgentServer.AckSubscribeTest.FlakyAction)
    end
  end

  describe("call/4") do
    test("runs the selector after the signal completes and returns its value", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.call(
          pid,
          signal("write", %{value: 7}),
          fn %AgentServer.State{agent: agent} ->
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
      pid = start_server(%{aikido: aikido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.call(
          pid,
          signal("write", %{value: 1}),
          fn _state -> {:error, :selector_says_no} end,
          timeout: 1000
        )

      assert {:error, :selector_says_no} = result
    end

    test(
      "delivers {:error, %Aikido.Error{}} verbatim when the action errors; selector is skipped",
      %{aikido: aikido}
    ) do
      pid = start_server(%{aikido: aikido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.call(
          pid,
          signal("fail"),
          fn _state -> {:ok, :selector_should_be_skipped} end,
          timeout: 1000
        )

      assert {:error, %Ash.Error.Unknown{}} = result
    end

    test("subscribers' selectors run even when the chain returned {:error, _}", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, TestAgent)
      :ok = AgentServer.await_ready(pid)
      caller = self()

      {:ok, ref} =
        AgentServer.subscribe(
          pid,
          "fail",
          fn _state ->
            send(caller, :subscriber_ran)
            :skip
          end,
          []
        )

      :ok = AgentServer.cast(pid, signal("fail"))
      assert_receive :subscriber_ran, 1000
      :ok = AgentServer.unsubscribe(pid, ref)
    end

    test(
      "Retry middleware re-invokes next on {:error, _}; selector fires once with the eventual success",
      %{aikido: aikido}
    ) do
      pid = start_server(%{aikido: aikido}, RetryingAgent)
      :ok = AgentServer.await_ready(pid)
      key = {:flaky, System.unique_integer([:positive])}
      FlakyAction.reset(key)

      # The action succeeds on the 4th invocation. Each middleware attempt
      # calls the action ≥1 time (Exec may also retry), so 3 middleware
      # attempts × ≥1 invocation comfortably exceeds 4.
      result =
        AgentServer.call(
          pid,
          signal("flaky", %{name: key, succeed_after: 4}),
          fn %AgentServer.State{agent: agent} ->
            case agent.state.app.status do
              :written -> {:ok, agent.state.app.value}
              _ -> {:error, :not_yet}
            end
          end,
          timeout: 2000
        )

      # Eventual success crosses the boundary as a single reply
      # (Retry retries internally; the outermost return fires the selector once).
      assert {:ok, 4} = result
      assert FlakyAction.attempts(key) >= 4
    end

    test(
      "Retry middleware exhausts max_attempts; caller receives the final {:error, _}",
      %{aikido: aikido}
    ) do
      pid = start_server(%{aikido: aikido}, RetryingAgent)
      :ok = AgentServer.await_ready(pid)
      key = {:flaky, System.unique_integer([:positive])}
      FlakyAction.reset(key)

      result =
        AgentServer.call(
          pid,
          signal("flaky", %{name: key, succeed_after: 9999}),
          fn _state -> {:ok, :should_be_skipped} end,
          timeout: 2000
        )

      assert {:error, %Ash.Error.Unknown{}} = result
      # Three middleware attempts, each may also Exec-retry, so >= 3.
      assert FlakyAction.attempts(key) >= 3
    end

    test(
      "raising selector surfaces as {:error, {:selector_raised, _, _}}; agent stays alive",
      %{aikido: aikido}
    ) do
      pid = start_server(%{aikido: aikido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      result =
        AgentServer.call(
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
      pid = start_server(%{aikido: aikido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      {:ok, ref} =
        AgentServer.subscribe(
          pid,
          "write",
          fn %AgentServer.State{agent: agent} -> {:ok, agent.state.app.value} end,
          once: true
        )

      :ok = AgentServer.cast(pid, signal("write", %{value: 42}))
      assert_receive {:aikido_subscription, ^ref, %{result: {:ok, 42}}}, 5000
    end

    test("with :skip return, keeps the subscription alive across multiple signals", %{
      aikido: aikido
    }) do
      pid = start_server(%{aikido: aikido}, TestAgent)
      :ok = AgentServer.await_ready(pid)
      caller = self()

      {:ok, ref} =
        AgentServer.subscribe(
          pid,
          "write",
          fn %AgentServer.State{agent: agent} ->
            send(caller, {:saw_value, agent.state.app.value})
            :skip
          end,
          []
        )

      :ok = AgentServer.cast(pid, signal("write", %{value: 1}))
      :ok = AgentServer.cast(pid, signal("write", %{value: 2}))
      assert_receive {:saw_value, 1}, 5000
      assert_receive {:saw_value, 2}, 5000
      :ok = AgentServer.unsubscribe(pid, ref)
    end

    test("unsubscribe/2 stops the subscription", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, TestAgent)
      :ok = AgentServer.await_ready(pid)
      {:ok, ref} = AgentServer.subscribe(pid, "write", fn _s -> {:ok, :received} end, [])
      :ok = AgentServer.unsubscribe(pid, ref)
      :ok = AgentServer.cast(pid, signal("write", %{value: 99}))
      refute_receive {:aikido_subscription, ^ref, _}, 200
    end

    test("ignores signals that don't match the pattern", %{aikido: aikido}) do
      pid = start_server(%{aikido: aikido}, TestAgent)
      :ok = AgentServer.await_ready(pid)

      {:ok, ref} =
        AgentServer.subscribe(pid, "specific.path", fn _ -> {:ok, :hit} end, once: true)

      :ok = AgentServer.cast(pid, signal("write", %{value: 1}))
      refute_receive {:aikido_subscription, ^ref, _}, 200
      :ok = AgentServer.unsubscribe(pid, ref)
    end
  end
end
