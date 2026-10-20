defmodule AikidoTest.ObserverSafety.Reducer do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    directives =
      for label <- [:first, :second] do
        %Aikido.Directives.Emit{
          signal: %Jido.Signal{
            id: nil,
            source: "/observer",
            type: "observer.effect",
            data: %{label: label}
          },
          dispatch: {:pid, target: input.arguments.target}
        }
      end

    Aikido.Types.ActionResult.new(
      state: %{count: input.arguments.state.count + 1},
      directives: directives
    )
  end
end

defmodule AikidoTest.ObserverSafety.Agent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "observer_safety"

    schema do
      attribute :count, :integer, default: 0
    end

    route "observer.increment", :increment
  end

  actions do
    action :increment, Aikido.Types.ActionResult do
      argument :state, :term, allow_nil?: false
      argument :target, :term, allow_nil?: false
      run AikidoTest.ObserverSafety.Reducer
    end
  end
end

defmodule AikidoTest.ObserverSafetyTest do
  use AikidoTest.Case, async: false
  require Ash.Tracer

  for mode <- [:call, :cast] do
    test "raising subscription preserves committed state and effects through #{mode}", context do
      pid = start_server(context, AikidoTest.ObserverSafety.Agent)

      {:ok, ref} =
        Aikido.AgentServer.subscribe(pid, "observer.increment", fn _ -> raise "bad observer" end,
          once: true
        )

      input = signal("observer.increment", %{target: self()})

      case unquote(mode) do
        :call ->
          assert {:ok, 1} =
                   Aikido.AgentServer.call(pid, input, &{:ok, &1.agent.state.state.count})

        :cast ->
          assert :ok = Aikido.AgentServer.cast(pid, input)
      end

      assert_receive {:aikido_subscription, ^ref,
                      %{result: {:error, {:selector_raised, %RuntimeError{}, _stack}}}}

      assert_receive {:signal, %{type: "observer.effect", data: %{label: :first}}}
      assert_receive {:signal, %{type: "observer.effect", data: %{label: :second}}}

      assert {:ok, {1, 0}} =
               Aikido.AgentServer.state(
                 pid,
                 &{:ok, {&1.agent.state.state.count, map_size(&1.signal_subscribers)}}
               )

      refute_receive {:signal, %{type: "observer.effect"}}
      assert Process.alive?(pid)
    end
  end

  test "directive debug records are retained in execution order", context do
    pid = start_server(context, AikidoTest.ObserverSafety.Agent, debug: true)

    assert {:ok, _} =
             Aikido.AgentServer.call(
               pid,
               signal("observer.increment", %{target: self()}),
               &{:ok, &1.agent.state.state.count}
             )

    assert {:ok, events} = Aikido.AgentServer.recent_events(pid)

    types =
      events
      |> Enum.reverse()
      |> Enum.filter(
        &(&1.data[:signal_type] == "observer.increment" || &1.data[:type] == "observer.increment")
      )
      |> Enum.map(& &1.type)

    assert types == [:signal_received, :directive_started, :directive_started]
  end

  test "disabled debug does not allocate directive records", context do
    pid = start_server(context, AikidoTest.ObserverSafety.Agent)

    assert {:ok, _} =
             Aikido.AgentServer.call(
               pid,
               signal("observer.increment", %{target: self()}),
               &{:ok, &1.agent.state.state.count}
             )

    assert {:ok, []} = Aikido.AgentServer.state(pid, &{:ok, &1.debug_events})
  end

  test "custom subscriber delivery cannot block the mailbox and retains tracing", context do
    pid = start_server(context, AikidoTest.ObserverSafety.Agent)
    start_supervised!(AikidoTest.Support.TestTracer)
    parent = self()

    formatter = fn notification ->
      send(parent, {:adapter_waiting, self(), AikidoTest.Support.TestTracer.get_span_context()})

      receive do
        :release -> {:signal, notification}
      end
    end

    {:ok, ref} =
      Aikido.AgentServer.subscribe(pid, "observer.increment", &{:ok, &1.agent.state.state.count},
        once: true,
        dispatch: {:pid, target: self(), message_format: formatter}
      )

    Ash.Tracer.span :custom, "observer.external", AikidoTest.Support.TestTracer do
      Aikido.AgentServer.cast(
        pid,
        signal("observer.increment", %{target: self()})
        |> Aikido.SignalCtx.put_ctx(%{tracer: AikidoTest.Support.TestTracer})
      )
    end

    assert_receive {:adapter_waiting, worker, trace_context}
    on_exit(fn -> if Process.alive?(worker), do: send(worker, :release) end)
    refute worker == pid
    spans = AikidoTest.Support.TestTracer.get_spans()
    assert {:start, trace_context, {:custom, :aikido_signal}, "observer.increment"} in spans

    external =
      Enum.find_value(spans, fn
        {:start, ref, :custom, "observer.external"} -> ref
        _ -> nil
      end)

    assert {:parent, trace_context, external, pid} in spans

    assert {:ok, {1, 0}} =
             Aikido.AgentServer.state(
               pid,
               &{:ok, {&1.agent.state.state.count, map_size(&1.signal_subscribers)}}
             )

    send(worker, :release)

    assert_receive {:signal,
                    %{type: "aikido.subscription.fire", data: %{sub_ref: ^ref, result: {:ok, 1}}}}
  end
end
