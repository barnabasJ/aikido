defmodule AikidoTest.AshFixtures.Counter.Actions.Increment do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: %{count: state.count + input.arguments.amount},
      directives: []
    )
  end
end

defmodule AikidoTest.AshFixtures.GeneratedCounter.Actions.Increment do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: %{state | count: state.count + input.arguments.amount},
      directives: []
    )
  end
end

defmodule AikidoTest.AshFixtures.GeneratedCounter.Actions.IncrementFromData do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state

    Aikido.Types.ActionResult.new(
      state: %{state | count: state.count + input.arguments.data.amount},
      directives: []
    )
  end
end

defmodule AikidoTest.AshFixtures.GeneratedCounter do
  use Ash.Resource,
    domain: AikidoTest.AshFixtures.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Aikido.Agent.Extension]

  agent do
    name "generated_counter"
    instance AikidoTest.AshFixtures.Instance

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        allow_nil? false
        default 0
        public? true
      end
    end

    route "generated.add", :reduce_increment, name: :add
    route "generated.data", :reduce_data, name: :with_data
  end

  actions do
    action :reduce_increment, Aikido.Types.ActionResult do
      argument :state, :term

      argument :amount, :integer,
        allow_nil?: false,
        default: 2,
        constraints: [min: 1],
        description: "Amount to add"

      run AikidoTest.AshFixtures.GeneratedCounter.Actions.Increment
    end
  end

  actions do
    action :reduce_data, Aikido.Types.ActionResult do
      argument :state, :term

      argument :data, :map,
        allow_nil?: false,
        constraints: [fields: [amount: [type: :integer, allow_nil?: false]]]

      run AikidoTest.AshFixtures.GeneratedCounter.Actions.IncrementFromData
    end
  end
end

defmodule AikidoTest.AshFixtures.Counter do
  use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Agent.Extension]

  agent do
    name "ash_counter"
    instance AikidoTest.AshFixtures.Instance

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        allow_nil? false
        default 0
        public? true
      end
    end

    route "counter.increment", :reduce_increment, name: :increment
    route "counter.add", :reduce_increment, name: :add
  end

  actions do
    action :reduce_increment, Aikido.Types.ActionResult do
      argument :state, :term
      argument :amount, :integer, default: 1
      run AikidoTest.AshFixtures.Counter.Actions.Increment
    end
  end
end

defmodule AikidoTest.AshFixtures.CounterSlice.Actions.Increment do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{count: input.arguments.state.count + Map.get(input.arguments.data, :amount, 1)}
    )
  end
end

defmodule AikidoTest.AshFixtures.CounterSlice.Actions.Internal do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(state: input.arguments.state)
  end
end

defmodule AikidoTest.AshFixtures.CounterSlice.Actions.Tick do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    Aikido.Types.ActionResult.new(
      state: %{count: input.arguments.state.count + Map.get(input.arguments.data, :amount, 1)}
    )
  end
end

defmodule AikidoTest.AshFixtures.CounterSlice do
  use Ash.Resource, data_layer: :embedded, extensions: [Aikido.Slice.Extension]

  attributes do
    attribute :count, :integer do
      description "Current counter value updated by routed signals."
      public? true
      default 0
    end
  end

  actions do
    action :increment, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :data, :map, allow_nil?: false
      run AikidoTest.AshFixtures.CounterSlice.Actions.Increment
    end

    action :internal, Aikido.Types.ActionResult do
      public? false
      argument :state, :map, allow_nil?: false
      argument :data, :map, allow_nil?: false
      run AikidoTest.AshFixtures.CounterSlice.Actions.Internal
    end

    action :tick, Aikido.Types.ActionResult do
      argument :state, :map, allow_nil?: false
      argument :data, :map, allow_nil?: false
      run AikidoTest.AshFixtures.CounterSlice.Actions.Tick
    end
  end

  slice do
    name "ash_counter_slice"
    route "slice.increment", :increment
    route "slice.internal", :internal
  end

  schedules do
    schedule "0 0 1 1 *", :tick, data: %{amount: 1}
  end
end

defmodule AikidoTest.AshFixtures.Composed do
  use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Agent.Extension]

  agent do
    name "ash_composed"
    instance AikidoTest.AshFixtures.Instance
    slice :counter, AikidoTest.AshFixtures.CounterSlice
  end
end

defmodule AikidoTest.AshFixtures.Team do
  use Ash.Resource,
    domain: AikidoTest.AshFixtures.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "ash_team"
    instance AikidoTest.AshFixtures.Instance
  end

  team do
    member :worker, AikidoTest.AshFixtures.Counter, initial_state: %{count: 2}
    member :reviewer, AikidoTest.AshFixtures.Composed
  end
end

defmodule AikidoTest.AshFixtures.TaskWorker.Actions.Uppercase do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  @impl true
  def run(input, _opts, _context) do
    state = input.arguments.state
    data = Map.delete(input.arguments, :state)
    result = String.upcase(data.text)

    reply =
      %Aikido.Signal{
        id: nil,
        source: "/test",
        type: "aikido.ash.team.task.completed",
        data: %{
          task_id: data.task_id,
          member: data.member,
          attempt: data.attempt,
          result: result
        }
      }

    Aikido.Types.ActionResult.new(
      state: %{state | result: result},
      directives: [Aikido.Directives.emit_to_pid(reply, data.reply_to)]
    )
  end
end

defmodule AikidoTest.AshFixtures.TaskWorker do
  use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Agent.Extension]

  agent do
    name "task_worker"
    instance AikidoTest.AshFixtures.Instance

    schema do
      attribute :result, :string do
        description "Echoed task result delivered to the assigning team."
        public? true
      end
    end

    route "harness.task", :task_echo, name: :task
  end

  actions do
    action :task_echo, Aikido.Types.ActionResult do
      argument :state, :term
      argument :text, :string, allow_nil?: false
      argument :task_id, :string, allow_nil?: false
      argument :member, :term, allow_nil?: false
      argument :attempt, :string, allow_nil?: false
      argument :reply_to, :term, allow_nil?: false
      run AikidoTest.AshFixtures.TaskWorker.Actions.Uppercase
    end
  end
end

defmodule AikidoTest.AshFixtures.DynamicTeam do
  use Ash.Resource,
    domain: AikidoTest.AshFixtures.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "dynamic_team"
    instance AikidoTest.AshFixtures.Instance
  end

  team do
    max_members 5
    worker :counter, AikidoTest.AshFixtures.Counter, max_members: 2
    worker :echo, AikidoTest.AshFixtures.TaskWorker, max_members: 2
  end
end

defmodule AikidoTest.AshFixtures.NestedTeam do
  use Ash.Resource,
    domain: AikidoTest.AshFixtures.Domain,
    extensions: [Aikido.Agent.Extension, Aikido.Team.Extension]

  agent do
    name "nested_team"
    instance AikidoTest.AshFixtures.Instance
  end

  team do
    member :subteam, AikidoTest.AshFixtures.Team

    member :lazy, AikidoTest.AshFixtures.Counter,
      activation: :lazy,
      owner: :subteam,
      depends_on: [:subteam]
  end
end

defmodule AikidoTest.AshFixtures.Protected do
  use Ash.Resource,
    domain: AikidoTest.AshFixtures.Domain,
    extensions: [Aikido.Agent.Extension],
    authorizers: [Ash.Policy.Authorizer]

  agent do
    name "protected"
    instance AikidoTest.AshFixtures.Instance
  end

  policies do
    policy action([:start, :initialize, :__aikido_initialize_state__]) do
      authorize_if actor_present()
    end
  end
end

defmodule AikidoTest.AshFixtures.DefaultCounter do
  use Ash.Resource, domain: AikidoTest.AshFixtures.Domain, extensions: [Aikido.Agent.Extension]

  agent do
    name "default_runtime_counter"

    schema do
      attribute :count, :integer do
        description "Current counter value updated by routed signals."
        default 0
        allow_nil? false
        public? true
        constraints min: 0
      end

      attribute :origin, :string do
        description "Read-only origin assigned by native resource defaults."
        default "local"
        writable? false
        public? true
      end
    end
  end
end

defmodule AikidoTest.AshFixtures.Domain do
  use Ash.Domain, otp_app: :aikido, extensions: [Aikido.Domain.Extension]

  agents do
    agent :generated_counter, AikidoTest.AshFixtures.GeneratedCounter
    agent :default_counter, AikidoTest.AshFixtures.DefaultCounter
    agent :counter, AikidoTest.AshFixtures.Counter
    agent :composed, AikidoTest.AshFixtures.Composed
    agent :team, AikidoTest.AshFixtures.Team
    agent :dynamic, AikidoTest.AshFixtures.DynamicTeam
    agent :nested, AikidoTest.AshFixtures.NestedTeam
    agent :task_worker, AikidoTest.AshFixtures.TaskWorker
    agent :protected, AikidoTest.AshFixtures.Protected
  end
end
