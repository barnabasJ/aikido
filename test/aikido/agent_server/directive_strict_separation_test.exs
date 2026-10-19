defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest.EmitDirectiveAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    directive =
      case Map.fetch(input.arguments, :directive) do
        {:ok, value} -> value
        :error -> input.context.aikido.signal.data[:directive]
      end

    slice = input.arguments.state
    Aikido.ActionResult.new(state: slice || %{}, directives: [directive])
  end
end

defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest.EmitDirectiveAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :emit_directive, Aikido.ActionResult do
      argument :state, :term
      argument :directive, :term, allow_nil?: false

      run {AikidoTest.AgentServer.DirectiveStrictSeparationTest.EmitDirectiveAction.Implementation,
           action: :run}
    end
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
  end

  signal_routes do
    route "test.directive",
          AikidoTest.AgentServer.DirectiveStrictSeparationTest.EmitDirectiveAction
  end
end

defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest.SuccessAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    Aikido.ActionResult.new(state: %{ran: true}, directives: [])
  end
end

defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest.SuccessAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :strict_success, Aikido.ActionResult do
      argument :state, :term

      run {AikidoTest.AgentServer.DirectiveStrictSeparationTest.SuccessAction.Implementation,
           action: :run}
    end
  end
end

defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest.CaptureAction.Implementation do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    params =
      Map.merge(input.context.aikido.signal.data || %{}, Map.delete(input.arguments, :state))

    slice = input.arguments.state
    slice = slice || %{}
    Aikido.ActionResult.new(state: Map.put(slice, :captured, params.status), directives: [])
  end
end

defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest.CaptureAction do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, validate_domain_inclusion?: false

  actions do
    action :strict_capture, Aikido.ActionResult do
      argument :state, :term
      argument :status, :atom, allow_nil?: false
      argument :result, :map, default: %{}
      argument :reason, :term, default: nil
      argument :effects, :term, default: []
      argument :instruction, :term, default: nil
      argument :meta, :map, default: %{}

      run {AikidoTest.AgentServer.DirectiveStrictSeparationTest.CaptureAction.Implementation,
           action: :run}
    end
  end
end

defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest.RoutedAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "strict_routed_agent"
    path :domain

    schema do
      attribute :captured, :atom, default: nil
    end
  end

  signal_routes do
    route "test.directive",
          AikidoTest.AgentServer.DirectiveStrictSeparationTest.EmitDirectiveAction

    route "test.routed.captured",
          AikidoTest.AgentServer.DirectiveStrictSeparationTest.CaptureAction
  end
end

defmodule AikidoTest.AgentServer.DirectiveStrictSeparationTest do
  @moduledoc """
  Directives mutate **no** state — neither
  `agent.state` (domain) nor `%AgentServer.State{}` (runtime). The
  `Aikido.Directive.exec/3` contract enforces this in the type system
  (return is `:ok | {:stop, term()}` only).

  Tests the runtime behavior of SpawnAgent, AdoptChild, Cron, CronCancel
  and RunInstruction:

  1. Apply the directive **inside the agent process** via a `state/3`
     selector, capturing pre/post state. Asserts byte-equality — the
     directive's `exec/3` does not mutate.
  2. Separately, assert that the natural cascade
     (`maybe_track_child_started`, `maybe_track_cron_*`, or the routed
     handler action for RunInstruction) eventually populates the
     relevant field via subscription-based `await_state_value/3`.

  StartNode/StopNode have their own test in
  `test/aikido/ash_team_test.exs`.
  """
  use AikidoTest.Case, async: true

  defp signal_carrying_directive(directive) do
    Jido.Signal.new!(%{type: "test.directive", source: "/test", data: %{directive: directive}})
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
    test("directive does not write state.cron_*; cascade does", %{aikido: aikido}) do
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

      {:ok, %{before: before_state, after: after_state}} =
        Aikido.AgentServer.state(pid, fn s ->
          before_state = %{specs: s.cron_specs, jobs: s.cron_jobs, monitors: s.cron_monitors}
          input_signal = Jido.Signal.new!(%{type: "test.harness", source: "/test", data: %{}})
          :ok = Aikido.Directive.exec(directive, input_signal, s)
          after_state = %{specs: s.cron_specs, jobs: s.cron_jobs, monitors: s.cron_monitors}
          {:ok, %{before: before_state, after: after_state}}
        end)

      assert before_state == after_state

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

  describe("RunInstruction") do
    test("directive does not write agent.state; the routed action does", %{aikido: aikido}) do
      pid =
        start_server(
          %{aikido: aikido},
          AikidoTest.AgentServer.DirectiveStrictSeparationTest.RoutedAgent,
          id: "strict-run-instr"
        )

      instruction =
        Aikido.Instruction.new!(%{
          action: AikidoTest.AgentServer.DirectiveStrictSeparationTest.SuccessAction
        })

      directive =
        Aikido.Directives.run_instruction(instruction,
          result_signal_type: "test.routed.captured",
          meta: %{}
        )

      input_signal = Jido.Signal.new!(%{type: "test.harness", source: "/test", data: %{}})

      {:ok, %{before: before_domain, after: after_domain}} =
        Aikido.AgentServer.state(pid, fn s ->
          before_domain = s.agent.state
          :ok = Aikido.Directive.exec(directive, input_signal, s)
          {:ok, %{before: before_domain, after: s.agent.state}}
        end)

      assert before_domain == after_domain

      captured =
        await_state_value(
          pid,
          fn s -> s.agent.state.domain.captured end,
          pattern: "test.routed.captured"
        )

      assert captured == :ok
    end
  end

  defp assert_no_runtime_mutation(pid, directive, projector) do
    input_signal = Jido.Signal.new!(%{type: "test.harness", source: "/test", data: %{}})

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
