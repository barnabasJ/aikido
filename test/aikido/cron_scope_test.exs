defmodule Aikido.CronScopeTest.Register do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, _context) do
    Aikido.Types.ActionResult.new(
      state: input.arguments.state,
      directives: [
        %Aikido.Directives.Cron{
          cron: "@yearly",
          message: input.arguments.message,
          job_id: input.arguments.job_id
        }
      ]
    )
  end
end

defmodule Aikido.CronScopeTest.Observe do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, context) do
    observation = %{
      actor_id: context.actor && context.actor.id,
      tenant: context.tenant,
      marker: input.context[:marker],
      authorize?: context.authorize?,
      tracers: List.wrap(context.tracer),
      data: input.arguments.data
    }

    Aikido.Types.ActionResult.new(
      state: %{observations: input.arguments.state.observations ++ [observation]}
    )
  end
end

defmodule Aikido.CronScopeTest.Resource do
  use Aikido.Agent

  agent do
    name "cron_scope"

    schema do
      attribute :observations, {:array, :map} do
        description "Safe native scope observations from scheduler deliveries."
        default []
      end
    end

    route "scope.register", :register
    route "scope.tick", :observe
    route "aikido.cron_tick", :observe
  end

  schedules do
    schedule "@yearly", "scope.tick", job_id: :static
  end

  actions do
    action :register, Aikido.Types.ActionResult do
      argument :state, :term
      argument :message, :term, allow_nil?: false
      argument :job_id, :atom, allow_nil?: false
      run Aikido.CronScopeTest.Register
    end

    action :observe, Aikido.Types.ActionResult do
      argument :state, :term
      argument :data, :map, default: %{}
      run Aikido.CronScopeTest.Observe
    end
  end
end

defmodule Aikido.CronScopeTest do
  use AikidoTest.Case, async: false

  alias Aikido.{AgentServer, Durable, Signal}
  alias AikidoTest.Support.TestTracer

  setup do
    start_supervised!(TestTracer)
    :ok
  end

  test "real scheduler callbacks retain native caller scope for signals and raw messages", ctx do
    pid = start_server(ctx, __MODULE__.Resource)
    parent = make_ref()
    TestTracer.set_span_context(parent)
    on_exit(fn -> TestTracer.set_span_context(nil) end)

    for {job_id, message, expected} <- [
          {:signal, %Signal{type: "scope.tick", data: %{value: 1}}, %{value: 1}},
          {:raw, :wake_up, %{job_id: :raw, message: :wake_up}}
        ] do
      job = register(pid, job_id, message, scope())
      observed = tick(pid, job)
      assert observed.actor_id == "alice"
      assert observed.tenant == "org-a"
      assert observed.marker == "origin"
      assert observed.authorize? == false
      assert TestTracer in observed.tracers
      assert observed.data == expected
    end

    spans = TestTracer.get_spans()
    parents = Map.new(for {:parent, ref, ancestor, _pid} <- spans, do: {ref, ancestor})

    observe_spans =
      for {:metadata, ref, :action, %{resource: __MODULE__.Resource, action: :observe}} <- spans,
          do: ref

    assert length(observe_spans) == 2
    assert Enum.all?(observe_spans, &descendant?(&1, parent, parents))
  end

  test "explicit message scope wins and live scheduler replacement retains inherited scope",
       ctx do
    pid = start_server(ctx, __MODULE__.Resource)

    message = %Signal{
      type: "scope.tick",
      scope: %{actor: %{id: "bob"}, tenant: "org-b", context: %{marker: "explicit"}}
    }

    job = register(pid, :override, message, scope())
    observed = tick(pid, job)
    assert %{actor_id: "bob", tenant: "org-b", marker: "explicit", authorize?: false} = observed

    job = register(pid, :inherited, %Signal{type: "scope.tick"}, scope())
    observed = tick(pid, job)
    assert %{actor_id: "alice", tenant: "org-a", marker: "origin"} = observed

    Process.exit(job, :kill)

    replacement =
      await_state_value(
        pid,
        fn runtime ->
          current = runtime.cron_jobs[:inherited]
          if is_pid(current) && current != job, do: current
        end,
        timeout: 6_000
      )

    assert tick(pid, replacement) == observed
  end

  test "snapshots exclude implicit caller credentials and recovery starts without that scope",
       ctx do
    id = unique_id("cron-scope")
    pid = start_server(ctx, __MODULE__.Resource, id: id)
    parent = make_ref()
    TestTracer.set_span_context(parent)
    on_exit(fn -> TestTracer.set_span_context(nil) end)

    message = %Signal{type: "scope.tick", data: %{declarative: true}}
    _job = register(pid, :durable, message, scope())
    _raw_job = register(pid, :raw, :wake_up, scope())
    supervisor = Aikido.durable_supervisor_name(ctx.aikido)

    # A new mailbox request observes the completed registration checkpoint.
    assert {:ok, ^message} = AgentServer.state(pid, &{:ok, &1.cron_specs.durable.message})

    {key, _} =
      Enum.find(DurableServer.Supervisor.global_members(supervisor), fn {_, {member, _}} ->
        member == pid
      end)

    assert {:ok, info} = DurableServer.Supervisor.get_server_info(supervisor, key)
    saved = Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state)
    assert saved.cron_specs.durable.message == message
    assert saved.cron_specs.raw.message == :wake_up
    refute Map.has_key?(saved, :cron_runtime_specs)
    refute inspect(saved) =~ "actor-private-marker"
    refute inspect(saved) =~ "context-private-marker"
    refute inspect(saved) =~ "unrelated-request-payload"
    refute runtime_term?(saved)

    TestTracer.set_span_context(nil)
    assert :ok = Durable.stop(supervisor, pid)
    assert {:ok, restored} = Durable.ensure_started(supervisor, id, agent: __MODULE__.Resource)
    assert :ok = AgentServer.await_ready(restored)

    assert {:ok, job} = AgentServer.state(restored, &{:ok, &1.cron_jobs.durable})
    observed = tick(restored, job)
    assert %{actor_id: nil, tenant: nil, marker: nil, tracers: []} = observed
    assert observed.data == %{declarative: true}
    assert {:ok, raw_job} = AgentServer.state(restored, &{:ok, &1.cron_jobs.raw})

    assert %{actor_id: nil, tenant: nil, marker: nil, tracers: [], data: data} =
             tick(restored, raw_job)

    assert data == %{job_id: :raw, message: :wake_up}
    assert :ok = Durable.stop(supervisor, restored)
  end

  test "static schedules do not inherit initialization scope", ctx do
    pid =
      start_server(ctx, __MODULE__.Resource, initialization_options: Ash.Scope.to_opts(scope()))

    assert :ok = AgentServer.await_ready(pid)

    assert {:ok, job} =
             AgentServer.state(pid, fn runtime ->
               {:ok,
                Enum.find_value(runtime.cron_runtime_specs, fn {key, spec} ->
                  if spec.kind == :schedule, do: runtime.cron_jobs[key]
                end)}
             end)

    assert %{actor_id: nil, tenant: nil, marker: nil, tracers: []} = tick(pid, job)
  end

  defp scope do
    %{
      actor: %{id: "alice", credential: "actor-private-marker"},
      tenant: "org-a",
      authorize?: false,
      tracer: TestTracer,
      context: %{
        marker: "origin",
        credential: "context-private-marker",
        callback: fn -> :runtime_only end,
        observer: self()
      }
    }
  end

  defp register(pid, job_id, message, scope) do
    signal =
      Signal.new!("scope.register", %{
        job_id: job_id,
        message: message,
        unrelated: "unrelated-request-payload"
      })
      |> Signal.put_ctx(scope)

    assert {:ok, job} =
             AgentServer.call_until(pid, signal, "aikido.agent.cron.registered", fn runtime ->
               case runtime.cron_jobs[job_id] do
                 nil -> :skip
                 job -> {:ok, job}
               end
             end)

    job
  end

  defp tick(pid, job) do
    assert {:ok, before} =
             AgentServer.state(pid, &{:ok, length(&1.agent.state.state.observations)})

    assert {:ok, observation} =
             AgentServer.call_until(
               pid,
               fn ->
                 send(job, :tick)
                 :ok
               end,
               "**",
               fn runtime ->
                 observations = runtime.agent.state.state.observations
                 if length(observations) > before, do: {:ok, List.last(observations)}, else: :skip
               end
             )

    observation
  end

  defp descendant?(ref, ancestor, _parents) when ref == ancestor, do: true
  defp descendant?(nil, _ancestor, _parents), do: false

  defp descendant?(ref, ancestor, parents),
    do: descendant?(Map.get(parents, ref), ancestor, parents)

  defp runtime_term?(term)
       when is_pid(term) or is_reference(term) or is_port(term) or is_function(term),
       do: true

  defp runtime_term?(term) when is_map(term), do: Enum.any?(Map.to_list(term), &runtime_term?/1)
  defp runtime_term?(term) when is_tuple(term), do: runtime_term?(Tuple.to_list(term))
  defp runtime_term?(term) when is_list(term), do: Enum.any?(term, &runtime_term?/1)
  defp runtime_term?(_), do: false
end
