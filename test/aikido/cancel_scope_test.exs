defmodule Aikido.CancelScopeTest.Reducer do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    observed = %{
      request_id: input.arguments.request_id,
      actor: context.actor,
      tenant: context.tenant,
      authorize?: context.authorize?,
      tracer: context.tracer,
      application: input.context[:application],
      shared: input.context[:shared]
    }

    Aikido.Types.ActionResult.new(changes: %{status: :failed, observed: observed})
  end
end

defmodule Aikido.CancelScopeTest.Agent do
  use Aikido.Agent, authorizers: [Ash.Policy.Authorizer]

  agent do
    name "scoped_cancel"

    schema do
      attribute :status, :atom do
        description "Current lifecycle or processing status of the fixture."
        default :running
      end

      attribute :observed, :map do
        description "Caller context or runtime value captured by the receiving reducer."
        default %{}
      end
    end

    route Aikido.AiReact.Signals.Cancel, Aikido.CancelScopeTest.Reducer
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:id, "alice")
    end
  end
end

defmodule Aikido.CancelScopeTest do
  use AikidoTest.Case, async: false
  require Ash.Tracer
  alias AikidoTest.Support.TestTracer

  test "public cancel forwards native scope and tracing to its routed action", ctx do
    start_supervised!(TestTracer)

    for style <- [:scope, :options, :overrides] do
      pid = start_server(ctx, __MODULE__.Agent, initialization_options: [actor: %{id: "alice"}])
      request_id = to_string(style)

      options = [
        actor: %{id: "alice"},
        tenant: "org-a",
        authorize?: true,
        tracer: TestTracer,
        context: %{application: request_id, shared: %{marker: "shared"}}
      ]

      options =
        case style do
          :scope ->
            [scope: Map.new(options), context: options[:context]]

          :options ->
            options

          :overrides ->
            [
              scope: %{
                actor: %{id: "bob"},
                tenant: "wrong",
                authorize?: false,
                tracer: [],
                context: %{shared: %{marker: "wrong"}}
              }
            ] ++ options
        end

      {:ok, processed} =
        Aikido.AgentServer.subscribe(pid, "ai.react.cancel", &{:ok, &1.agent.state.state},
          once: true
        )

      root =
        Ash.Tracer.span :custom, "cancel.external", TestTracer do
          root = TestTracer.get_span_context()
          assert :ok = Aikido.AI.cancel(pid, request_id, options)
          root
        end

      assert_receive {:aikido_subscription, ^processed,
                      %{
                        result:
                          {:ok,
                           %{
                             status: :failed,
                             observed: %{
                               request_id: ^request_id,
                               actor: %{id: "alice"},
                               tenant: "org-a",
                               authorize?: true,
                               tracer: tracers,
                               application: ^request_id,
                               shared: %{marker: "shared"}
                             }
                           }}
                      }},
                     5_000

      assert TestTracer in List.wrap(tracers)

      events = TestTracer.get_spans()

      {:start, signal_span, {:custom, :aikido_signal}, "ai.react.cancel"} =
        Enum.find(events, &match?({:start, _, {:custom, :aikido_signal}, "ai.react.cancel"}, &1))

      assert {:parent, ^signal_span, ^root, ^pid} =
               Enum.find(events, &match?({:parent, ^signal_span, _, _}, &1))

      {:start, action_span, :action, _name} =
        Enum.find(events, &match?({:start, _, :action, _}, &1))

      parents = Map.new(for {:parent, id, parent, _} <- events, do: {id, parent})

      assert signal_span in Stream.unfold(action_span, fn
               nil -> nil
               id -> {id, Map.get(parents, id)}
             end)
    end
  end

  test "a denied asynchronous cancellation leaves state unchanged and explicit authorization is preserved",
       ctx do
    pid = start_server(ctx, __MODULE__.Agent, initialization_options: [actor: %{id: "alice"}])

    {:ok, denied} =
      Aikido.AgentServer.subscribe(pid, "ai.react.cancel", &{:ok, &1.agent.state.state},
        once: true
      )

    assert :ok = Aikido.AI.cancel(pid, "denied", actor: %{id: "bob"}, authorize?: true)

    assert_receive {:aikido_subscription, ^denied,
                    %{result: {:ok, %{status: :running, observed: %{}}}}},
                   5_000

    {:ok, allowed} =
      Aikido.AgentServer.subscribe(pid, "ai.react.cancel", &{:ok, &1.agent.state.state},
        once: true
      )

    assert :ok =
             Aikido.AI.cancel(pid, nil,
               actor: %{id: "bob"},
               authorize?: false,
               context: %{application: "explicit"}
             )

    assert_receive {:aikido_subscription, ^allowed,
                    %{
                      result:
                        {:ok,
                         %{
                           status: :failed,
                           observed: %{
                             request_id: nil,
                             actor: %{id: "bob"},
                             authorize?: false,
                             application: "explicit"
                           }
                         }}
                    }},
                   5_000
  end
end
