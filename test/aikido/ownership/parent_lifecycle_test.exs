defmodule AikidoTest.Ownership.ParentLifecycleTest do
  use AikidoTest.Case, async: true
  alias Aikido.Ownership.{ParentRef, Slice}
  alias AikidoTest.TestAgents.Basic

  setup context do
    owner = start_server(context, Basic, id: "child")
    parent = start_server(context, Basic, id: "parent")
    {:ok, slice} = Aikido.AgentServer.state(owner, &{:ok, &1.agent.state.ownership})
    parent_ref = ParentRef.new!(%{pid: parent, id: "parent", tag: :worker})
    {:ok, owner: owner, parent: parent, parent_ref: parent_ref, slice: slice}
  end

  test "parent exit before monitor acknowledgement releases a late acknowledgement", context do
    ref = Process.monitor(context.parent)
    on_exit(fn -> Process.demonitor(ref, [:flush]) end)

    attached =
      transition(context, context.slice, :configure, %{
        parent: context.parent_ref,
        on_parent_death: :continue
      })

    assert [%Aikido.Ownership.Directives.MonitorParent{pid: pid}] = attached.directives
    assert pid == context.parent

    exited =
      transition(context, attached.state, :parent_died, %{
        former_parent: context.parent_ref,
        monitor_ref: ref,
        reason: :normal
      })

    assert exited.state.parent == nil
    assert exited.state.orphaned_from == context.parent_ref

    late =
      transition(context, exited.state, :parent_monitored, %{pid: context.parent, ref: ref})

    assert late.state == exited.state
    assert [%Aikido.Directives.Demonitor{ref: ^ref}] = late.directives

    repaired =
      transition(context, late.state, :attach_parent, %{
        parent: context.parent_ref,
        initial_only?: true
      })

    assert repaired.state == late.state
    assert repaired.directives == []
  end

  test "an unrelated monitor exit cannot orphan the current parent binding", context do
    ref = Process.monitor(context.parent)
    on_exit(fn -> Process.demonitor(ref, [:flush]) end)

    attached =
      transition(context, context.slice, :configure, %{
        parent: context.parent_ref,
        on_parent_death: :continue
      })

    monitored =
      transition(context, attached.state, :parent_monitored, %{pid: context.parent, ref: ref})

    stale =
      transition(context, monitored.state, :parent_died, %{
        former_parent: context.parent_ref,
        monitor_ref: make_ref(),
        reason: :normal
      })

    assert stale.state == monitored.state
    assert stale.directives == []
    saved = Slice.externalize(monitored.state)
    assert saved.parent == nil
    assert saved.parent_monitor == nil
    assert saved.on_parent_death == :continue
  end

  test "rejected attachment reports the existing parent and recovery guidance", context do
    assert {:ok, _} = Aikido.AgentServer.adopt_parent(context.owner, context.parent_ref)
    assert {:error, error} = Aikido.AgentServer.adopt_parent(context.owner, context.parent_ref)

    failure =
      Enum.find(error.errors, &match?(%Aikido.Ownership.Errors.AttachmentRejected{}, &1))

    assert failure.reason == :already_attached
    assert failure.current_parent_id == "parent"
    assert Exception.message(failure) =~ "already attached"
    assert Exception.message(failure) =~ "Reuse the existing relationship"
    assert AshAi.ToToolError.to_tool_error(failure) =~ "parent"
    assert AshLua.Error.to_error(failure).code == "parent_attachment_rejected"
  end

  defp transition(context, slice, action, arguments) do
    input =
      Ash.ActionInput.for_action(Slice, action, Map.put(arguments, :state, slice),
        context: %{
          aikido: %{
            agent_id: "child",
            agent_pid: context.owner,
            agent_module: Basic,
            partition: nil
          }
        }
      )

    result = Ash.run_action!(input)
    assert result == Ash.run_action!(input)
    result
  end
end
