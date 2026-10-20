defmodule AikidoTest.Actions.ForwardTest.Agent do
  use Aikido.Agent

  agent do
    name "forwarding"
    route "test.forward", {Aikido.AgentServer.RuntimeActions, :forward}
  end
end

defmodule AikidoTest.Actions.ForwardTest do
  use AikidoTest.Case, async: true

  test "forwarding preserves the original envelope and changes only requested fields" do
    for data <- [%{amount: 1}, false, nil, 42, "value"] do
      original = %Aikido.Signal{
        id: "request-id",
        time: "2026-10-20T00:00:00Z",
        type: "test.forward",
        data: data,
        source: "/caller",
        subject: "origin",
        reply_to: self(),
        scope: %{actor: %{id: "caller"}, tenant: "workspace"},
        tracer_context: %{Tracer => :opaque_context}
      }

      assert {:ok, result} = forward(original)
      assert result.state == %{count: 7}
      assert [%Aikido.Directives.Emit{signal: forwarded, target: target}] = result.directives
      assert target == self()
      assert forwarded === %{original | source: "/caller/forwarded"}

      assert {:ok, changed} =
               forward(original, %{
                 signal_type: "work.other",
                 payload: %{other: true},
                 source: "/override"
               })

      assert [%{signal: overridden}] = changed.directives

      assert overridden === %{
               original
               | type: "work.other",
                 data: %{other: true},
                 source: "/override"
             }
    end
  end

  test "forwarding without an original envelope returns an unmaterialized descriptor" do
    assert {:ok, result} = forward(nil)

    assert [
             %{
               signal: %Aikido.Signal{
                 id: nil,
                 time: nil,
                 type: "forwarded",
                 data: %{},
                 source: "/forwarded"
               }
             }
           ] = result.directives
  end

  test "a signal call reaches a downstream agent and retains reply correlation and scope",
       context do
    downstream = start_server(context, AikidoTest.TestAgents.Minimal)
    forwarder = start_server(context, AikidoTest.Actions.ForwardTest.Agent)

    query =
      Aikido.Signal.new!("test.forward", %{
        target_pid: downstream,
        signal_type: "aikido.agent.query.children",
        payload: %{}
      })
      |> Aikido.Signal.put_ctx(%{actor: %{id: "caller"}, tenant: "workspace"})

    assert {:ok, :processed} =
             Aikido.AgentServer.call_until(
               downstream,
               fn ->
                 assert {:ok, reply} = Aikido.Signal.Call.call(forwarder, query)
                 assert reply.type == "aikido.agent.query.children.reply"
                 assert reply.subject == query.id
                 assert reply.data == %{children: %{}}
                 assert reply.scope.actor == %{id: "caller"}
                 assert reply.scope.tenant == "workspace"
                 :ok
               end,
               "aikido.agent.query.children",
               fn _ -> {:ok, :processed} end
             )
  end

  defp forward(signal, overrides \\ %{}) do
    Aikido.AgentServer.RuntimeActions
    |> Ash.ActionInput.for_action(
      :forward,
      Map.merge(%{state: %{count: 7}, target_pid: self()}, overrides),
      context: %{aikido: %{signal: signal}}
    )
    |> Ash.run_action()
  end
end
