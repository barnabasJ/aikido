defmodule Aikido.DurableAnonymousRestoreTest do
  use AikidoTest.Case, async: false

  alias AikidoTest.TestAgents.Counter

  @pool Aikido.DurableAnonymousRestoreTest.Pool

  setup ctx do
    options =
      durable_options()
      |> Keyword.delete(:scope_adapter)
      |> Keyword.merge(name: @pool, aikido: ctx.aikido)

    start_supervised!({Aikido.Durable, options})
    {:ok, pool: @pool}
  end

  test "an anonymous pool restores the saved module and state without fresh attributes", ctx do
    id = save_counter(ctx.pool)

    assert {:ok, restored} = Aikido.Durable.ensure_started(ctx.pool, id)
    assert :ok = Aikido.AgentServer.await_ready(restored)
    assert_saved_counter(restored)
  end

  test "irrelevant invalid fresh attributes do not block an anonymous saved restoration", ctx do
    id = save_counter(ctx.pool)

    assert {:ok, restored} =
             Aikido.Durable.ensure_started(ctx.pool, id,
               initial_state: %{domain: "invalid-fresh-only-state"}
             )

    assert :ok = Aikido.AgentServer.await_ready(restored)
    assert_saved_counter(restored)
  end

  test "a genuinely new identity requires a module before writing and can then start correctly",
       ctx do
    id = Ash.UUIDv7.generate()
    key = Aikido.Durable.storage_key(id, nil)

    assert {:error, :agent_module_required} = Aikido.Durable.ensure_started(ctx.pool, id)
    assert :error = Aikido.Durable.lookup(ctx.pool, id)
    refute match?({:ok, _}, DurableServer.Supervisor.get_server_info(ctx.pool, key))

    assert {:ok, pid} =
             Aikido.Durable.ensure_started(ctx.pool, id,
               agent: Counter,
               initial_state: %{domain: %{counter: 23}}
             )

    assert :ok = Aikido.AgentServer.await_ready(pid)

    assert {:ok, {Counter, 23}} =
             Aikido.AgentServer.state(pid, fn runtime ->
               {:ok, {runtime.agent_module, runtime.agent.state.domain.counter}}
             end)

    assert {:ok, ^pid} = Aikido.Durable.lookup(ctx.pool, id)
    assert {:ok, _info} = DurableServer.Supervisor.get_server_info(ctx.pool, key)
  end

  defp save_counter(pool) do
    id = Ash.UUIDv7.generate()

    assert {:ok, pid} =
             Aikido.Durable.ensure_started(pool, id,
               agent: Counter,
               initial_state: %{domain: %{counter: 7}}
             )

    assert :ok = Aikido.AgentServer.await_ready(pid)

    assert {:ok, 12} =
             Aikido.AgentServer.call(
               pid,
               Aikido.Signal.new!("increment", %{amount: 5}),
               &{:ok, &1.agent.state.domain.counter}
             )

    assert :ok = Aikido.Durable.stop(pool, pid)
    assert :error = Aikido.Durable.lookup(pool, id)
    id
  end

  defp assert_saved_counter(pid) do
    assert {:ok, {Counter, 12}} =
             Aikido.AgentServer.state(pid, fn runtime ->
               {:ok, {runtime.agent_module, runtime.agent.state.domain.counter}}
             end)
  end
end
