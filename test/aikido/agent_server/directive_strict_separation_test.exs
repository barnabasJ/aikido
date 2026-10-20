defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest.EmitDirectiveAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    directive =
      input.arguments.directive

    slice = input.arguments.state
    Aikido.Types.ActionResult.new(state: slice || %{}, directives: [directive])
  end
end

defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest.HarnessAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "directive_strict_harness"
    path :domain

    schema do
      attribute :observed, :term, default: nil
    end

    route "test.directive",
          {AikidoTest.AgentServer.DirectiveStrictSeparationTest.HarnessAgent, :emit_directive}
  end

  actions do
    action :emit_directive, Aikido.Types.ActionResult do
      argument :state, :term
      argument :directive, :term, allow_nil?: false

      run AikidoTest.AgentServer.DirectiveStrictSeparationTest.EmitDirectiveAction.Implementation
    end
  end
end

defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest do
  @moduledoc """
  Directives mutate **no** state — neither
  `agent.state` (domain) nor `%AgentServer.State{}` (runtime). The
  `Aikido.Directive.exec/3` contract enforces this in the type system
  (return is `:ok | {:stop, term()}` only).

  Tests the runtime behavior of SpawnAgent, AdoptChild, Cron and CronCancel:

  1. Apply the directive **inside the agent process** via a `state/3`
     selector, capturing pre/post state. Asserts byte-equality — the
     directive's `exec/3` does not mutate.
  2. Separately, assert that the natural cascade
     (`maybe_track_child_started` or `maybe_track_cron_*`) populates the
     relevant field via subscription-based `await_state_value/3`.

  """
  use AikidoTest.Case, async: true

  defp signal_carrying_directive(directive) do
    Aikido.Signal.new!(%{type: "test.directive", source: "/test", data: %{directive: directive}})
  end

  describe("SpawnAgent") do
    test("directive does not write state.children; cascade does", %{aikido: aikido}) do
      pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.DirectiveStrictSeparationTest.HarnessAgent,
          id: "strict-spawn"
        )

      directive = %Aikido.Directives.SpawnAgent{
        agent: AikidoTest.AgentServer.DirectiveStrictSeparationTest.HarnessAgent,
        tag: :worker,
        opts: %{},
        meta: %{}
      }

      assert_no_runtime_mutation(pid, directive, fn s -> s.children end)

      child_info =
        await_state_value(
          pid,
          fn s -> Map.get(s.children, :worker) end,
          pattern: "aikido.agent.child.started"
        )

      assert is_pid(child_info.pid)
      GenServer.stop(child_info.pid)
    end
  end

  describe("AdoptChild") do
    test("directive does not write state.children; cascade does", %{aikido: aikido}) do
      parent_pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.DirectiveStrictSeparationTest.HarnessAgent,
          id: "strict-adopt-parent"
        )

      orphan_pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.DirectiveStrictSeparationTest.HarnessAgent,
          id: "strict-adopt-orphan"
        )

      directive = %Aikido.Directives.AdoptChild{child: orphan_pid, tag: :adopted, meta: %{}}
      assert_no_runtime_mutation(parent_pid, directive, fn s -> s.children end)

      child_info =
        await_state_value(
          parent_pid,
          fn s -> Map.get(s.children, :adopted) end,
          pattern: "aikido.agent.child.started"
        )

      assert child_info.pid == orphan_pid
      GenServer.stop(orphan_pid)
    end
  end

  describe("Cron") do
    test("directive does not write state.cron_*; cascade does", %{aikido: aikido}) do
      pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.DirectiveStrictSeparationTest.HarnessAgent,
          id: "strict-cron"
        )

      directive = %Aikido.Directives.Cron{
        cron: "@hourly",
        message: :tick,
        job_id: :strict_cron,
        timezone: nil
      }

      assert_no_runtime_mutation(pid, directive, fn s ->
        %{
          specs: s.cron_specs,
          jobs: s.cron_jobs,
          monitors: s.cron_monitors,
          monitor_refs: s.cron_monitor_refs,
          runtime_specs: s.cron_runtime_specs
        }
      end)

      cron_pid =
        await_state_value(
          pid,
          fn s -> Map.get(s.cron_jobs, :strict_cron) end,
          pattern: "aikido.agent.cron.registered"
        )

      assert is_pid(cron_pid)

      {:ok, all} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok,
           %{
             specs: Map.has_key?(s.cron_specs, :strict_cron),
             jobs: Map.has_key?(s.cron_jobs, :strict_cron),
             monitors: Map.has_key?(s.cron_monitors, :strict_cron),
             runtime_specs: Map.has_key?(s.cron_runtime_specs, :strict_cron)
           }}
        end)

      assert all.specs
      assert all.jobs
      assert all.monitors
      assert all.runtime_specs

      Aikido.AgentServer.cast(
        pid,
        signal_carrying_directive(%Aikido.Directives.CronCancel{job_id: :strict_cron})
      )
    end
  end

  describe("CronCancel") do
    test("runtime retires ownership before the supervised cancellation completes", %{
      aikido: aikido
    }) do
      pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.DirectiveStrictSeparationTest.HarnessAgent,
          id: "strict-cron-cancel"
        )

      Aikido.AgentServer.cast(
        pid,
        signal_carrying_directive(%Aikido.Directives.Cron{
          cron: "@hourly",
          message: :tick,
          job_id: :cancel_target,
          timezone: nil
        })
      )

      _cron_pid =
        await_state_value(
          pid,
          fn s -> Map.get(s.cron_jobs, :cancel_target) end,
          pattern: "aikido.agent.cron.registered"
        )

      directive = %Aikido.Directives.CronCancel{job_id: :cancel_target}

      assert {:ok, _} =
               Aikido.AgentServer.call(pid, signal_carrying_directive(directive), fn runtime ->
                 {:ok, runtime.cron_jobs}
               end)

      true =
        await_state_value(
          pid,
          fn s ->
            if not Map.has_key?(s.cron_jobs, :cancel_target) do
              true
            end
          end,
          pattern: "aikido.agent.cron.cancelled"
        )

      {:ok, all} =
        Aikido.AgentServer.state(pid, fn s ->
          {:ok,
           %{
             specs: Map.has_key?(s.cron_specs, :cancel_target),
             jobs: Map.has_key?(s.cron_jobs, :cancel_target),
             monitors: Map.has_key?(s.cron_monitors, :cancel_target),
             runtime_specs: Map.has_key?(s.cron_runtime_specs, :cancel_target)
           }}
        end)

      refute all.specs
      refute all.jobs
      refute all.monitors
      refute all.runtime_specs
    end
  end

  defp assert_no_runtime_mutation(pid, directive, projector) do
    input_signal = Aikido.Signal.new!(%{type: "test.harness", source: "/test", data: %{}})

    {:ok, %{before: before_value, after: after_value}} =
      Aikido.AgentServer.state(pid, fn s ->
        before_value = projector.(s)
        :ok = Aikido.Directive.exec(directive, input_signal, s)
        after_value = projector.(s)
        {:ok, %{before: before_value, after: after_value}}
      end)

    assert before_value == after_value
  end
end
