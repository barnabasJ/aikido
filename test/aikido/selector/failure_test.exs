defmodule AikidoTest.SelectorFailure.Signals.Bump do
  use Aikido.Signal

  signal do
    type "selector.bump"

    schema do
      attribute :payload, :string do
        description "Synthetic input available to an execution-aware selector."
      end
    end
  end
end

defmodule AikidoTest.SelectorFailure.Bump do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context),
    do: Aikido.Types.ActionResult.new(changes: %{count: input.arguments.state.count + 1})
end

defmodule AikidoTest.SelectorFailure.Agent do
  use Aikido.Agent

  agent do
    name "selector_failure"

    schema do
      attribute :count, :integer do
        description "Committed updates observed after a failing selector."
        default 0
      end

      attribute :synthetic_value, :string do
        description "Synthetic private fixture data that must not enter generated failures."
      end
    end

    route AikidoTest.SelectorFailure.Signals.Bump, AikidoTest.SelectorFailure.Bump
  end
end

defmodule AikidoTest.SelectorFailure.Callback do
  @canary "SYNTHETIC-SELECTOR-CANARY-3197"

  def raise_with_state(state), do: :erlang.error({:synthetic_failure, @canary}, [state])

  def raise_with_event(state, event),
    do: :erlang.error({:synthetic_failure, @canary}, [state, event])

  def throw_value(_state), do: throw({:synthetic_failure, @canary})
  def exit_value(_state), do: exit({:synthetic_failure, @canary})
end

defmodule AikidoTest.SelectorFailureTest do
  use AikidoTest.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias Aikido.{AgentServer, Inspector}
  alias Aikido.Selector.Failure
  alias AikidoTest.SelectorFailure.{Agent, Callback}

  @canary "SYNTHETIC-SELECTOR-CANARY-3197"

  defp start(context),
    do: start_server(context, Agent, initial_state: %{synthetic_value: @canary})

  defp bump, do: signal("selector.bump", %{payload: @canary})

  defp assert_frames(frames) do
    assert frames != []

    assert Enum.all?(frames, fn
             {module, function, arity}
             when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0 ->
               true

             _other ->
               false
           end)
  end

  defp log_safe(result) do
    refute inspect(result) =~ @canary
    Logger.error("Synthetic selector diagnostic: #{inspect(result)}")
  end

  test "projection omits exception payloads, frame arguments and metadata" do
    exception = RuntimeError.exception(@canary)

    stack = [
      {Callback, :raise_with_state, [%{nested: @canary}], [file: @canary, line: 7]},
      {Callback, :raise_with_event, 2, [file: @canary]},
      {Callback, :throw_value, [@canary]},
      {:unsupported_frame, @canary}
    ]

    expected = [
      {Callback, :raise_with_state, 1},
      {Callback, :raise_with_event, 2},
      {Callback, :throw_value, 1}
    ]

    logs =
      capture_log(fn ->
        assert {:error, {:selector_raised, RuntimeError, ^expected}} =
                 result = Failure.raised(exception, stack)

        log_safe(result)
        assert {:error, {:selector_failed, :throw, ^expected}} = Failure.failed(:throw, stack)
      end)

    refute logs =~ @canary
    assert logs =~ "RuntimeError"
    assert logs =~ "raise_with_state"
  end

  test "call and state selectors return safe classes and MFAs without losing committed state",
       context do
    pid = start(context)

    logs =
      capture_log(fn ->
        for result <- [
              AgentServer.state(pid, &Callback.raise_with_state/1),
              AgentServer.call(pid, bump(), &Callback.raise_with_state/1)
            ] do
          assert {:error, {:selector_raised, ErlangError, frames}} = result
          assert_frames(frames)
          assert {Callback, :raise_with_state, 1} in frames
          log_safe(result)
        end
      end)

    refute logs =~ @canary
    assert {:ok, 1} = AgentServer.state(pid, &{:ok, &1.agent.state.state.count})
    assert Process.alive?(pid)
  end

  test "both subscription selector arities deliver safe failures and retain native cleanup",
       context do
    pid = start(context)

    logs =
      capture_log(fn ->
        for selector <- [&Callback.raise_with_state/1, &Callback.raise_with_event/2] do
          {:ok, ref} = AgentServer.subscribe(pid, "selector.bump", selector, once: true)
          assert {:ok, :processed} = AgentServer.call(pid, bump(), fn _ -> {:ok, :processed} end)

          assert_receive {:aikido_subscription, ^ref, %{result: result}}
          assert {:error, {:selector_raised, ErlangError, frames}} = result
          assert_frames(frames)
          log_safe(result)
        end
      end)

    refute logs =~ @canary

    assert {:ok, {2, 0}} =
             AgentServer.state(
               pid,
               &{:ok, {&1.agent.state.state.count, map_size(&1.signal_subscribers)}}
             )
  end

  test "inspector retains only safe projection failures for raises, throws and exits", context do
    pid = start(context)

    logs =
      capture_log(fn ->
        for {callback, tag, class} <- [
              {&Callback.raise_with_state/1, :selector_raised, ErlangError},
              {&Callback.throw_value/1, :selector_failed, :throw},
              {&Callback.exit_value/1, :selector_failed, :exit}
            ] do
          projection = fn runtime, event ->
            if event.signal.type == "selector.bump", do: callback.(runtime), else: :skip
          end

          {:ok, ref} = Inspector.attach(pid, projection, flush_interval_ms: 1)

          try do
            assert {:ok, :processed} =
                     AgentServer.call(pid, bump(), fn _ -> {:ok, :processed} end)

            assert_receive {:aikido_inspection, ^ref, %{entries: [entry]}}, 2_000
            assert {:error, {^tag, ^class, frames}} = entry.result
            assert_frames(frames)
            log_safe(entry.result)
          after
            Inspector.detach(ref)
          end
        end
      end)

    refute logs =~ @canary
    assert Process.alive?(pid)
  end

  test "thrown and exited values are contained across call, state and subscription selectors",
       context do
    pid = start(context)

    logs =
      capture_log(fn ->
        for {callback, kind} <- [
              {&Callback.throw_value/1, :throw},
              {&Callback.exit_value/1, :exit}
            ] do
          {:ok, ref} =
            AgentServer.subscribe(pid, "selector.bump", fn runtime, _ -> callback.(runtime) end,
              once: true
            )

          for result <- [
                AgentServer.state(pid, callback),
                AgentServer.call(pid, bump(), callback)
              ] do
            assert {:error, {:selector_failed, ^kind, frames}} = result
            assert_frames(frames)
            log_safe(result)
          end

          assert_receive {:aikido_subscription, ^ref, %{result: result}}
          assert {:error, {:selector_failed, ^kind, frames}} = result
          assert_frames(frames)
          log_safe(result)
        end
      end)

    refute logs =~ @canary
    assert Process.alive?(pid)
  end

  test "successful values, explicit errors and skip remain selector-owned", context do
    pid = start(context)
    assert {:ok, @canary} = AgentServer.state(pid, fn _ -> {:ok, @canary} end)
    assert {:error, :chosen_error} = AgentServer.state(pid, fn _ -> {:error, :chosen_error} end)

    {:ok, skipped} = AgentServer.subscribe(pid, "selector.bump", fn _ -> :skip end)

    {:ok, explicit} =
      AgentServer.subscribe(pid, "selector.bump", fn _ -> {:error, :chosen_error} end, once: true)

    assert {:error, :chosen_error} =
             AgentServer.call(pid, bump(), fn _ -> {:error, :chosen_error} end)

    assert_receive {:aikido_subscription, ^explicit, %{result: {:error, :chosen_error}}}
    refute_receive {:aikido_subscription, ^skipped, _}
    assert :ok = AgentServer.unsubscribe(pid, skipped)
  end
end
