defmodule AikidoTest.PublicScopeRefusal.Authority do
  @moduledoc false
  use Agent
  @behaviour Aikido.Durable.ScopeAdapter

  def start_link(_options), do: Agent.start_link(fn -> nil end, name: __MODULE__)
  def refuse(reason), do: Agent.update(__MODULE__, fn _ -> reason end)

  @impl true
  defdelegate prepare(attributes, options, identity), to: AikidoTest.DurableScopeAuthority

  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority

  @impl true
  def restore(credential, saved, identity) do
    with {:ok, scope} <- AikidoTest.DurableScopeAuthority.restore(credential, saved, identity) do
      case Agent.get(__MODULE__, & &1) do
        nil ->
          if observer = Process.whereis(AikidoTest.PublicScopeRefusal.Observer),
            do: send(observer, {:public_scope_restored, scope.actor, scope.tenant})

          {:ok, scope}

        reason ->
          {:error, reason}
      end
    end
  end
end

defmodule AikidoTest.PublicScopeRefusal.Create do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _options, context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if observer = Process.whereis(AikidoTest.PublicScopeRefusal.Observer),
        do: send(observer, {:public_scope_initialize, context.actor, context.tenant})

      case Ash.Changeset.get_attribute(changeset, :failure) do
        :invalid ->
          Ash.Changeset.add_error(changeset, field: :failure, message: "native create rejected")

        :noproc ->
          exit(:noproc)

        _ ->
          changeset
      end
    end)
  end
end

defmodule AikidoTest.PublicScopeRefusal.Signals.Capture do
  @moduledoc false
  use Aikido.Signal

  signal do
    type "public.scope.capture"
  end
end

defmodule AikidoTest.PublicScopeRefusal.Capture do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _options, context) do
    Aikido.Types.ActionResult.new(
      changes: %{observed: %{actor: context.actor, tenant: context.tenant}}
    )
  end
end

defmodule AikidoTest.PublicScopeRefusal.Resource do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "public_scope_refusal"
    instance AikidoTest.PublicScopeRefusal.Instance
    persistence :permanent

    schema do
      attribute :value, :integer do
        description "Saved value proves successful native restoration."
        default 7
      end

      attribute :failure, :atom do
        description "Explicit native create failure scenario for boundary classification controls."
      end

      attribute :observed, :map do
        description "Caller scope captured by a pure native routed action."
        default %{}
      end
    end

    route AikidoTest.PublicScopeRefusal.Signals.Capture, AikidoTest.PublicScopeRefusal.Capture
  end

  changes do
    change AikidoTest.PublicScopeRefusal.Create, on: [:create]
  end
end

defmodule Aikido.PublicScopeRefusalTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias AikidoTest.PublicScopeRefusal.{Authority, Resource}

  setup do
    Process.register(self(), AikidoTest.PublicScopeRefusal.Observer)
    start_supervised!({Authority, []})

    directory =
      Path.join(System.tmp_dir!(), "public-scope-refusal-#{System.unique_integer([:positive])}")

    instance = AikidoTest.PublicScopeRefusal.Instance

    start_supervised!(
      {Aikido,
       name: instance,
       durable: [
         data_dir: directory,
         scope_adapter: Authority,
         durable_options: [discovery_interval_ms: 100, initial_discovery_delay_ms: 0]
       ]}
    )

    on_exit(fn -> File.rm_rf!(directory) end)
    actor = %{id: Ash.UUIDv7.generate(), allowed: true, revision: 1}
    %{scope: [actor: actor, tenant: "public-scope-workspace"], actor: actor, instance: instance}
  end

  for reason <- [:revoked_session, :inactive_principal, :invalid_membership] do
    test "generated public start preserves typed #{reason} restoration refusal", ctx do
      owner = saved_owner(ctx)
      Authority.refuse(unquote(reason))

      assert {:error, %Ash.Error.Forbidden{errors: errors} = failure} =
               command(:start, %{id: owner.id}, ctx.scope)

      assert %Aikido.Durable.ScopeAdapter.Error{operation: :restore, reason: unquote(reason)} =
               Enum.find(errors, &match?(%Aikido.Durable.ScopeAdapter.Error{}, &1))

      refute inspect(failure, limit: :infinity) =~ "#PID"
      refute inspect(failure, limit: :infinity) =~ "UnknownError"

      assert :error =
               Aikido.Durable.lookup(Aikido.durable_supervisor_name(ctx.instance), owner.id)

      refute_received {:public_scope_initialize, _, _}
    end
  end

  test "generated public start restores saved state under refreshed current authority without initialization",
       ctx do
    owner = saved_owner(ctx)
    current = %{ctx.actor | revision: 2}
    AikidoTest.DurableScopeAuthority.refresh_actor(current, "public-scope-workspace")
    assert {:ok, restored} = command(:start, %{id: owner.id}, ctx.scope)
    assert :ok = Aikido.AgentServer.await_ready(restored.pid)
    refute_received {:public_scope_initialize, _, _}
    assert_receive {:public_scope_restored, ^current, "public-scope-workspace"}, 5_000

    assert {:ok, _receipt} =
             command(:capture, %{agent: restored},
               actor: current,
               tenant: "public-scope-workspace"
             )

    observed =
      AikidoTest.AgentWait.await_state_value(restored.pid, fn runtime ->
        own = Aikido.Agent.resource_attributes(runtime.agent)
        if own.observed != %{}, do: own
      end)

    assert observed.value == 42
    assert observed.observed == %{actor: current, tenant: "public-scope-workspace"}
  end

  test "opaque refusal data is sanitized across the complete native public error", ctx do
    owner = saved_owner(ctx)
    secret = "scope-adapter-private-marker"
    original = %{credential: secret, cause: %{stacktrace: secret}, data: [secret]}
    Authority.refuse(original)

    assert {:error, %Ash.Error.Forbidden{errors: errors} = failure} =
             command(:start, %{id: owner.id}, ctx.scope)

    assert %Aikido.Durable.ScopeAdapter.Error{operation: :restore} =
             typed = Enum.find(errors, &match?(%Aikido.Durable.ScopeAdapter.Error{}, &1))

    assert typed.reason == :scope_rejected
    refute inspect(failure, limit: :infinity) =~ secret
    refute Exception.message(failure) =~ secret
    refute inspect(failure, limit: :infinity) =~ "#PID"
    assert :error = Aikido.Durable.lookup(Aikido.durable_supervisor_name(ctx.instance), owner.id)
    refute_received {:public_scope_initialize, _, _}
  end

  for mode <- [:invalid, :noproc] do
    test "unrelated native #{mode} startup failure is not classified as scope refusal", ctx do
      id = Ash.UUIDv7.generate()
      assert {:error, failure} = command(:start, %{id: id, failure: unquote(mode)}, ctx.scope)
      refute match?(%Ash.Error.Forbidden{}, failure)
      refute inspect(failure, limit: :infinity) =~ "Aikido.Durable.ScopeAdapter.Error"
      assert :error = Aikido.Durable.lookup(Aikido.durable_supervisor_name(ctx.instance), id)
      assert_receive {:public_scope_initialize, _, _}, 5_000
    end
  end

  defp saved_owner(ctx) do
    assert {:ok, owner} = command(:start, %{id: Ash.UUIDv7.generate(), value: 42}, ctx.scope)
    assert :ok = Aikido.AgentServer.await_ready(owner.pid)
    assert_receive {:public_scope_initialize, actor, "public-scope-workspace"}, 5_000
    assert actor == ctx.actor
    assert_receive {:public_scope_restored, ^actor, "public-scope-workspace"}, 5_000
    monitor = Process.monitor(owner.pid)
    assert {:ok, %{status: :stopped}} = command(:stop, %{agent: owner}, ctx.scope)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    owner
  end

  defp command(action, arguments, scope),
    do: Resource |> Ash.ActionInput.for_action(action, arguments, scope) |> Ash.run_action()
end
