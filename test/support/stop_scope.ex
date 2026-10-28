defmodule AikidoTest.StopScope.Signals.Shutdown do
  use Aikido.Signal

  signal do
    type "test.stop_scope.shutdown"
  end
end

defmodule AikidoTest.StopScope.Actions.RequestShutdown do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _opts, _context) do
    Aikido.Types.ActionResult.new(directives: [%Aikido.Directives.Stop{}])
  end
end

defmodule AikidoTest.StopScope.Actions.RecordCleanup do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    actor = context.actor && context.actor.id
    cleanups = input.arguments.state.cleanups + 1

    effect =
      Aikido.Directives.emit_to_pid(
        %Aikido.Signal{
          type: "test.stop_scope.cleaned",
          data: %{
            actor: actor,
            tenant: context.tenant,
            cleanups: cleanups,
            marker: input.context[:marker]
          }
        },
        input.arguments.state.observer
      )

    Aikido.Types.ActionResult.new(
      changes: %{cleanups: cleanups, cleanup_actor: actor, cleanup_tenant: context.tenant},
      directives: [effect]
    )
  end
end

defmodule AikidoTest.StopScope.Agent do
  use Ash.Resource,
    domain: AikidoTest.StopScope.Domain,
    extensions: [Aikido.Agent.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "stop_scope"
    persistence :permanent

    schema do
      attribute :observer, :term do
        description "Test process observing effects after the authorized cleanup update."
        allow_nil? false
      end

      attribute :cleanups, :integer do
        description "Number of authorized cleanup updates applied to this agent."
        allow_nil? false
        default 0
      end

      attribute :cleanup_actor, :string do
        description "Current stop caller recorded by the last authorized cleanup."
      end

      attribute :cleanup_tenant, :string do
        description "Current stop tenant recorded by the last authorized cleanup."
      end
    end

    route Aikido.AgentServer.Signals.LifecycleStopping,
          AikidoTest.StopScope.Actions.RecordCleanup, public?: false

    route AikidoTest.StopScope.Signals.Shutdown,
          AikidoTest.StopScope.Actions.RequestShutdown, name: :shutdown
  end

  policies do
    policy action_type(:action) do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action(:__aikido_apply_state__) do
      authorize_if actor_attribute_equals(:can_cleanup, true)
    end
  end
end

defmodule AikidoTest.StopScope.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :stoppable, AikidoTest.StopScope.Agent
  end
end
