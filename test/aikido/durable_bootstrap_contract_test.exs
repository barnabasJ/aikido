defmodule AikidoTest.BootstrapContract.WaitForCreate do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _options, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if observer = Process.whereis(AikidoTest.BootstrapContract.Observer) do
        send(observer, {:bootstrap_create_waiting, self()})

        receive do
          :resume_bootstrap_create -> :ok
        end
      end

      changeset
    end)
  end
end

defmodule AikidoTest.BootstrapContract.Agent do
  use Aikido.Agent

  agent do
    name "bootstrap_contract"
    path :domain
    slice :todos, Aikido.Todo.Slice

    schema do
      attribute :value, :integer do
        description "Supplied value retained across bootstrap encoding."
        default 5
      end

      attribute :label, :string do
        description "Default applied by native initialization after the claim."
        default "native default"
      end
    end
  end

  changes do
    change AikidoTest.BootstrapContract.WaitForCreate, on: [:create]
  end
end

defmodule AikidoTest.BootstrapContract.CheckpointOnlyAgent do
  use Aikido.Agent

  agent do
    name "checkpoint_only_bootstrap"
    path :domain

    schema do
      attribute :credential, :string do
        description "Secret omitted by the existing whole-agent checkpoint contract."
        sensitive? true
      end
    end
  end

  @impl true
  def checkpoint(agent, _context), do: {:ok, %{id: agent.id}}

  @impl true
  def restore(checkpoint, _context), do: {:ok, initialize!(%{id: checkpoint.id})}
end

defmodule AikidoTest.BootstrapContract.Callbacks do
  def add(left, right), do: left + right
end

defmodule AikidoTest.BootstrapContract.PreservedCallbackSlice do
  use Aikido.Slice

  slice do
    name "preserved_bootstrap_callback"

    schema do
      attribute :callback, :function do
        description "Portable callback retained by this shape-preserving codec."
        constraints mfa: true, arity: 2
      end
    end
  end

  def externalize(state), do: state

  def reinstate(%{callback: callback} = state) when is_function(callback, 2), do: state
end

defmodule AikidoTest.BootstrapContract.EncodedCallbackSlice do
  use Aikido.Slice

  slice do
    name "encoded_bootstrap_callback"

    schema do
      attribute :callback, :function do
        description "Portable callback whose string representation belongs to this codec."
        constraints mfa: true, arity: 2
      end
    end
  end

  def externalize(state) do
    {:ok, encoded} = Ash.Type.dump_to_embedded(:function, state.callback, mfa: true, arity: 2)
    %{callback: encoded}
  end

  def reinstate(%{callback: encoded}) when is_binary(encoded) do
    {:ok, callback} = Ash.Type.cast_from_embedded(:function, encoded, mfa: true, arity: 2)
    Ash.create!(__MODULE__, %{callback: callback})
  end
end

defmodule AikidoTest.BootstrapContract.PreservedCallbackAgent do
  use Aikido.Agent

  agent do
    name "preserved_bootstrap_callback_agent"
    slice :callbacks, AikidoTest.BootstrapContract.PreservedCallbackSlice
  end
end

defmodule AikidoTest.BootstrapContract.EncodedCallbackAgent do
  use Aikido.Agent

  agent do
    name "encoded_bootstrap_callback_agent"
    slice :callbacks, AikidoTest.BootstrapContract.EncodedCallbackSlice
  end
end

defmodule AikidoTest.DurableBootstrapContractTest do
  use ExUnit.Case, async: false

  alias AikidoTest.BootstrapContract

  setup do
    directory =
      Path.join(System.tmp_dir!(), "aikido-bootstrap-#{System.unique_integer([:positive])}")

    instance = AikidoTest.BootstrapContract.Instance
    pool = AikidoTest.BootstrapContract.Pool

    start_supervised!(
      {Aikido, name: instance, durable: [data_dir: Path.join(directory, "runtime")]}
    )

    # This separately configured pool deliberately has no scope adapter: the
    # anonymous bootstrap path must protect its own declared input contract.
    start_supervised!(
      {Aikido.Durable,
       name: pool,
       agent: BootstrapContract.Agent,
       aikido: instance,
       agent_opts: [sync: %{mode: :explicit}],
       data_dir: Path.join(directory, "anonymous"),
       durable_options: [discovery_interval_ms: 100, initial_discovery_delay_ms: 0]}
    )

    on_exit(fn -> File.rm_rf!(directory) end)
    %{pool: pool}
  end

  test "sparse fresh todo input gets native defaults after bootstrap", %{pool: pool} do
    assert {:ok, pid} =
             Aikido.Durable.ensure_started(pool, "sparse-todo",
               initial_state: %{todos: %{items: [%{id: "one", text: "work"}]}}
             )

    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert {:ok, [item]} = todos(pid)
    assert item.id == "one"
    assert item.text == "work"
    assert item.status == :pending
    assert item.blocking?
    assert item.reason == nil
  end

  test "fresh timed todo remains pending instead of being treated as interrupted", %{pool: pool} do
    todo =
      Ash.create!(Aikido.Todo.Slice, %{items: [%{id: "one", text: "work", timeout_ms: 1_000}]})

    assert {:ok, pid} =
             Aikido.Durable.ensure_started(pool, "fresh-timed-todo",
               initial_state: %{todos: todo}
             )

    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert {:ok, [item]} = todos(pid)
    assert item.status == :pending
    assert item.timeout_ms == 1_000
    assert item.reason == nil
  end

  test "saved timed todo retains the interrupted restoration policy", %{pool: pool} do
    assert {:ok, pid} =
             Aikido.Durable.ensure_started(pool, "saved-timed-todo",
               initial_state: %{todos: %{items: [%{id: "one", text: "work", timeout_ms: 1_000}]}}
             )

    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert {:ok, [%{status: :pending}]} = todos(pid)
    assert :ok = Aikido.Durable.stop(pool, pid)
    assert {:ok, restored} = Aikido.Durable.ensure_started(pool, "saved-timed-todo")
    assert :ok = Aikido.AgentServer.await_ready(restored)
    assert {:ok, [item]} = todos(restored)
    assert item.status == :blocked
    assert item.reason == :interrupted
  end

  test "first claim discards unknown top-level and own attributes before native create", %{
    pool: pool
  } do
    Process.register(self(), BootstrapContract.Observer)
    id = "unknown-bootstrap-fields"

    activation =
      Task.async(fn ->
        Aikido.Durable.ensure_started(pool, id,
          initial_state: %{
            domain: %{value: 91, unknown_credential: "unknown-own-secret"},
            unknown_scope: %{credential: "unknown-top-level-secret"}
          }
        )
      end)

    assert_receive {:bootstrap_create_waiting, child}, 5_000
    on_exit(fn -> send(child, :resume_bootstrap_create) end)
    saved = saved_envelope(pool, id)
    assert {:uninitialized, attributes} = saved.agent
    assert attributes.domain.value == 91
    refute Map.has_key?(attributes, :unknown_scope)
    refute Map.has_key?(attributes.domain, :unknown_credential)
    refute inspect(saved, limit: :infinity) =~ "unknown-own-secret"
    refute inspect(saved, limit: :infinity) =~ "unknown-top-level-secret"
    assert saved.bootstrap_codecs == []

    send(child, :resume_bootstrap_create)
    assert {:ok, ^child} = Task.await(activation, 10_000)
    assert :ok = Aikido.AgentServer.await_ready(child)

    assert {:ok, {91, "native default"}} =
             Aikido.AgentServer.state(child, fn runtime ->
               own = Aikido.Agent.resource_attributes(runtime.agent)
               {:ok, {own.value, own.label}}
             end)
  end

  test "first claim follows nested item types while preserving unconstrained metadata and results",
       %{pool: pool} do
    Process.register(self(), BootstrapContract.Observer)
    id = "nested-bootstrap-fields"
    marker = "same-marker-is-valid-in-opaque-data"
    metadata = %{unknown_credential: marker}
    result = %{unknown_credential: marker, observations: [%{unknown_credential: marker}]}

    activation =
      Task.async(fn ->
        Aikido.Durable.ensure_started(pool, id,
          initial_state: %{
            todos: %{
              items: [
                %{
                  id: "one",
                  text: "work",
                  unknown_credential: marker,
                  metadata: metadata,
                  result: result
                }
              ]
            }
          }
        )
      end)

    assert_receive {:bootstrap_create_waiting, child}, 5_000
    on_exit(fn -> send(child, :resume_bootstrap_create) end)
    saved = saved_envelope(pool, id)
    assert {:uninitialized, attributes} = saved.agent
    assert [item] = attributes.todos.items
    assert item.id == "one"
    assert item.text == "work"
    refute Map.has_key?(item, :unknown_credential)
    assert item.metadata == metadata
    assert item.result == result
    assert :todos in saved.bootstrap_codecs

    send(child, :resume_bootstrap_create)
    assert {:ok, ^child} = Task.await(activation, 10_000)
    assert :ok = Aikido.AgentServer.await_ready(child)
    assert {:ok, [initialized]} = todos(child)
    assert initialized.id == "one"
    assert initialized.text == "work"
    assert initialized.status == :pending
    assert initialized.blocking?
    assert initialized.reason == nil
    assert initialized.metadata == metadata
    assert initialized.result == result
  end

  test "checkpoint-only sanitizers require explicit bootstrap preparation before any write", %{
    pool: pool
  } do
    id = "checkpoint-only-secret"

    assert {:error,
            {:bootstrap_preparation_required, BootstrapContract.CheckpointOnlyAgent, :domain}} =
             Aikido.Durable.ensure_started(pool, id,
               agent: BootstrapContract.CheckpointOnlyAgent,
               initial_state: %{
                 domain: %{credential: "checkpoint-only-secret-must-not-be-written"}
               }
             )

    assert :error = Aikido.Durable.lookup(pool, id)
    refute match?({:ok, _}, DurableServer.Supervisor.get_server_info(pool, storage_key(id)))
  end

  test "bootstrap restores only callbacks it encoded before invoking paired codecs", %{pool: pool} do
    callback = &BootstrapContract.Callbacks.add/2

    for {resource, id} <- [
          {BootstrapContract.PreservedCallbackAgent, "preserved-callback"},
          {BootstrapContract.EncodedCallbackAgent, "encoded-callback"}
        ] do
      assert {:ok, pid} =
               Aikido.Durable.ensure_started(pool, id,
                 agent: resource,
                 initial_state: %{callbacks: %{callback: callback}}
               )

      assert :ok = Aikido.AgentServer.await_ready(pid)

      assert {:ok, ^callback} =
               Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.callbacks.callback})

      assert :ok = Aikido.Durable.stop(pool, pid)
      assert {:ok, restored} = Aikido.Durable.ensure_started(pool, id, agent: resource)
      assert :ok = Aikido.AgentServer.await_ready(restored)

      assert {:ok, ^callback} =
               Aikido.AgentServer.state(restored, &{:ok, &1.agent.state.callbacks.callback})
    end
  end

  defp todos(pid),
    do: Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.todos.items})

  defp saved_envelope(pool, id) do
    assert {:ok, info} = DurableServer.Supervisor.get_server_info(pool, storage_key(id))
    Aikido.Durable.AgentServer.load_state(info.vsn, info.user_state)
  end

  defp storage_key(id),
    do: "agent/" <> Base.url_encode64(:erlang.term_to_binary({nil, id}), padding: false)
end
