defmodule AikidoTest.Middleware.PersisterTest.TestAgent do
  @moduledoc false
  use Aikido.Agent

  agent do
    name "persister_test_agent"
    path :app

    schema do
      attribute :counter, :integer, default: 0
    end
  end
end

defmodule AikidoTest.Middleware.PersisterTest do
  use ExUnit.Case, async: true

  defp signal(type) do
    {:ok, sig} = Jido.Signal.new(%{type: type, source: "/test", data: %{}})
    sig
  end

  defp ctx(agent) do
    %{agent: agent, agent_module: agent.agent_module, aikido: Aikido, partition: nil}
  end

  defp ets_storage do
    {Aikido.Storage.ETS, table: :"persister_#{System.unique_integer([:positive])}"}
  end

  describe("starting signal — thaw round-trip") do
    test "with no storage, passes through unchanged" do
      agent = AikidoTest.Middleware.PersisterTest.TestAgent.initialize!(%{id: "no-storage"})
      next = fn sig, c -> {:ok, Map.put(c, :ran, true), done: sig.type} end

      assert {:ok, new_ctx, dirs} =
               Aikido.Middlewares.Persister.on_signal(
                 signal("aikido.agent.lifecycle.starting"),
                 ctx(agent),
                 %{storage: nil, persistence_key: "x"},
                 next
               )

      assert new_ctx.ran == true
      assert dirs == [done: "aikido.agent.lifecycle.starting"]
    end

    test "with storage but no checkpoint, emits thaw.failed and continues" do
      agent = AikidoTest.Middleware.PersisterTest.TestAgent.initialize!(%{id: "missing"})
      storage = ets_storage()
      next = fn _sig, c -> {:ok, c, []} end

      assert {:ok, _ctx, dirs} =
               Aikido.Middlewares.Persister.on_signal(
                 signal("aikido.agent.lifecycle.starting"),
                 ctx(agent),
                 %{storage: storage, persistence_key: "missing"},
                 next
               )

      assert Enum.any?(dirs, fn d ->
               match?(%Aikido.Directives.Emit{}, d) and
                 d.signal.type == "aikido.persist.thaw.failed"
             end)
    end

    test "with stored checkpoint, replaces ctx.agent with thawed copy" do
      agent =
        AikidoTest.Middleware.PersisterTest.TestAgent.initialize!(%{
          id: "round-trip",
          state: %{app: %{counter: 99}}
        })

      storage = ets_storage()
      assert :ok = Aikido.Persist.hibernate(storage, agent)
      next = fn _sig, c -> {:ok, c, []} end

      assert {:ok, final_ctx, dirs} =
               Aikido.Middlewares.Persister.on_signal(
                 signal("aikido.agent.lifecycle.starting"),
                 ctx(agent),
                 %{storage: storage, persistence_key: "round-trip"},
                 next
               )

      assert final_ctx.agent.state.app.counter == 99

      assert Enum.any?(dirs, fn d ->
               match?(%Aikido.Directives.Emit{}, d) and
                 d.signal.type == "aikido.persist.thaw.completed"
             end)
    end

    test "passes a chain {:error, ctx, _} through verbatim with the thawed agent in ctx" do
      agent =
        AikidoTest.Middleware.PersisterTest.TestAgent.initialize!(%{
          id: "round-trip-err",
          state: %{app: %{counter: 1}}
        })

      storage = ets_storage()
      assert :ok = Aikido.Persist.hibernate(storage, agent)
      next = fn _sig, c -> {:error, c, :downstream_blew_up} end

      assert {:error, ctx, :downstream_blew_up} =
               Aikido.Middlewares.Persister.on_signal(
                 signal("aikido.agent.lifecycle.starting"),
                 ctx(agent),
                 %{storage: storage, persistence_key: "round-trip-err"},
                 next
               )

      assert ctx.agent.state.app.counter == 1
    end
  end

  describe("stopping signal — hibernate round-trip") do
    test "with no storage, passes through unchanged" do
      agent = AikidoTest.Middleware.PersisterTest.TestAgent.initialize!(%{id: "stop-no-storage"})
      next = fn _sig, c -> {:ok, c, []} end

      assert {:ok, _ctx, dirs} =
               Aikido.Middlewares.Persister.on_signal(
                 signal("aikido.agent.lifecycle.stopping"),
                 ctx(agent),
                 %{storage: nil, persistence_key: "x"},
                 next
               )

      assert dirs == []
    end

    test "with storage, persists agent and emits hibernate.completed" do
      agent =
        AikidoTest.Middleware.PersisterTest.TestAgent.initialize!(%{
          id: "save-me",
          state: %{app: %{counter: 7}}
        })

      storage = ets_storage()
      next = fn _sig, c -> {:ok, c, []} end

      assert {:ok, _ctx, dirs} =
               Aikido.Middlewares.Persister.on_signal(
                 signal("aikido.agent.lifecycle.stopping"),
                 ctx(agent),
                 %{storage: storage, persistence_key: "save-me"},
                 next
               )

      assert Enum.any?(dirs, fn d ->
               match?(%Aikido.Directives.Emit{}, d) and
                 d.signal.type == "aikido.persist.hibernate.completed"
             end)

      assert {:ok, thawed} =
               Aikido.Persist.thaw(
                 storage,
                 AikidoTest.Middleware.PersisterTest.TestAgent,
                 "save-me"
               )

      assert thawed.state.app.counter == 7
    end
  end

  describe("non-lifecycle signal — passthrough") do
    test "any other signal type is passed through next/2 unchanged" do
      agent = AikidoTest.Middleware.PersisterTest.TestAgent.initialize!(%{id: "passthrough"})
      next = fn _sig, c -> {:ok, Map.put(c, :passed, true), []} end

      assert {:ok, final_ctx, dirs} =
               Aikido.Middlewares.Persister.on_signal(
                 signal("work.start"),
                 ctx(agent),
                 %{storage: nil, persistence_key: "x"},
                 next
               )

      assert final_ctx.passed == true
      assert dirs == []
    end
  end
end
