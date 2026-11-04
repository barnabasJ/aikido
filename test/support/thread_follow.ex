defmodule Aikido.ThreadFollowTest.Role do
  use Ash.Type.Enum, values: [:publisher, :writer, :outsider]
end

defmodule Aikido.ThreadFollowTest.Access do
  @moduledoc "External application access records used by native source policies."
  use Ash.Resource, domain: Aikido.ThreadFollowTest.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    attribute :id, :string do
      description "Application actor identity."
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :role, Aikido.ThreadFollowTest.Role do
      description "Explicit application permission role."
      allow_nil? false
      public? true
    end

    attribute :reader?, :boolean do
      description "Current permission to read source journals."
      default false
      allow_nil? false
      public? true
    end

    attribute :active?, :boolean do
      description "Current business actor activity, checked natively rather than resolved into agent scope."
      default true
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:id, :role, :reader?, :active?],
      update: [:reader?, :active?]
    ]
  end
end

defmodule Aikido.ThreadFollowTest.SourcePolicy do
  use Ash.Policy.SimpleCheck

  @requests [
    "aikido.thread.follow",
    "aikido.thread.ack",
    "aikido.thread.unfollow",
    "aikido.ash.team.follow_roster",
    "aikido.ash.team.ack_roster",
    "aikido.ash.team.unfollow_roster"
  ]

  @impl true
  def describe(_options),
    do: "current application grant allows publishing or this journal read operation"

  @impl true
  def match?(%{id: id}, %{subject: subject}, _options) do
    case Ash.get(Aikido.ThreadFollowTest.Access, id, authorize?: false) do
      {:ok, %{active?: true, role: :publisher}} ->
        true

      {:ok, %{active?: true, role: :writer, reader?: true}} ->
        subject.action.name in [
          :follow,
          :ack,
          :unfollow,
          :follow_roster,
          :ack_roster,
          :unfollow_roster
        ] ||
          get_in(subject.context, [:aikido, :signal, Access.key(:type)]) in @requests

      _ ->
        false
    end
  end

  def match?(_actor, _context, _options), do: false
end

defmodule Aikido.ThreadFollowTest.WriterPolicy do
  use Ash.Policy.SimpleCheck
  @impl true
  def describe(_options), do: "the current application writer principal is active"
  @impl true
  def match?(%{id: id}, _context, _options) do
    case Ash.get(Aikido.ThreadFollowTest.Access, id, authorize?: false) do
      {:ok, %{active?: true, role: role}} when role in [:writer, :publisher] -> true
      _ -> false
    end
  end

  def match?(_actor, _context, _options), do: false
end

defmodule Aikido.ThreadFollowTest.Authority do
  @behaviour Aikido.Durable.ScopeAdapter

  @impl true
  def prepare(attributes, options, identity) do
    id = get_in(attributes, [:state, :actor_id])
    options = if id, do: Keyword.put(options, :actor, %{id: id, allowed: true}), else: options
    AikidoTest.DurableScopeAuthority.prepare(attributes, options, identity)
  end

  @impl true
  defdelegate restore(credential, saved, identity), to: AikidoTest.DurableScopeAuthority
  @impl true
  defdelegate checkpoint(agent, credential, identity), to: AikidoTest.DurableScopeAuthority
end

defmodule Aikido.ThreadFollowTest.Source do
  use Aikido.Agent, domain: Aikido.ThreadFollowTest.Domain, authorizers: [Ash.Policy.Authorizer]

  agent do
    name "journal_source"
    persistence :permanent
    slice :thread, Aikido.Thread.Slice

    schema do
      attribute :actor_id, :string do
        description "Identity authenticated by the durable scope adapter."
        allow_nil? false
      end
    end
  end

  policies do
    policy always() do
      authorize_if Aikido.ThreadFollowTest.SourcePolicy
    end
  end
end

defmodule Aikido.ThreadFollowTest.HoldWork do
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _options, _context) do
    Aikido.Types.ActionResult.new(
      changes: %{
        last_work: Map.delete(input.arguments, :state),
        works_received: input.arguments.state.works_received + 1,
        last_actor: input.context.aikido.actor.id
      }
    )
  end
end

defmodule Aikido.ThreadFollowTest.Writer do
  use Aikido.Agent, domain: Aikido.ThreadFollowTest.Domain, authorizers: [Ash.Policy.Authorizer]

  agent do
    name "journal_writer"
    persistence :permanent
    slice :journal_consumer, Aikido.Thread.Consumer.Slice

    schema do
      attribute :actor_id, :string do
        description "Authenticated writer principal."
        allow_nil? false
      end

      attribute :last_work, :map do
        description "One held external work batch for explicit commit-boundary tests, not a source backlog."
      end

      attribute :works_received, :integer do
        description "Number of work batches offered to this test application."
        default 0
        allow_nil? false
      end

      attribute :last_actor, :string do
        description "Actual native receiving principal."
      end
    end

    route Aikido.Thread.Consumer.Signals.Work, Aikido.ThreadFollowTest.HoldWork, public?: false
  end

  policies do
    policy always() do
      authorize_if Aikido.ThreadFollowTest.WriterPolicy
    end
  end
end

defmodule Aikido.ThreadFollowTest.Team do
  use Ash.Resource,
    domain: Aikido.ThreadFollowTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "journal_team"
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Authenticated team publisher."
        allow_nil? false
      end
    end
  end

  team do
    roster_history? true
    inherit [:actor_id]
    worker :source, Aikido.ThreadFollowTest.Source
    worker :writer, Aikido.ThreadFollowTest.Writer
  end

  policies do
    policy always() do
      authorize_if Aikido.ThreadFollowTest.SourcePolicy
    end
  end
end

defmodule Aikido.ThreadFollowTest.OptionalRosterTeam do
  @moduledoc "An ordinary team initially configured without retained roster history."
  use Ash.Resource,
    domain: Aikido.ThreadFollowTest.Domain,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "optional_roster_team"
    persistence :permanent

    schema do
      attribute :actor_id, :string do
        description "Authenticated owner of the retained team."
        allow_nil? false
      end
    end
  end

  team do
    inherit [:actor_id]
    worker :source, Aikido.ThreadFollowTest.Source
  end

  policies do
    policy always() do
      authorize_if Aikido.ThreadFollowTest.SourcePolicy
    end
  end
end

defmodule Aikido.ThreadFollowTest.HoldRequest do
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(_input, _options, _context), do: Aikido.Types.ActionResult.new(changes: nil)
end

defmodule Aikido.ThreadFollowTest.ReplyAvailability do
  use Aikido.Signal

  signal do
    type "test.journal.reply_availability"

    schema do
      attribute :consumer, Aikido.Agent.Reference do
        description "Actual consumer expecting this delayed source response."
        allow_nil? false
      end

      attribute :request_id, :string do
        description "Follow request whose response this source is now releasing."
        allow_nil? false
      end
    end
  end
end

defmodule Aikido.ThreadFollowTest.SendAvailability do
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _options, _context) do
    context = input.context.aikido

    source =
      Aikido.Agent.Reference.new!(
        id: context.agent_id,
        resource: context.agent_module,
        aikido: context.aikido,
        partition: context.partition
      )

    data = %{
      source: source,
      consumer: input.arguments.consumer,
      request_id: input.arguments.request_id,
      path: :thread,
      channel: :thread,
      batch: nil,
      cursor: Aikido.Thread.Types.Cursor.new!(generation: "pending", sequence: -1),
      pending?: false
    }

    reply = %Aikido.Signal{type: "aikido.thread.available", data: data}

    Aikido.Types.ActionResult.new(
      directives: [
        Aikido.Thread.Directives.Deliver.new!(
          target: input.arguments.consumer,
          signal: reply,
          kind: :batch
        )
      ]
    )
  end
end

defmodule Aikido.ThreadFollowTest.PendingSource do
  use Aikido.Agent, domain: Aikido.ThreadFollowTest.Domain

  agent do
    name "pending_journal_source"

    schema do
      attribute :actor_id, :string do
        description "Identity authenticated at source activation."
        allow_nil? false
      end
    end

    route Aikido.Thread.Signals.Follow, Aikido.ThreadFollowTest.HoldRequest
    route Aikido.ThreadFollowTest.ReplyAvailability, Aikido.ThreadFollowTest.SendAvailability
  end
end

defmodule Aikido.ThreadFollowTest.SquadStart do
  @moduledoc "Holds a real replacement's initial topology for activation-boundary assertions."
  use Aikido.Middleware

  @impl true
  def on_signal(signal, context, _options, next) do
    observer = Process.whereis(Aikido.ThreadFollowTest.SquadStartObserver)

    if signal.type == "aikido.ash.team.start" && observer do
      send(observer, {:squad_start_waiting, self()})

      receive do
        :continue_squad_start -> next.(signal, context)
      end
    else
      next.(signal, context)
    end
  end
end

defmodule Aikido.ThreadFollowTest.JournalSquad do
  @moduledoc "A normal nested team with retained Thread and roster channels."
  use Aikido.Agent,
    domain: Aikido.ThreadFollowTest.Domain,
    extensions: [Aikido.Team.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "journal_squad"
    persistence :permanent
    slice :thread, Aikido.Thread.Slice
    middleware [Aikido.ThreadFollowTest.SquadStart]

    schema do
      attribute :actor_id, :string do
        description "Authenticated owner of this real journal-producing team."
        allow_nil? false
      end
    end
  end

  team do
    roster_history? true
  end

  policies do
    policy always() do
      authorize_if Aikido.ThreadFollowTest.SourcePolicy
    end
  end
end

defmodule Aikido.ThreadFollowTest.TransientSource do
  @moduledoc "A normal temporary journal source whose identity can be replaced after stop."
  use Aikido.Agent, domain: Aikido.ThreadFollowTest.Domain, authorizers: [Ash.Policy.Authorizer]

  agent do
    name "transient_journal_source"
    persistence :temporary
    slice :thread, Aikido.Thread.Slice

    schema do
      attribute :actor_id, :string do
        description "Authenticated owner of this temporary source."
        allow_nil? false
      end
    end
  end

  policies do
    policy always() do
      authorize_if Aikido.ThreadFollowTest.SourcePolicy
    end
  end
end

defmodule Aikido.ThreadFollowTest.Domain do
  use Ash.Domain, extensions: [Aikido.Domain.Extension]

  resources do
    resource Aikido.ThreadFollowTest.Access
  end

  agents do
    agent :source, Aikido.ThreadFollowTest.Source
    agent :pending_source, Aikido.ThreadFollowTest.PendingSource
    agent :writer, Aikido.ThreadFollowTest.Writer
    agent :journal_team, Aikido.ThreadFollowTest.Team
    agent :optional_roster_team, Aikido.ThreadFollowTest.OptionalRosterTeam
    agent :journal_squad, Aikido.ThreadFollowTest.JournalSquad
    agent :transient_source, Aikido.ThreadFollowTest.TransientSource
  end
end
