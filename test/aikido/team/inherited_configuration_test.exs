defmodule Aikido.InheritedConfigurationTest do
  use AikidoTest.Case, async: false
  require Ash.Tracer
  alias Aikido.InheritedConfigurationTest.{Access, Domain}

  setup do
    options =
      Keyword.put(durable_options(), :scope_adapter, Aikido.InheritedConfigurationTest.Authority)

    start_supervised!({Aikido, name: Aikido.Default, durable: options})
    root_actor = actor()
    child_actor = actor()
    {:ok, root_actor: root_actor, child_actor: child_actor}
  end

  test "tracked reconciliation reaches retained nested agents and preserves explicit member overrides",
       ctx do
    root = start_tree(ctx)
    Domain.root_stop!(root, scope: scope(ctx.root_actor))

    restored =
      Domain.root_start!(%{id: root.id, actor_id: ctx.root_actor.id},
        scope: scope(ctx.root_actor)
      )

    result = Domain.root_reconcile(restored, %{}, scope: scope(ctx.root_actor))
    team = snapshot(restored.pid).team

    branch_operation =
      case team.members[:branch] do
        pid when is_pid(pid) -> snapshot(pid).team.operation
        _ -> :branch_not_running
      end

    assert match?({:ok, _}, result),
           "Restored reconciliation failed: parent=#{inspect(team.operation, limit: :infinity)} branch=#{inspect(branch_operation, limit: :infinity)}"

    Domain.root_configure_storage!(restored, %{storage_id: "updated", storage_replay?: true},
      scope: scope(ctx.root_actor)
    )

    Domain.root_reconcile_inherited!(restored, %{}, scope: scope(ctx.root_actor))
    assert snapshot(restored.pid).team.operation.status == :completed
    branch = snapshot(restored.pid).team.members.branch
    leaf = snapshot(branch).team.members.leaf
    assert own(branch).storage_id == "updated"
    assert own(branch).storage_replay?
    assert own(leaf).storage_id == "updated"
    assert own(leaf).storage_replay?
    override = snapshot(restored.pid).team.members.override
    assert own(override).storage_id == "explicit-member-destination"
    assert own(branch).actor_id == ctx.child_actor.id
    assert own(leaf).actor_id == ctx.child_actor.id
  end

  test "root completion waits until the nested leaf finishes its receiving middleware", ctx do
    root = start_tree(ctx)
    branch = snapshot(root.pid).team.members.branch
    leaf = snapshot(branch).team.members.leaf
    Domain.root_configure_storage!(root, %{storage_id: "awaited"}, scope: scope(ctx.root_actor))
    Process.register(self(), Aikido.InheritedConfigurationTest.InheritanceObserver)
    on_exit(fn -> send(leaf, :release_leaf_inheritance) end)

    task =
      Task.async(fn ->
        Domain.root_reconcile_inherited!(root, %{}, scope: scope(ctx.root_actor))
      end)

    assert_receive {:leaf_inheritance_waiting, ^leaf}, 5_000
    assert snapshot(root.pid).team.operation.status == :running
    assert snapshot(branch).team.operation.status == :running
    task_ref = task.ref
    refute_received {^task_ref, _}
    send(leaf, :release_leaf_inheritance)
    Task.await(task, 5_000)
    assert snapshot(root.pid).team.operation.status == :completed
    assert own(leaf).storage_id == "awaited"
  end

  test "default empty reconciliation opt-in leaves running members unchanged", ctx do
    root =
      Domain.opt_out_start!(
        %{
          id: ctx.root_actor.id,
          actor_id: ctx.root_actor.id,
          topology: %{
            worker: %{
              resource: Aikido.InheritedConfigurationTest.Worker,
              initial_state: %{actor_id: ctx.child_actor.id}
            }
          }
        },
        scope: scope(ctx.root_actor)
      )

    worker = snapshot(root.pid).team.members.worker

    Domain.opt_out_configure_storage!(root, %{storage_id: "updated"},
      scope: scope(ctx.root_actor)
    )

    Domain.opt_out_reconcile_inherited!(root, %{}, scope: scope(ctx.root_actor))
    assert own(worker).storage_id == "initial"
    assert snapshot(root.pid).team.operation.status == :completed
  end

  test "native receiving casts reject incompatible inherited values", ctx do
    root = start_tree(ctx)
    branch = snapshot(root.pid).team.members.branch

    Domain.root_configure_storage!(root, %{storage_id: %{invalid: "not a string"}},
      scope: scope(ctx.root_actor)
    )

    assert {:error, _} = Domain.root_reconcile_inherited(root, %{}, scope: scope(ctx.root_actor))
    assert snapshot(root.pid).team.operation.status == :failed
    assert own(branch).storage_id == "initial"
  end

  test "a revoked receiving actor rejects even an unchanged inherited value", ctx do
    root = start_tree(ctx)
    branch = snapshot(root.pid).team.members.branch
    access = Ash.get!(Access, ctx.child_actor.id, authorize?: false)
    Ash.update!(access, %{active?: false}, authorize?: false)
    assert {:error, _} = Domain.root_reconcile_inherited(root, %{}, scope: scope(ctx.root_actor))
    assert snapshot(root.pid).team.operation.status == :failed
    assert own(branch).storage_id == "initial"
  end

  test "direct typed inheritance cannot forge the coordinator delivery marker", ctx do
    root = start_tree(ctx)
    branch = snapshot(root.pid).team.members.branch

    signal =
      Aikido.Agent.Signals.Inherit.new!(
        %{
          operation_id: "fabricated",
          member: :branch,
          changes: %{storage_id: "forged"}
        },
        scope:
          Map.put(scope(ctx.child_actor), :__delivery__, %{
            protocol: Aikido.Team.Delivery,
            kind: :inheritance
          })
      )

    assert {:error, %Ash.Error.Forbidden{}} =
             Aikido.AgentServer.call(branch, signal, &{:ok, &1.agent})

    assert own(branch).storage_id == "initial"
  end

  test "actorless initial topology retains authenticated tenant and application context" do
    root =
      Domain.tenant_team_start!(%{id: Ash.UUIDv7.generate()},
        tenant: "tenant-only",
        context: %{shared: %{boot?: true}}
      )

    assert snapshot(root.pid).team.operation.status == :completed
    assert {:ok, nil} = Aikido.AgentServer.state(root.pid, &{:ok, &1.startup_operation})
  end

  test "initial topology retains a caller-only native tracer across the receiver scope boundary",
       ctx do
    tracer = AikidoTest.Support.TestTracer
    start_supervised!(tracer)

    root =
      Ash.Tracer.span :custom, "test.team_boot", tracer do
        Domain.opt_out_start!(%{id: ctx.root_actor.id, actor_id: ctx.root_actor.id},
          scope: scope(ctx.root_actor),
          tracer: tracer
        )
      end

    assert {:ok, :ready} = Aikido.AgentServer.state(root.pid, fn _ -> {:ok, :ready} end)
    events = tracer.get_spans()

    assert [{:start, signal_span, _, _}] =
             Enum.filter(events, fn
               {:start, _, {:custom, :aikido_signal}, "aikido.ash.team.start"} -> true
               _ -> false
             end)

    assert {:parent, ^signal_span, parent, pid} =
             Enum.find(events, &match?({:parent, ^signal_span, _, _}, &1))

    assert pid == root.pid
    assert is_reference(parent)
  end

  test "fresh child topology uses child authority without rebinding public configuration callers",
       ctx do
    root = start_tree(ctx)
    branch = snapshot(root.pid).team.members.branch
    before = snapshot(branch).team.topology

    reference = %{
      id: "#{root.id}/branch",
      pid: branch,
      resource: Aikido.InheritedConfigurationTest.Branch
    }

    assert {:error, %Ash.Error.Forbidden{}} =
             Domain.branch_configure_topology(reference, %{topology: before.nodes},
               scope: scope(ctx.root_actor)
             )

    assert snapshot(branch).team.topology == before

    Domain.branch_configure_topology!(reference, %{topology: before.nodes},
      scope: scope(ctx.child_actor)
    )

    assert {:ok, nil} = Aikido.AgentServer.state(branch, &{:ok, &1.startup_operation})
    assert {:ok, nil} = Aikido.AgentServer.state(root.pid, &{:ok, &1.startup_operation})
  end

  test "failed nested initial configuration cleans up under its issued identity", ctx do
    attributes = %{
      id: ctx.root_actor.id,
      actor_id: ctx.root_actor.id,
      storage_id: "reject-initial",
      topology: %{
        branch: %{
          resource: Aikido.InheritedConfigurationTest.Branch,
          initial_state: %{actor_id: ctx.child_actor.id}
        }
      }
    }

    assert {:error, error} = Domain.root_start(attributes, scope: scope(ctx.root_actor))
    refute inspect(error) =~ "StartupCleanupFailed"
    pool = Aikido.durable_supervisor_name(Aikido.Default)
    assert :error = Aikido.Durable.lookup(pool, ctx.root_actor.id)
    assert :error = Aikido.Durable.lookup(pool, "#{ctx.root_actor.id}/branch")
  end

  test "an early failed boot consumes its owned cleanup marker exactly once", ctx do
    pool = Aikido.durable_supervisor_name(Aikido.Default)
    id = "#{ctx.root_actor.id}/early-boot"

    assert {:ok, pid} =
             Aikido.Durable.start(pool, id,
               agent: Aikido.InheritedConfigurationTest.Branch,
               initial_state: %{
                 state: %{actor_id: ctx.child_actor.id, storage_id: "reject-initial"}
               },
               agent_opts: [initialization_options: Map.to_list(scope(ctx.root_actor))]
             )

    :ok = Aikido.AgentServer.await_ready(pid)
    assert {:ok, marker} = Aikido.AgentServer.state(pid, &{:ok, &1.startup_operation})
    assert is_map(marker)
    assert is_nil(Map.get(marker, :id))
    signal = Aikido.Team.Signals.Start.new!(%{topology: %{}})

    assert {:error, %Ash.Error.Action.InvalidArgument{field: :topology}} =
             Aikido.AgentServer.start_initial_topology(pid, signal)

    assert {:ok, %{id: operation_id}} =
             Aikido.AgentServer.state(pid, &{:ok, &1.startup_operation})

    assert operation_id == signal.id
    assert :ok = Aikido.AgentServer.prepare_failed_start_stop(pid, signal.id)
    assert {:ok, nil} = Aikido.AgentServer.state(pid, &{:ok, &1.startup_operation})

    assert {:error, %Ash.Error.Invalid{}} =
             Aikido.AgentServer.prepare_failed_start_stop(pid, signal.id)

    assert :ok = Aikido.Durable.stop(pool, pid, scope: scope(ctx.child_actor))
    assert :error = Aikido.Durable.lookup(pool, id)
  end

  test "restored topology ignores different fresh constructor topology and refuses boot dispatch",
       ctx do
    root = start_tree(ctx)
    saved_nodes = snapshot(root.pid).team.topology.nodes
    Domain.root_stop!(root, scope: scope(ctx.root_actor))

    restored =
      Domain.root_start!(
        %{
          id: root.id,
          actor_id: ctx.root_actor.id,
          topology: %{
            incoming: %{
              resource: Aikido.InheritedConfigurationTest.Worker,
              initial_state: %{actor_id: ctx.root_actor.id}
            }
          }
        },
        scope: scope(ctx.root_actor)
      )

    result = Domain.root_reconcile(restored, %{}, scope: scope(ctx.root_actor))
    team = snapshot(restored.pid).team

    branch_operation =
      case team.members[:branch] do
        pid when is_pid(pid) -> snapshot(pid).team.operation
        _ -> :branch_not_running
      end

    assert match?({:ok, _}, result),
           "Restored reconciliation failed: parent=#{inspect(team.operation, limit: :infinity)} branch=#{inspect(branch_operation, limit: :infinity)}"

    assert snapshot(restored.pid).team.topology.nodes == saved_nodes
    assert Map.keys(snapshot(restored.pid).team.members) |> Enum.sort() == [:branch, :override]
    signal = Aikido.Team.Signals.Start.new!(%{topology: %{}})

    assert {:error, %Ash.Error.Invalid{}} =
             Aikido.AgentServer.start_initial_topology(restored.pid, signal)

    assert snapshot(restored.pid).team.topology.nodes == saved_nodes
  end

  test "a failed saved-topology restoration retains the saved identity for inspection", ctx do
    root = start_tree(ctx)
    saved_nodes = snapshot(root.pid).team.topology.nodes
    Domain.root_stop!(root, scope: scope(ctx.root_actor))
    access = Ash.get!(Access, ctx.child_actor.id, authorize?: false)
    Ash.update!(access, %{active?: false}, authorize?: false)

    assert {:error, _} =
             Domain.root_start(%{id: root.id, actor_id: ctx.root_actor.id},
               scope: scope(ctx.root_actor)
             )

    pool = Aikido.durable_supervisor_name(Aikido.Default)
    assert {:ok, restored_pid} = Aikido.Durable.lookup(pool, root.id)
    assert snapshot(restored_pid).team.topology.nodes == saved_nodes
    assert snapshot(restored_pid).team.operation.status == :failed
    assert {:ok, nil} = Aikido.AgentServer.state(restored_pid, &{:ok, &1.startup_operation})
  end

  test "restored empty teams cannot reuse the boot-only configuration path", ctx do
    root =
      Domain.opt_out_start!(%{id: ctx.root_actor.id, actor_id: ctx.root_actor.id},
        scope: scope(ctx.root_actor)
      )

    Domain.opt_out_stop!(root, scope: scope(ctx.root_actor))

    restored =
      Domain.opt_out_start!(%{id: root.id, actor_id: ctx.root_actor.id},
        scope: scope(ctx.root_actor)
      )

    assert snapshot(restored.pid).team.topology.nodes == %{}
    signal = Aikido.Team.Signals.Start.new!(%{topology: %{}})

    assert {:error, %Ash.Error.Invalid{}} =
             Aikido.AgentServer.start_initial_topology(restored.pid, signal)

    assert {:ok, nil} = Aikido.AgentServer.state(restored.pid, &{:ok, &1.startup_operation})
  end

  defp start_tree(ctx) do
    Domain.root_start!(
      %{
        id: ctx.root_actor.id,
        actor_id: ctx.root_actor.id,
        topology: %{
          branch: %{
            resource: Aikido.InheritedConfigurationTest.Branch,
            initial_state: %{actor_id: ctx.child_actor.id}
          },
          override: %{
            resource: Aikido.InheritedConfigurationTest.Worker,
            initial_state: %{
              actor_id: ctx.root_actor.id,
              storage_id: "explicit-member-destination"
            }
          }
        }
      },
      scope: scope(ctx.root_actor)
    )
  end

  defp actor do
    actor = %{id: Ash.UUIDv7.generate(), allowed: true}
    Ash.create!(Access, %{id: actor.id}, authorize?: false)
    actor
  end

  defp scope(actor), do: %{actor: actor, tenant: "inheritance-test"}

  defp snapshot(pid) do
    assert {:ok, agent} = Aikido.AgentServer.state(pid, &{:ok, &1.agent})
    Aikido.Agent.resource_attributes(agent)
  end

  defp own(pid) do
    assert {:ok, own} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.state})
    own
  end
end
