defmodule AikidoTest.AgentServer.AckSubscribeTest.WriteAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    v =
      case Map.fetch(input.arguments, :value) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:value]
      end

    slice = input.arguments.state
    Aikido.ActionResult.new(state: %{slice | value: v, status: :written}, directives: [])
  end
end

defmodule AikidoTest.AgentServer.AckSubscribeTest.WriteAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :write, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServer.AckSubscribeTest.WriteAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AgentServer.AckSubscribeTest.FailingAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    {:error, :intentional_action_failure}
  end
end

defmodule AikidoTest.AgentServer.AckSubscribeTest.FailingAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :fail, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServer.AckSubscribeTest.FailingAction.Implementation, action: :run}
    end
  end
end

defmodule AikidoTest.AgentServer.AckSubscribeTest.TestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "ack_subscribe_agent"
    path :app

    schema do
      attribute :value, :integer, default: 0
      attribute :status, :atom, default: :idle
    end
  end

  signal_routes do
    route "write", AikidoTest.AgentServer.AckSubscribeTest.WriteAction
    route "fail", AikidoTest.AgentServer.AckSubscribeTest.FailingAction
  end
end

defmodule AikidoTest.AgentServer.AckSubscribeTest.FlakyAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @counter_key {AikidoTest.AgentServer.AckSubscribeTest.FlakyAction, :counter}
  @impl true
  def run(input, _opts, _context) do
    name =
      case Map.fetch(input.arguments, :name) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:name]
      end

    succeed_after =
      case Map.fetch(input.arguments, :succeed_after) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:succeed_after]
      end

    slice = input.arguments.state
    counter = :persistent_term.get({@counter_key, name})
    :counters.add(counter, 1, 1)
    n = :counters.get(counter, 1)

    if n >= succeed_after do
      Aikido.ActionResult.new(
        state: %{slice | value: succeed_after, status: :written},
        directives: []
      )
    else
      {:error, :transient}
    end
  end
end

defmodule AikidoTest.AgentServer.AckSubscribeTest.FlakyAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :flaky, Aikido.ActionResult do
      argument :state, :term
      run {AikidoTest.AgentServer.AckSubscribeTest.FlakyAction.Implementation, action: :run}
    end
  end

  @counter_key {__MODULE__, :counter}
  def reset(name) do
    :persistent_term.put({@counter_key, name}, :counters.new(1, []))
  end

  def attempts(name) do
    :counters.get(:persistent_term.get({@counter_key, name}), 1)
  end
end

defmodule AikidoTest.AgentServer.AckSubscribeTest.RetryingAgent do
  @moduledoc false
  use Aikido.Agent, middleware: [{Aikido.Middlewares.Retry, %{max_attempts: 3, pattern: "flaky"}}]

  agent do
    name "retrying_agent"
    path :app

    schema do
      attribute :value, :integer, default: 0
      attribute :status, :atom, default: :idle
    end
  end

  signal_routes do
    route "flaky", AikidoTest.AgentServer.AckSubscribeTest.FlakyAction
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

    test("skip waits for a later signal without polling state", %{aikido: aikido}) do
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

      assert_eventually(fn ->
        Aikido.AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)}) == {:ok, 0}
      end)
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

      assert_eventually(fn ->
        Aikido.AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)}) == {:ok, 0}
      end)

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
      "delivers {:error, %Aikido.Error{}} verbatim when the action errors; selector is skipped",
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
      "Retry middleware re-invokes next on {:error, _}; selector fires once with the eventual success",
      %{aikido: aikido}
    ) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.RetryingAgent)
      :ok = Aikido.AgentServer.await_ready(pid)
      key = {:flaky, System.unique_integer([:positive])}
      AikidoTest.AgentServer.AckSubscribeTest.FlakyAction.reset(key)

      result =
        Aikido.AgentServer.call(
          pid,
          signal("flaky", %{name: key, succeed_after: 4}),
          fn %Aikido.AgentServer.State{agent: agent} ->
            case agent.state.app.status do
              :written -> {:ok, agent.state.app.value}
              _ -> {:error, :not_yet}
            end
          end,
          timeout: 2000
        )

      assert {:ok, 4} = result
      assert AikidoTest.AgentServer.AckSubscribeTest.FlakyAction.attempts(key) >= 4
    end

    test(
      "Retry middleware exhausts max_attempts; caller receives the final {:error, _}",
      %{aikido: aikido}
    ) do
      pid = start_server(%{aikido: aikido}, AikidoTest.AgentServer.AckSubscribeTest.RetryingAgent)
      :ok = Aikido.AgentServer.await_ready(pid)
      key = {:flaky, System.unique_integer([:positive])}
      AikidoTest.AgentServer.AckSubscribeTest.FlakyAction.reset(key)

      result =
        Aikido.AgentServer.call(
          pid,
          signal("flaky", %{name: key, succeed_after: 9999}),
          fn _state -> {:ok, :should_be_skipped} end,
          timeout: 2000
        )

      assert {:error, %Ash.Error.Unknown{}} = result
      assert AikidoTest.AgentServer.AckSubscribeTest.FlakyAction.attempts(key) >= 3
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
