defmodule AikidoTest.ScopeReducer do
  use Ash.Resource.Actions.Implementation

  def run(input, _, context) do
    Aikido.Types.ActionResult.new(
      state: %{
        observed: %{
          actor: context.actor,
          tenant: context.tenant,
          request_tag: input.context[:request_tag]
        }
      }
    )
  end
end

defmodule AikidoTest.ScopedAgent do
  use Ash.Resource, domain: AikidoTest.ScopedDomain, extensions: [Aikido.Ash.Agent]

  agent do
    name "scope_test"

    schema do
      attribute :observed, :map do
        description "Caller context or runtime value captured by the receiving reducer."
        default %{}
      end
    end

    route "scope.observe", {__MODULE__, :reduce}, name: :observe
  end

  actions do
    action :reduce, Aikido.Types.ActionResult do
      public? false
      argument :state, :term
      run AikidoTest.ScopeReducer
    end
  end
end

defmodule AikidoTest.ScopedTool.Actions.ReadIdentity do
  use Ash.Resource.Actions.Implementation
  def run(_input, _opts, context), do: {:ok, %{actor: context.actor.id, tenant: context.tenant}}
end

defmodule AikidoTest.ScopedTool do
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    validate_domain_inclusion?: false,
    domain: AikidoTest.ScopedDomain,
    authorizers: [Ash.Policy.Authorizer]

  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  actions do
    action :identity, :map do
      run AikidoTest.ScopedTool.Actions.ReadIdentity
    end
  end
end

defmodule AikidoTest.ScopedClient do
  def generate_text(_, messages, opts) do
    send(opts[:observer], {:model, self(), messages})

    receive do
      {:answer, value} -> value
    end
  end
end

defmodule AikidoTest.ScopedAssistant do
  use Ash.Resource,
    domain: AikidoTest.ScopedDomain,
    extensions: [Aikido.Ash.Agent, Aikido.Ash.AI]

  agent do
    name "scoped_assistant"
  end
end

defmodule AikidoTest.ScopedDomain do
  use Ash.Domain, validate_config_inclusion?: false, extensions: [Aikido.Ash.Domain, AshAi]

  resources do
    resource AikidoTest.ScopedTool
  end

  tools do
    tool :identity, AikidoTest.ScopedTool, :identity
  end

  agents do
    agent :scoped, AikidoTest.ScopedAgent
    agent :assistant, AikidoTest.ScopedAssistant
  end
end

defmodule Aikido.AshScopeTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!({Aikido, name: Aikido.Default, durable: AikidoTest.Case.durable_options()})
    :ok
  end

  test "native commands carry caller actor, tenant and custom context through the mailbox" do
    ref = AikidoTest.ScopedDomain.scoped_start!(%{})

    AikidoTest.ScopedDomain.scoped_observe!(ref, %{},
      actor: %{id: "alice"},
      tenant: "org-a",
      context: %{request_tag: "first"}
    )

    assert %{observed: %{actor: %{id: "alice"}, tenant: "org-a", request_tag: "first"}} =
             AikidoTest.ScopedDomain.scoped_inspect!(ref)

    AikidoTest.ScopedDomain.scoped_observe!(ref, %{}, actor: nil, tenant: "org-b")

    assert %{observed: %{actor: nil, tenant: "org-b", request_tag: nil}} =
             AikidoTest.ScopedDomain.scoped_inspect!(ref)
  end

  test "native AI commands preserve scope across model and authorized Ash tool execution" do
    ref =
      AikidoTest.ScopedDomain.assistant_start!(%{
        model: "offline",
        client: AikidoTest.ScopedClient,
        tools: [:identity],
        tool_options: [actions: [{AikidoTest.ScopedTool, [:identity]}]],
        llm_opts: [observer: self()]
      })

    AikidoTest.ScopedDomain.assistant_ask!(ref, %{query: "identify", request_id: "scoped-run"},
      actor: %{id: "alice"},
      tenant: "org-a",
      authorize?: false
    )

    assert_receive {:model, model, _}, 2_000

    {[tool], _registry} =
      AshAi.build_tools_and_registry(
        actions: [{AikidoTest.ScopedTool, [:identity]}],
        actor: %{id: "alice"},
        tenant: "org-a"
      )

    turn =
      %ReqLLM.Response{
        id: "scripted",
        model: "offline",
        context: ReqLLM.Context.new(),
        message:
          ReqLLM.Context.assistant("",
            tool_calls: [%{id: "identity", name: tool.name, arguments: %{}}]
          ),
        finish_reason: :tool_calls
      }

    send(model, {:answer, {:ok, turn}})
    assert_receive {:model, next, messages}, 2_000
    result = Enum.find(messages, &(&1.role == :tool))
    text = Enum.map_join(result.content, & &1.text)
    assert Jason.decode!(text) == %{"actor" => "alice", "tenant" => "org-a"}

    send(
      next,
      {:answer,
       {:ok,
        %ReqLLM.Response{
          id: "scripted",
          model: "offline",
          context: ReqLLM.Context.new(),
          message: ReqLLM.Context.assistant("done", tool_calls: []),
          finish_reason: :stop
        }}}
    )
  end
end
