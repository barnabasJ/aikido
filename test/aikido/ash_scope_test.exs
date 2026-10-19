defmodule AikidoTest.ScopeReducer do
  use Ash.Resource.Actions.Implementation

  def run(input, _, context) do
    Aikido.ActionResult.new(
      state: %{
        observed: %{
          actor: context.actor,
          tenant: context.tenant,
          request_tag: input.context.aikido[:request_tag]
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
      attribute :observed, :map, default: %{}
    end

    signal :observe, "scope.observe", {__MODULE__, :reduce}
  end

  actions do
    action :reduce, Aikido.ActionResult do
      public? false
      argument :state, :term
      run AikidoTest.ScopeReducer
    end
  end
end

defmodule AikidoTest.ScopedDomain do
  use Ash.Domain, extensions: [Aikido.Ash.Domain]

  agents do
    agent :scoped, AikidoTest.ScopedAgent
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
end
