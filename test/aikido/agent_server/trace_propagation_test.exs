defmodule AikidoTest.TracePropagation.Work do
  require Ash.Tracer

  def run(amount) do
    Ash.Tracer.span :custom, "test.async_work", AikidoTest.Support.TestTracer do
      {:ok, %{value: amount * 2}}
    end
  end
end

defmodule AikidoTest.TracePropagation.Pipeline.Actions.BeginWork do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | status: :working},
      directives: [
        %Aikido.Directives.AsyncTask{
          work: {AikidoTest.TracePropagation.Work, :run, [input.arguments.amount]},
          success_type: "trace.completed"
        }
      ]
    )
  end
end

defmodule AikidoTest.TracePropagation.Pipeline.Actions.AcceptResult do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    value = input.arguments.result.value

    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | status: :finishing},
      directives: [
        %Aikido.Directives.Schedule{
          delay_ms: 0,
          message: %Aikido.Signal{
            id: nil,
            type: "trace.finished",
            data: %{value: value},
            source: "/test"
          }
        }
      ]
    )
  end
end

defmodule AikidoTest.TracePropagation.Pipeline.Actions.Finish do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{input.arguments.state | status: :completed, value: input.arguments.value}
    )
  end
end

defmodule AikidoTest.TracePropagation.Pipeline.Actions.Fail do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context) do
    raise "trace failure"
  end
end

defmodule AikidoTest.TracePropagation.Pipeline do
  use Ash.Resource,
    domain: AikidoTest.TracePropagation.Domain,
    extensions: [Aikido.Ash.Agent]

  agent do
    name "trace_pipeline"
    instance AikidoTest.TracePropagation.Instance

    schema do
      attribute :status, :atom do
        description "Current lifecycle or processing status of the fixture."
        default :idle
      end

      attribute :value, :integer do
        description "Domain value used to verify state transitions and native contracts."
        default 0
      end
    end

    route "trace.start", :begin_work, name: :work
    route "trace.fail", :fail, name: :fail_work
    route "trace.completed", :accept_result, public?: false
    route "trace.finished", :finish, public?: false
  end

  actions do
    action :begin_work, Aikido.Types.ActionResult do
      argument :state, :term
      argument :amount, :integer, allow_nil?: false
      run AikidoTest.TracePropagation.Pipeline.Actions.BeginWork
    end

    action :accept_result, Aikido.Types.ActionResult do
      argument :state, :term
      argument :result, :map, allow_nil?: false
      run AikidoTest.TracePropagation.Pipeline.Actions.AcceptResult
    end

    action :finish, Aikido.Types.ActionResult do
      argument :state, :term
      argument :value, :integer, allow_nil?: false
      run AikidoTest.TracePropagation.Pipeline.Actions.Finish
    end

    action :fail, Aikido.Types.ActionResult do
      argument :state, :term
      run AikidoTest.TracePropagation.Pipeline.Actions.Fail
    end
  end
end

defmodule AikidoTest.TracePropagation.Domain do
  use Ash.Domain, extensions: [Aikido.Ash.Domain], validate_config_inclusion?: false

  agents do
    agent :pipeline, AikidoTest.TracePropagation.Pipeline
  end
end

defmodule AikidoTest.AgentServer.TracePropagationTest do
  use ExUnit.Case, async: false
  require Ash.Tracer

  alias AikidoTest.TracePropagation.Domain
  alias AikidoTest.Support.TestTracer

  setup do
    start_supervised!(TestTracer)
    instance = AikidoTest.TracePropagation.Instance
    start_supervised!({Aikido, name: instance, durable: AikidoTest.Case.durable_options()})
    reference = Domain.pipeline_start!(%{id: "traced"})
    :ok = Aikido.AgentServer.await_ready(reference.pid)
    %{reference: reference}
  end

  test "one native Ash trace connects the external action, async effect, result signals and final state",
       %{reference: reference} do
    previous = TestTracer.get_span_context()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:aikido, :agent_server, :directive, :start],
          [:aikido, :agent_server, :directive, :stop]
        ],
        fn event, _, metadata, pid -> send(pid, {handler, event, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Ash.Tracer.span :custom, "test.external_caller", TestTracer do
      caller = TestTracer.get_span_context()

      assert {:ok, sub} =
               Aikido.AgentServer.subscribe(
                 reference.pid,
                 "trace.finished",
                 fn runtime ->
                   {:ok, runtime.agent.state.state}
                 end,
                 once: true
               )

      assert %{status: :processed} =
               Domain.pipeline_work!(reference, %{amount: 21}, tracer: TestTracer)

      assert TestTracer.get_span_context() == caller

      assert_receive {:aikido_subscription, ^sub,
                      %{result: {:ok, %{status: :completed, value: 42}}}},
                     5_000

      # A mailbox barrier ensures the finishing signal's span has closed.
      assert {:ok, :ready} = Aikido.AgentServer.state(reference.pid, fn _ -> {:ok, :ready} end)
    end

    assert TestTracer.get_span_context() == previous
    spans = spans()
    root = only(spans, &(&1.name == "test.external_caller"))
    external = only(spans, &(&1.type == :action && &1.metadata[:action] == :work))
    first = only(spans, &(&1.type == {:custom, :aikido_signal} && &1.name == "trace.start"))
    reducer = only(spans, &(&1.type == :action && &1.metadata[:action] == :begin_work))

    async_directive =
      only(
        spans,
        &(&1.type == {:custom, :aikido_directive} && &1.name == "Aikido.Directives.AsyncTask")
      )

    async = only(spans, &(&1.type == {:custom, :aikido_async_task}))
    work = only(spans, &(&1.name == "test.async_work"))

    result =
      only(spans, &(&1.type == {:custom, :aikido_signal} && &1.name == "trace.completed"))

    accept = only(spans, &(&1.type == :action && &1.metadata[:action] == :accept_result))

    schedule =
      only(
        spans,
        &(&1.type == {:custom, :aikido_directive} && &1.name == "Aikido.Directives.Schedule")
      )

    finished = only(spans, &(&1.type == {:custom, :aikido_signal} && &1.name == "trace.finished"))
    final_action = only(spans, &(&1.type == :action && &1.metadata[:action] == :finish))

    assert external.parent == root.id
    assert first.parent == external.id
    assert reducer.parent == first.id
    assert async_directive.parent == first.id
    assert async.parent == async_directive.id
    assert work.parent == async.id
    assert result.parent == async.id
    assert accept.parent == result.id
    assert schedule.parent == result.id
    assert finished.parent == schedule.id
    assert final_action.parent == finished.id
    assert first.pid == reference.pid
    assert reducer.pid == reference.pid
    assert async.pid != reference.pid
    assert work.pid == async.pid
    assert result.pid == reference.pid
    assert final_action.pid == reference.pid
    AikidoTest.LifecycleWait.await_down(async.pid)
    assert Enum.all?(spans(), & &1.stopped?)
    assert is_binary(first.metadata.signal_id)
    assert is_binary(result.metadata.signal_id)
    refute first.metadata.signal_id == result.metadata.signal_id

    for phase <- [:start, :stop] do
      origin_id = first.metadata.signal_id

      assert_receive {^handler, [:aikido, :agent_server, :directive, ^phase],
                      %{signal_type: "trace.start", signal_id: ^origin_id}}

      result_id = result.metadata.signal_id

      assert_receive {^handler, [:aikido, :agent_server, :directive, ^phase],
                      %{signal_type: "trace.completed", signal_id: ^result_id}}
    end
  end

  @tag capture_log: true
  test "a failed turn restores native context and does not parent the next untraced call", %{
    reference: reference
  } do
    Ash.Tracer.span :custom, "test.failed_caller", TestTracer do
      caller = TestTracer.get_span_context()
      assert {:error, _} = Domain.pipeline_fail_work(reference, %{}, tracer: TestTracer)
      assert TestTracer.get_span_context() == caller
    end

    signal = Aikido.Signal.new!("trace.fail", %{}) |> Aikido.Signal.put(:tracer, TestTracer)

    assert {:error, _} =
             Aikido.AgentServer.call(reference.pid, signal, fn _ -> {:ok, :unused} end)

    failures =
      Enum.filter(spans(), &(&1.type == {:custom, :aikido_signal} && &1.name == "trace.fail"))

    assert length(failures) == 2
    assert Enum.count(failures, &is_nil(&1.parent)) == 1
    assert TestTracer.get_span_context() == nil
  end

  defp only(spans, predicate) do
    assert [span] = Enum.filter(spans, predicate)
    span
  end

  defp spans do
    events = TestTracer.get_spans()

    for {:start, id, type, name} <- events do
      {:parent, ^id, parent, pid} = Enum.find(events, &match?({:parent, ^id, _, _}, &1))

      metadata =
        for {:metadata, ^id, _, metadata} <- Enum.reverse(events), reduce: %{} do
          acc -> Map.merge(acc, metadata)
        end

      %{
        id: id,
        type: type,
        name: name,
        parent: parent,
        pid: pid,
        metadata: metadata,
        stopped?: {:stop, id} in events
      }
    end
  end
end
