defmodule Aikido.HooksScopeTest.Reducer do
  use Ash.Resource.Actions.Implementation

  def run(input, _, context) do
    Aikido.Types.ActionResult.new(
      state: %{
        observed: %{
          actor: context.actor,
          tenant: context.tenant,
          marker: get_in(input.context, [:shared, :marker])
        }
      }
    )
  end
end

defmodule Aikido.HooksScopeTest.Agent do
  use Aikido.Agent, authorizers: [Ash.Policy.Authorizer]

  agent do
    name "hook_scope"

    schema do
      attribute :observed, :map, default: %{}
    end

    slice :ai, Aikido.Slices.AiReact
    route "hook.notice", :notice
  end

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  actions do
    action :notice, Aikido.Types.ActionResult do
      argument :state, :term
      run Aikido.HooksScopeTest.Reducer
    end
  end
end

defmodule Aikido.HooksScopeTest.Client do
  require Ash.Tracer

  def generate_text("tool-scope", messages, _) do
    done? = Enum.any?(messages, &(&1.role == :tool))

    {:ok,
     struct!(ReqLLM.Response,
       id: "scope-tool",
       model: "offline",
       context: ReqLLM.Context.new(),
       message:
         ReqLLM.Context.assistant(if(done?, do: "done", else: ""),
           tool_calls:
             if(done?, do: [], else: [ReqLLM.ToolCall.new("scope-call", "scope_callback", "{}")])
         ),
       finish_reason: if(done?, do: :stop, else: :tool_calls)
     )}
  end

  def generate_text(_, _, opts) do
    send(opts[:observer], {:model_waiting, self()})

    receive do
      :finish ->
        {:ok,
         struct!(ReqLLM.Response,
           id: "hook",
           model: "offline",
           context: ReqLLM.Context.new(),
           message: ReqLLM.Context.assistant("done"),
           finish_reason: :stop
         )}
    end
  end

  def scope_tool(_args, context) do
    tracer = AikidoTest.Support.TestTracer

    Ash.Tracer.span :custom, "tool.scope_callback", tracer do
      send(
        context.context.shared.observer,
        {:tool_scope, Map.take(context, [:actor, :tenant, :authorize?, :tracer, :context])}
      )

      {:ok, "observed"}
    end
  end

  def unused_tool(_args), do: {:ok, %{}}
end

defmodule Aikido.HooksScopeTest do
  use AikidoTest.Case, async: false
  require Ash.Tracer
  alias AikidoTest.Support.TestTracer

  test "both async Lua helpers preserve native scope and the originating trace", ctx do
    start_supervised!(TestTracer)

    pid = start_server(ctx, Aikido.HooksScopeTest.Agent)

    assert {:error, _} =
             Aikido.AgentServer.call(
               pid,
               Jido.Signal.new!("hook.notice", %{}),
               &{:ok, &1.agent.state.state}
             )

    {:ok, hook} =
      Ash.Type.cast_input(Aikido.Hooks.Hook, %{
        name: "scoped",
        event: :before_model,
        mode: :async,
        script:
          ~s|aikido.send_context("evidence"); aikido.send_signal("hook.notice", {actor = "forged", tenant = "forged"})|
      })

    {:ok, sub} =
      Aikido.AgentServer.subscribe(
        pid,
        "hook.notice",
        fn runtime ->
          case {runtime.agent.state.state.observed, runtime.agent.state.ai.hook_context} do
            {%{actor: %{id: "alice"}, tenant: "org-a", marker: "application"},
             [%{text: "evidence"}]} ->
              {:ok, :observed}

            _ ->
              :skip
          end
        end,
        once: true
      )

    Ash.Tracer.span :custom, "hooks.external", TestTracer do
      assert {:ok, _} =
               Aikido.AI.ask(pid, "hello",
                 model: "offline",
                 client: Aikido.HooksScopeTest.Client,
                 hooks: [hook],
                 llm_opts: [observer: self()],
                 scope: %{
                   actor: %{id: "alice"},
                   tenant: "org-a",
                   context: %{shared: %{marker: "application"}},
                   tracer: TestTracer
                 }
               )

      assert_receive {:model_waiting, model}, 5_000
      assert_receive {:aikido_subscription, ^sub, %{result: {:ok, :observed}}}, 5_000
      assert {:ok, :barrier} = Aikido.AgentServer.state(pid, fn _ -> {:ok, :barrier} end)
      send(model, :finish)
    end

    events = TestTracer.get_spans()

    {:start, context_signal, {:custom, :aikido_signal}, "ai.react.hook.context"} =
      Enum.find(
        events,
        &match?({:start, _, {:custom, :aikido_signal}, "ai.react.hook.context"}, &1)
      )

    {:parent, ^context_signal, async, ^pid} =
      Enum.find(events, &match?({:parent, ^context_signal, _, _}, &1))

    assert {:start, ^async, {:custom, :aikido_async_task}, _} =
             Enum.find(events, &match?({:start, ^async, _, _}, &1))

    {:parent, ^async, directive, _} = Enum.find(events, &match?({:parent, ^async, _, _}, &1))

    assert {:start, ^directive, {:custom, :aikido_directive}, "Aikido.Hooks.Execute"} =
             Enum.find(events, &match?({:start, ^directive, _, _}, &1))

    for name <- ["ai.react.hook.context", "hook.notice"] do
      {:start, id, {:custom, :aikido_signal}, ^name} =
        Enum.find(events, &match?({:start, _, {:custom, :aikido_signal}, ^name}, &1))

      assert {:parent, ^id, ^async, ^pid} = Enum.find(events, &match?({:parent, ^id, _, _}, &1))
    end
  end

  test "tool preparation accepts traced scopes without stripping native callback context", ctx do
    start_supervised!(TestTracer)

    tool =
      ReqLLM.Tool.new!(
        name: "scope_callback",
        description: "Observe native runtime scope",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: &Aikido.HooksScopeTest.Client.unused_tool/1
      )

    for authorize? <- [true, false] do
      pid = start_server(ctx, Aikido.HooksScopeTest.Agent)

      scope = %{
        actor: %{id: "alice"},
        tenant: "org-a",
        authorize?: authorize?,
        tracer: TestTracer,
        context: %{shared: %{observer: self(), marker: "tool context"}}
      }

      root =
        Ash.Tracer.span :custom, "tools.external", TestTracer do
          root = TestTracer.get_span_context()

          signal =
            Jido.Signal.new!("ai.react.ask", %{
              query: "observe",
              request_id: unique_id("tool-scope"),
              model: "tool-scope",
              client: Aikido.HooksScopeTest.Client,
              tool_options: [extra_tools: [{tool, &Aikido.HooksScopeTest.Client.scope_tool/2}]]
            })
            |> Aikido.SignalCtx.put_ctx(scope)

          result =
            Aikido.AgentServer.call_until(pid, signal, "ai.react.**", fn runtime ->
              ai = runtime.agent.state.ai

              cond do
                ai.status == :completed -> {:ok, ai.result}
                ai.status == :failed -> {:error, ai.error}
                true -> :skip
              end
            end)

          assert result == {:ok, "done"},
                 inspect({result, Aikido.AgentServer.state(pid, &{:ok, &1.agent.state.ai})})

          root
        end

      assert_receive {:tool_scope,
                      %{
                        actor: %{id: "alice"},
                        tenant: "org-a",
                        authorize?: ^authorize?,
                        tracer: tracers,
                        context: %{shared: %{marker: "tool context"}}
                      }},
                     5_000

      assert TestTracer in List.wrap(tracers)
      assert {:ok, :barrier} = Aikido.AgentServer.state(pid, fn _ -> {:ok, :barrier} end)

      events = TestTracer.get_spans()

      {:start, callback, :custom, "tool.scope_callback"} =
        Enum.find(events, &match?({:start, _, :custom, "tool.scope_callback"}, &1))

      parents = Map.new(for {:parent, id, parent, _} <- events, do: {id, parent})

      assert root in Stream.unfold(callback, fn
               nil -> nil
               id -> {id, Map.get(parents, id)}
             end)
    end
  end
end
