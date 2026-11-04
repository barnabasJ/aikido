defmodule Aikido.TeamMemberAdmissionTest.Authority do
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  def prepare(attributes, options, identity) do
    actor_id = get_in(attributes, [:state, :actor_id])
    actor = options[:actor]

    actor =
      if actor && actor.id == actor_id,
        do: actor,
        else: %{id: actor_id, allowed: true, coordinator?: false}

    AikidoTest.DurableScopeAuthority.prepare(
      attributes,
      Keyword.put(options, :actor, actor),
      identity
    )
  end

  @impl true
  defdelegate restore(credential, saved, identity), to: AikidoTest.DurableScopeAuthority
  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority
end

defmodule Aikido.TeamMemberAdmissionTest.Work do
  use Aikido.Signal

  signal do
    type "test.member.work"

    schema do
      attribute :task_id, :string do
        description "The coordinator's task correlation."
        allow_nil? false
      end

      attribute :member, :term do
        description "The receiving member name."
        allow_nil? false
      end

      attribute :attempt, :term do
        description "The current receiving incarnation."
      end

      attribute :reply_to, :term do
        description "The coordinator selected by the task transport."
      end

      attribute :metadata, :map do
        description "Application-authored task metadata."
        default %{}
      end

      attribute :result, :term do
        description "The work result to return."
      end

      attribute :complete?, :boolean do
        description "Whether this unit finishes immediately."
        default true
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.TeamMemberAdmissionTest.Finish do
  use Aikido.Signal

  signal do
    type "test.member.finish"
  end
end

defmodule Aikido.TeamMemberAdmissionTest.Hold do
  use Aikido.Signal

  signal do
    type "test.member.hold"
  end
end

defmodule Aikido.TeamMemberAdmissionTest.WorkResult do
  @moduledoc "Pure application task completion descriptors."
  def directive(data, context) do
    signal = %Aikido.Signal{
      type: "aikido.ash.team.task.completed",
      data: Map.take(data, [:task_id, :member, :attempt, :result])
    }

    Aikido.Team.Delivery.directive(signal, context.parent.meta.team_pid, :completion, context)
  end
end

defmodule Aikido.TeamMemberAdmissionTest.RunWork do
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _options, _context) do
    context = input.context.aikido
    own = Aikido.Agent.resource_attributes(context.agent)
    data = Map.get(input.arguments, :data, input.arguments)
    changes = %{work_count: own.work_count + 1, seen_actor: context.actor.id}

    if data.complete? do
      Aikido.Types.ActionResult.new(
        changes: changes,
        directives: [Aikido.TeamMemberAdmissionTest.WorkResult.directive(data, context)]
      )
    else
      Aikido.Types.ActionResult.new(
        changes:
          Map.put(changes, :pending_work, Map.take(data, [:task_id, :member, :attempt, :result]))
      )
    end
  end
end

defmodule Aikido.TeamMemberAdmissionTest.FinishWork do
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _options, _context) do
    context = input.context.aikido

    case Aikido.Agent.resource_attributes(context.agent).pending_work do
      nil ->
        Aikido.Types.ActionResult.new(changes: nil)

      data ->
        Aikido.Types.ActionResult.new(
          changes: %{pending_work: nil},
          directives: [Aikido.TeamMemberAdmissionTest.WorkResult.directive(data, context)]
        )
    end
  end
end

defmodule Aikido.TeamMemberAdmissionTest.NoChange do
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(_input, _options, _context), do: Aikido.Types.ActionResult.new(changes: nil)
end

defmodule Aikido.TeamMemberAdmissionTest.HoldMailbox do
  use Aikido.Middleware
  @impl true
  def on_signal(signal, context, _options, next) do
    observer = Process.whereis(Aikido.TeamMemberAdmissionTest.Observer)

    if signal.type == "test.member.hold" && observer do
      send(observer, {:member_held, self()})

      receive do
        :release_member -> next.(signal, context)
      after
        5_000 -> raise "test did not release held member"
      end
    else
      next.(signal, context)
    end
  end
end

defmodule Aikido.TeamMemberAdmissionTest.HoldInitialTopology do
  @moduledoc "Holds a real lazy member's startup before it can acknowledge activation."
  use Aikido.Middleware

  @impl true
  def on_signal(signal, context, _options, next) do
    observer = Process.whereis(Aikido.TeamMemberAdmissionTest.Observer)

    if signal.type == "aikido.ash.team.start" && observer do
      send(observer, {:member_start_held, self()})

      receive do
        :release_member_start -> next.(signal, context)
      after
        5_000 -> raise "test did not release lazy member startup"
      end
    else
      next.(signal, context)
    end
  end
end

defmodule Aikido.TeamMemberAdmissionTest.DelayedWorker do
  @moduledoc "Real task worker with an empty nested topology that can be held during native startup."
  use Ash.Resource,
    domain: Aikido.TeamMemberAdmissionTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "admission_delayed_worker"
    instance Aikido.TeamMemberAdmissionTest.Instance
    persistence :temporary
    middleware [Aikido.TeamMemberAdmissionTest.HoldInitialTopology]

    schema do
      attribute :actor_id, :string do
        description "The immutable receiving principal selected at activation."
        allow_nil? false
      end

      attribute :work_count, :integer do
        description "Number of actual tasks received."
        default 0
        allow_nil? false
      end

      attribute :seen_actor, :string do
        description "Execution principal observed by the task action."
      end

      attribute :pending_work, :map do
        description "An unfinished application's task correlation."
      end
    end

    route Aikido.TeamMemberAdmissionTest.Work, Aikido.TeamMemberAdmissionTest.RunWork, name: :work
  end

  team do
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.TeamMemberAdmissionTest.Worker do
  use Ash.Resource,
    domain: Aikido.TeamMemberAdmissionTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension]

  agent do
    name "admission_worker"
    instance Aikido.TeamMemberAdmissionTest.Instance
    persistence :temporary
    middleware [Aikido.TeamMemberAdmissionTest.HoldMailbox]

    schema do
      attribute :actor_id, :string do
        description "The immutable application principal selected at activation."
        allow_nil? false
      end

      attribute :private_state, :string do
        description "Private worker data excluded from coordination."
        default "worker-secret"
        sensitive? true
      end

      attribute :pending_work, :map do
        description "An unfinished application task, with no runtime handles."
      end

      attribute :work_count, :integer do
        description "Number of tasks received through native delivery."
        default 0
        allow_nil? false
      end

      attribute :seen_actor, :string do
        description "Execution principal observed by the receiving task action."
      end
    end

    route Aikido.TeamMemberAdmissionTest.Work, Aikido.TeamMemberAdmissionTest.RunWork, name: :work

    route Aikido.TeamMemberAdmissionTest.Finish, Aikido.TeamMemberAdmissionTest.FinishWork,
      name: :finish

    route Aikido.TeamMemberAdmissionTest.Hold, Aikido.TeamMemberAdmissionTest.NoChange,
      name: :hold
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:allowed, true)
    end
  end
end

defmodule Aikido.TeamMemberAdmissionTest.Coordinator do
  use Ash.Resource,
    domain: Aikido.TeamMemberAdmissionTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "admission_coordinator"
    instance Aikido.TeamMemberAdmissionTest.Instance
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "The coordinator's immutable application principal."
        allow_nil? false
      end

      attribute :private_state, :string do
        description "Private coordinator data excluded from coordination."
        sensitive? true
        default "coordinator-secret"
      end
    end
  end

  team do
    inherit [:actor_id]
    worker :worker, Aikido.TeamMemberAdmissionTest.Worker
  end

  policies do
    policy always() do
      authorize_if actor_attribute_equals(:allowed, true)
    end

    policy action(:team_coordination) do
      authorize_if Aikido.Team.PolicyChecks.CoordinatorRead
    end

    policy action(:assign_task) do
      authorize_if Aikido.Team.PolicyChecks.MemberDelegation
    end

    policy action([:inspect, :stop]) do
      authorize_if actor_attribute_equals(:coordinator?, true)
    end
  end
end

defmodule Aikido.TeamMemberAdmissionTest.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  agents do
    agent :coordinator, Aikido.TeamMemberAdmissionTest.Coordinator
    agent :worker, Aikido.TeamMemberAdmissionTest.Worker
    agent :delayed_worker, Aikido.TeamMemberAdmissionTest.DelayedWorker
  end
end
