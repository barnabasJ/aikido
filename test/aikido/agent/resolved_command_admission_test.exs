defmodule Aikido.ResolvedCommandAdmissionTest do
  use AikidoTest.Case, async: false
  alias Aikido.ResolvedCommandAdmissionTest.Domain

  setup do
    start_supervised!(AikidoTest.Support.TestTracer)
    options = Keyword.put(durable_options(), :scope_adapter, AikidoTest.DurableScopeAuthority)

    start_supervised!(
      {Aikido, name: Aikido.ResolvedCommandAdmissionTest.Instance, durable: options}
    )

    actor = %{id: Ash.UUIDv7.generate(), allowed: true}
    {:ok, actor: actor}
  end

  test "inspect reauthorizes its exact replacement PID with the original native scope", ctx do
    old = start_subject(ctx.actor, true, "old")
    observer = self()

    pending =
      Task.async(fn ->
        Domain.subject_inspect(old.id, %{fields: [:label]},
          tracer: AikidoTest.Support.TestTracer,
          scope:
            scope(ctx.actor, %{
              observer: observer,
              marker: "inspect-marker",
              pause_id_check?: true
            })
        )
      end)

    assert_receive {:command_id_check_waiting, policy, old_pid}, 5_000
    assert old_pid == old.pid
    assert_receive {:command_policy_tracers, :inspect, false, ^old_pid, original_tracers}
    assert AikidoTest.Support.TestTracer in original_tracers
    replacement = replace_subject(old, ctx.actor)
    send(policy, :continue_command_id_check)
    assert {:error, %Ash.Error.Forbidden{}} = Task.await(pending, 5_000)

    assert_receive {:command_target_checked, :inspect, true, pid, actor, "command-tenant",
                    "inspect-marker"}

    assert pid == replacement.pid
    assert actor == ctx.actor
    assert_receive {:command_policy_tracers, :inspect, true, ^pid, tracers}
    assert AikidoTest.Support.TestTracer in tracers

    assert {:ok, %{label: "replacement"}} =
             Domain.subject_inspect(replacement.pid, %{fields: [:label]},
               scope: scope(ctx.actor),
               authorize?: false
             )
  end

  test "stop cannot reuse an old incarnation's ID authorization to stop a replacement", ctx do
    old = start_subject(ctx.actor, true, "old")
    observer = self()

    pending =
      Task.async(fn ->
        Domain.subject_stop(%{id: old.id},
          scope:
            scope(ctx.actor, %{observer: observer, marker: "stop-marker", pause_id_check?: true})
        )
      end)

    assert_receive {:command_id_check_waiting, policy, old_pid}, 5_000
    assert old_pid == old.pid
    replacement = replace_subject(old, ctx.actor)
    send(policy, :continue_command_id_check)
    assert {:error, %Ash.Error.Forbidden{}} = Task.await(pending, 5_000)

    assert_receive {:command_target_checked, :stop, true, pid, actor, "command-tenant",
                    "stop-marker"}

    assert pid == replacement.pid
    assert actor == ctx.actor
    pool = Aikido.durable_supervisor_name(Aikido.ResolvedCommandAdmissionTest.Instance)
    assert {:ok, ^pid} = Aikido.Durable.lookup(pool, old.id)
    assert Process.alive?(pid)
  end

  test "allowed exact PID commands still inspect and stop normally", ctx do
    subject = start_subject(ctx.actor, true, "allowed")
    observer = self()

    assert {:ok, %{label: "allowed"}} =
             Domain.subject_inspect(subject.id, %{fields: [:label]},
               scope: scope(ctx.actor, %{observer: observer, marker: "allowed"})
             )

    assert_receive {:command_target_checked, :inspect, true, pid, _, _, "allowed"}
    assert pid == subject.pid

    assert {:ok, %{status: :stopped}} =
             Domain.subject_stop(subject.id,
               scope: scope(ctx.actor, %{observer: observer, marker: "allowed"})
             )

    assert_receive {:command_target_checked, :stop, true, ^pid, _, _, "allowed"}
  end

  test "explicit trusted authorize false bypasses exact PID admission for inspect and stop",
       ctx do
    subject = start_subject(ctx.actor, false, "trusted")
    observer = self()

    options = [
      scope: scope(ctx.actor, %{observer: observer, marker: "trusted"}),
      authorize?: false
    ]

    assert {:ok, %{label: "trusted"}} =
             Domain.subject_inspect(subject.id, %{fields: [:label]}, options)

    assert {:ok, %{status: :stopped}} = Domain.subject_stop(subject.id, options)
    refute_received {:command_target_checked, _, _, _, _, _, "trusted"}
  end

  defp start_subject(actor, visible?, label, id \\ nil) do
    Domain.subject_start!(%{id: id || Ash.UUIDv7.generate(), visible?: visible?, label: label},
      scope: scope(actor)
    )
  end

  defp replace_subject(old, actor) do
    monitor = Process.monitor(old.pid)
    Domain.subject_stop!(old.pid, scope: scope(actor), authorize?: false)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    replacement = start_subject(actor, false, "replacement", old.id)
    assert replacement.pid != old.pid
    replacement
  end

  defp scope(actor, shared \\ %{}),
    do: %{
      actor: actor,
      tenant: "command-tenant",
      context: %{shared: shared}
    }
end
