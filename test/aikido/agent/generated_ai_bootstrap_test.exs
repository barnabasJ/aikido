defmodule AikidoTest.GeneratedAIBootstrapTest do
  use AikidoTest.Case, async: false

  alias AikidoTest.GeneratedAIBootstrap.{Agent, Domain}
  @instance AikidoTest.GeneratedAIBootstrap.Instance

  setup do
    options = Keyword.put(AikidoTest.Case.durable_options(), :scope_adapter, nil)
    start_supervised!({Aikido, name: @instance, durable: options})
    :ok
  end

  test "generated public start resolves a declared Lua hook default without an application adapter" do
    assert {:ok, agent} = Domain.generated_ai_start(%{})
    assert :ok = Aikido.AgentServer.await_ready(agent.pid)
    assert_configuration(agent.pid, "declared-model", "declared")
    assert {:ok, _} = Domain.generated_ai_stop(agent)
  end

  test "generated public start preserves explicit overrides through saved reactivation" do
    hook = %{
      name: "explicit",
      event: :before_model,
      script: "return nil"
    }

    assert {:ok, agent} = Domain.generated_ai_start(%{model: "explicit-model", hooks: [hook]})
    assert :ok = Aikido.AgentServer.await_ready(agent.pid)
    assert_configuration(agent.pid, "explicit-model", "explicit")
    assert {:ok, _} = Domain.generated_ai_stop(agent)
    assert {:ok, restored} = Domain.generated_ai_start(%{id: agent.id})
    assert :ok = Aikido.AgentServer.await_ready(restored.pid)
    assert_configuration(restored.pid, "explicit-model", "explicit")
    assert {:ok, _} = Domain.generated_ai_stop(restored)
  end

  test "string-key Lua hooks use native initialization" do
    hook = %{
      "name" => "string-root",
      "event" => "before_model",
      "script" => "return nil"
    }

    pool = Aikido.durable_supervisor_name(@instance)

    assert {:ok, pid} =
             Aikido.Durable.start(pool, Ash.UUIDv7.generate(),
               agent: Agent,
               initial_state: %{"ai" => %{"hooks" => [hook]}}
             )

    assert :ok = Aikido.AgentServer.await_ready(pid)
    assert {:ok, [actual]} = Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai.hooks})
    assert actual.name == "string-root"
    assert :ok = Aikido.Durable.stop(pool, pid)
  end

  test "checkpoint-only AI input requires preparation before the first write" do
    resource = AikidoTest.GeneratedAIBootstrap.CheckpointOnlyAgent
    pool = Aikido.durable_supervisor_name(@instance)
    marker = "must-not-write-ai-bootstrap-credential"

    for attributes <- [
          %{state: %{tool_context: %{credential: marker}}},
          %{ai: %{tool_context: %{credential: marker}}}
        ] do
      id = Ash.UUIDv7.generate()

      assert {:error, {:bootstrap_preparation_required, ^resource, :state}} =
               Aikido.Durable.start(pool, id, agent: resource, initial_state: attributes)

      assert :error = Aikido.Durable.lookup(pool, id)
      prefix = DurableServer.Supervisor.__get_config__(pool).prefix
      key = Aikido.Durable.storage_key(id, nil)

      assert {:error, :not_found} =
               DurableServer.fetch_stored_state(pool, %{key: key, prefix: prefix},
                 consistent: true
               )

      assert {:ok, pid} = Aikido.Durable.start(pool, id, agent: resource)
      assert :ok = Aikido.AgentServer.await_ready(pid)
      assert :ok = Aikido.Durable.stop(pool, pid)
    end
  end

  defp assert_configuration(pid, model, name) do
    assert {:ok, {own, ai}} =
             Aikido.AgentServer.state(pid, &{:ok, {&1.agent.state.state, &1.agent.state.ai}})

    assert own.model == model
    assert ai.model == model
    assert Keyword.get(ai.tool_options, :otp_app) == :aikido
    assert [own_hook] = own.hooks
    assert [ai_hook] = ai.hooks
    assert own_hook.name == name
    assert ai_hook.name == name
  end
end
