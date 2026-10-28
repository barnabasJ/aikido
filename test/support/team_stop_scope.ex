defmodule AikidoTest.TeamStopScope.RecordCleanup do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    actor = context.actor && context.actor.id
    count = input.arguments.state.cleanups + 1

    effect =
      Aikido.Directives.emit_to_pid(
        %Aikido.Signal{
          type: "test.team_stop_scope.cleaned",
          data: %{id: input.context.aikido.agent_id, actor: actor, tenant: context.tenant}
        },
        input.arguments.state.observer
      )

    Aikido.Types.ActionResult.new(changes: %{cleanups: count}, directives: [effect])
  end
end

defmodule AikidoTest.TeamStopScope.Member do
  use Ash.Resource,
    domain: AikidoTest.TeamStopScope.Domain,
    extensions: [Aikido.Agent.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "team_scope_member"
    persistence :temporary

    schema do
      attribute :observer, :term do
        description "Process observing cleanup effects from this actual member agent."
        allow_nil? false
      end

      attribute :cleanups, :integer do
        description "Authorized cleanup transitions completed by this member."
        allow_nil? false
        default 0
      end

      attribute :boot_allowed, :boolean do
        description "Native create validation used to exercise failed topology startup."
        allow_nil? false
        default true
      end
    end

    route Aikido.AgentServer.Signals.LifecycleStopping,
          AikidoTest.TeamStopScope.RecordCleanup, public?: false
  end

  validations do
    validate attribute_equals(:boot_allowed, true), on: [:create]
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
      authorize_unless changing_attributes([:cleanups])
    end
  end
end

defmodule AikidoTest.TeamStopScope.Team do
  use Ash.Resource,
    domain: AikidoTest.TeamStopScope.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "stop_scope_team"
    persistence :temporary

    schema do
      attribute :observer, :term do
        description "Process observing this real team's own rollback cleanup."
        allow_nil? false
      end

      attribute :cleanups, :integer do
        description "Authorized cleanup transitions completed by the team root."
        allow_nil? false
        default 0
      end
    end

    route Aikido.AgentServer.Signals.LifecycleStopping,
          AikidoTest.TeamStopScope.RecordCleanup, public?: false
  end

  team do
    inherit [:observer]
    member :worker, AikidoTest.TeamStopScope.Member
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
      authorize_unless changing_attributes([:cleanups])
    end
  end
end

defmodule AikidoTest.TeamStopScope.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :scope_member, AikidoTest.TeamStopScope.Member
    agent :scope_team, AikidoTest.TeamStopScope.Team
  end
end
