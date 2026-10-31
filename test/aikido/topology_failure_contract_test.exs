defmodule Aikido.TopologyFailureContractTest.Authority do
  @moduledoc false
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  def prepare(attributes, options, identity) do
    scenario = Keyword.get(options, :context, %{})[:topology_failure_scenario]

    if scenario do
      apply_scenario(scenario, attributes, options, identity)
    else
      AikidoTest.DurableScopeAuthority.prepare(attributes, options, identity)
    end
  end

  defp apply_scenario(%{mode: :refuse}, _attributes, _options, _identity) do
    {:error,
     Aikido.Durable.ScopeAdapter.Error.exception(
       operation: :prepare,
       reason: :synthetic_denial
     )}
  end

  defp apply_scenario(%{mode: :throw, reason: reason}, _attributes, _options, _identity),
    do: throw(reason)

  defp apply_scenario(
         %{mode: :hold, observer: observer, token: token},
         attributes,
         options,
         identity
       ) do
    monitor = Process.monitor(observer)
    send(observer, {:topology_activation_waiting, token, self(), identity.id})

    try do
      receive do
        {:release_topology_activation, ^token, :continue} ->
          AikidoTest.DurableScopeAuthority.prepare(attributes, options, identity)

        {:release_topology_activation, ^token, :abort} ->
          {:error, :synthetic_activation_aborted}

        {:DOWN, ^monitor, :process, ^observer, _reason} ->
          {:error, :synthetic_owner_stopped}
      after
        15_000 -> {:error, :synthetic_gate_timeout}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  @impl true
  defdelegate restore(credential, saved, identity), to: AikidoTest.DurableScopeAuthority

  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority
end

defmodule Aikido.TopologyFailureContractTest.Fixture.Child do
  @moduledoc false
  use Ash.Resource,
    domain: Aikido.TopologyFailureContractTest.Fixture.Domain,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "topology_failure_child"
    instance Aikido.TopologyFailureContractTest.Fixture.Instance

    schema do
      attribute :value, :integer do
        description "Value retained by a real child created through its native resource action."
        default 0
        public? true
      end
    end
  end
end

defmodule Aikido.TopologyFailureContractTest.Fixture.Team do
  @moduledoc false
  use Ash.Resource,
    domain: Aikido.TopologyFailureContractTest.Fixture.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "topology_failure_team"
    instance Aikido.TopologyFailureContractTest.Fixture.Instance
  end

  team do
    worker :child, Aikido.TopologyFailureContractTest.Fixture.Child, max_members: 2
    operation_timeout 5_000
  end
end

defmodule Aikido.TopologyFailureContractTest.Fixture.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Domain.Extension]

  agents do
    agent :topology, Aikido.TopologyFailureContractTest.Fixture.Team
    agent :child, Aikido.TopologyFailureContractTest.Fixture.Child
  end
end

defmodule Aikido.TopologyFailureContractTest do
  use ExUnit.Case, async: true
  import AikidoTest.Case, only: [unique_id: 1]

  alias Aikido.Agent.Errors.RuntimeUnavailable
  alias Aikido.Team.Errors.OperationFailed

  setup context do
    case context[:fixture] do
      nil ->
        :ok

      {instance, domain} ->
        durable =
          AikidoTest.Case.durable_options()
          |> Keyword.put(:scope_adapter, Aikido.TopologyFailureContractTest.Authority)

        runtime = start_supervised!({Aikido, name: instance, durable: durable})
        register_join(runtime)
        attempts = Process.whereis(Aikido.task_supervisor_name(instance))
        assert is_pid(attempts)
        register_join(attempts)
        calls = start_supervised!(Task.Supervisor)
        register_join(calls)

        team =
          domain.topology_start!(
            %{id: unique_id("topology-failure")},
            context: %{aikido_runtime_options: [restart?: false]}
          )

        register_join(team.pid)

        %{
          team: team,
          calls: calls,
          instance: instance,
          domain: domain,
          runtime: runtime,
          attempts: attempts
        }
    end
  end

  @tag :r3_regression
  @tag fixture:
         {Aikido.TopologyFailureContractTest.Fixture.Instance,
          Aikido.TopologyFailureContractTest.Fixture.Domain}
  test "generated add_member preserves runtime loss while actual child activation is waiting",
       ctx do
    assert_runtime_retires(ctx, fn ->
      token = make_ref()
      caller = add_in_background(ctx, %{mode: :hold, observer: self(), token: token})
      assert_receive {:topology_activation_waiting, ^token, activation, child_id}, 5_000
      _activation_monitor = register_join(activation)
      parent_monitor = register_join(ctx.team.pid)

      assert_activation_retires(caller, activation, token, fn ->
        Process.exit(ctx.team.pid, :kill)
        assert_receive {:DOWN, ^parent_monitor, :process, _, :killed}, 5_000
        assert {:error, %Ash.Error.Invalid{} = failure} = Task.await(caller, 7_000)
        assert [%RuntimeUnavailable{reason: {:server_stopped, _reason}}] = leaves(failure)
      end)

      assert :error = lookup(ctx.instance, child_id)
    end)
  end

  @tag :r3_regression
  @tag fixture:
         {Aikido.TopologyFailureContractTest.Fixture.Instance,
          Aikido.TopologyFailureContractTest.Fixture.Domain}
  test "generated add_member retains a real child activation's forbidden classification", ctx do
    assert_runtime_retires(ctx, fn ->
      assert {:error, %Ash.Error.Forbidden{} = failure} =
               ctx.domain.topology_add_member(
                 ctx.team,
                 %{member: "worker", template: :child},
                 context: %{topology_failure_scenario: %{mode: :refuse}}
               )

      assert [%Aikido.Durable.ScopeAdapter.Error{operation: :prepare, reason: :synthetic_denial}] =
               leaves(failure)

      snapshot = ctx.domain.topology_inspect!(ctx.team)
      assert snapshot.team.operation.status == :failed
      assert %Ash.Error.Forbidden{} = snapshot.team.operation.error
      assert snapshot.team.members == %{}
      assert_no_subscriptions(ctx.team.pid)
    end)
  end

  @tag :r3_regression
  @tag fixture:
         {Aikido.TopologyFailureContractTest.Fixture.Instance,
          Aikido.TopologyFailureContractTest.Fixture.Domain}
  test "actual AsyncTask topology failure retains its opaque reason behind safe public projections",
       ctx do
    assert_runtime_retires(ctx, fn ->
      secret = "SYNTHETIC-R3-ONLY"
      original = {:synthetic_topology_failure, %{credential: secret}}

      assert {:error, %Ash.Error.Invalid{} = failure} =
               ctx.domain.topology_add_member(
                 ctx.team,
                 %{member: "worker", template: :child},
                 context: %{topology_failure_scenario: %{mode: :throw, reason: original}}
               )

      assert [%{__struct__: OperationFailed} = typed] = leaves(failure)
      assert typed.reason == original
      snapshot = ctx.domain.topology_inspect!(ctx.team)
      assert snapshot.team.operation.error == typed.reason
      assert snapshot.team.members == %{}
      assert_safe_error(typed, failure, secret, "team_operation_failed")
      assert_no_subscriptions(ctx.team.pid)
    end)
  end

  @tag fixture:
         {Aikido.TopologyFailureContractTest.Fixture.Instance,
          Aikido.TopologyFailureContractTest.Fixture.Domain}
  test "known topology validation messages and successful receipts remain unchanged", ctx do
    assert_runtime_retires(ctx, fn ->
      assert {:ok, %{status: :processed}} =
               ctx.domain.topology_add_member(
                 ctx.team,
                 %{member: "worker", template: :child}
               )

      snapshot = ctx.domain.topology_inspect!(ctx.team)
      assert is_pid(snapshot.team.members["worker"])
      assert snapshot.team.operation.status == :completed

      assert {:error, %{errors: [%Ash.Error.Action.InvalidArgument{} = duplicate]}} =
               ctx.domain.topology_add_member(
                 ctx.team,
                 %{member: "worker", template: :child}
               )

      assert duplicate.field == :member

      assert duplicate.message ==
               "Member worker already exists. Inspect the roster and reuse it, or choose a different name."

      assert {:error, %{errors: [%Ash.Error.Action.InvalidArgument{} = unavailable]}} =
               ctx.domain.topology_add_member(
                 ctx.team,
                 %{member: "other", template: :missing}
               )

      assert unavailable.field == :template

      assert unavailable.message ==
               "Unknown worker template :missing. Choose one of the configured templates: [:child]."

      for _ <- 1..2 do
        assert {:ok, %{status: :processed}} = ctx.domain.topology_reconcile(ctx.team)

        assert ctx.domain.topology_inspect!(ctx.team).team.operation.status ==
                 :completed
      end

      assert_no_subscriptions(ctx.team.pid)
    end)
  end

  @tag fixture:
         {Aikido.TopologyFailureContractTest.Fixture.Instance,
          Aikido.TopologyFailureContractTest.Fixture.Domain}
  test "actual operation timeout keeps the existing ambiguous-activation warning", ctx do
    assert_runtime_retires(ctx, fn ->
      token = make_ref()
      caller = add_in_background(ctx, %{mode: :hold, observer: self(), token: token})
      assert_receive {:topology_activation_waiting, ^token, activation, child_id}, 5_000
      _activation_monitor = register_join(activation)

      assert_activation_retires(caller, activation, token, fn ->
        assert {:error, %{errors: [%Ash.Error.Action.InvalidArgument{} = timeout]}} =
                 Task.await(caller, 8_000)

        assert timeout.message ==
                 "Team activation timed out. Inspect the roster before retrying; a member may already have started."

        assert ctx.domain.topology_inspect!(ctx.team).team.operation.error == :timeout
        assert_no_subscriptions(ctx.team.pid)
      end)

      assert :error = lookup(ctx.instance, child_id)
    end)
  end

  test "private native runtime reasons retain their exact term without entering public displays" do
    secret = "SYNTHETIC-RUNTIME-ONLY"
    reason = {:server_stopped, {:synthetic_exit, %{credential: secret}}}
    error = RuntimeUnavailable.exception(reason: reason)
    assert error.reason == reason
    assert_safe_error(error, Ash.Error.to_error_class(error), secret, "agent_runtime_unavailable")
  end

  defp add_in_background(ctx, scenario) do
    Task.Supervisor.async_nolink(ctx.calls, fn ->
      ctx.domain.topology_add_member(
        ctx.team,
        %{member: "worker", template: :child},
        context: %{topology_failure_scenario: scenario}
      )
    end)
  end

  defp lookup(instance, id) do
    Aikido.Durable.lookup(Aikido.durable_supervisor_name(instance), id)
  end

  defp assert_activation_retires(caller, activation, token, assertions) do
    errors = collect_failure(assertions)
    send(activation, {:release_topology_activation, token, :abort})

    errors =
      errors ++
        Enum.flat_map(
          [
            fn -> assert :ok = AikidoTest.LifecycleWait.await_down(caller.pid, 10_000) end,
            fn -> assert :ok = AikidoTest.LifecycleWait.await_down(activation, 10_000) end
          ],
          &collect_failure/1
        )

    report_failures(errors)
  end

  defp assert_runtime_retires(ctx, assertions) do
    errors = collect_failure(assertions)

    errors =
      errors ++
        Enum.flat_map(
          [
            fn -> assert :ok = stop_supervised(ctx.instance) end,
            fn -> assert :ok = stop_supervised(Task.Supervisor) end,
            fn -> assert :ok = AikidoTest.LifecycleWait.await_down(ctx.calls, 10_000) end,
            fn -> assert :ok = AikidoTest.LifecycleWait.await_down(ctx.runtime, 10_000) end,
            fn -> assert :ok = AikidoTest.LifecycleWait.await_down(ctx.attempts, 10_000) end
          ],
          &collect_failure/1
        )

    report_failures(errors)
  end

  defp collect_failure(operation) do
    operation.()
    []
  catch
    :error, %ExUnit.MultiError{errors: errors} -> errors
    kind, reason -> [{kind, reason, __STACKTRACE__}]
  end

  defp report_failures([]), do: :ok
  defp report_failures([{kind, reason, stacktrace}]), do: :erlang.raise(kind, reason, stacktrace)
  defp report_failures(errors), do: raise(ExUnit.MultiError, errors: errors)

  defp register_join(pid) do
    on_exit(fn -> assert :ok = AikidoTest.LifecycleWait.await_down(pid, 10_000) end)
    Process.monitor(pid)
  end

  defp assert_no_subscriptions(pid) do
    assert {:ok, 0} = Aikido.AgentServer.state(pid, &{:ok, map_size(&1.signal_subscribers)})
  end

  defp leaves(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &leaves/1)
  defp leaves(error), do: [error]

  defp assert_safe_error(error, aggregate, secret, code) do
    for rendered <- [
          inspect(error),
          Exception.message(error),
          inspect(aggregate),
          Exception.message(aggregate),
          AshAi.ToToolError.to_tool_error(error),
          AshAi.ToToolError.to_tool_error(aggregate),
          inspect(AshLua.Error.to_error(error)),
          inspect(AshLua.Encoder.encode_error(aggregate))
        ] do
      refute rendered =~ secret
    end

    assert %{code: ^code, vars: vars} = AshLua.Error.to_error(error)
    assert vars == %{}
  end
end
